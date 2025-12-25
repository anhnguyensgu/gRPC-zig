const std = @import("std");
const ArrayList = std.array_list.Managed;

pub const HpackError = error{
    InvalidIndex,
    BufferTooSmall,
    InvalidHuffmanCode,
    InvalidEncoding,
} || std.mem.Allocator.Error;

pub const Encoder = struct {
    dynamic_table: ArrayList(HeaderField),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Encoder {
        return Encoder{
            .dynamic_table = ArrayList(HeaderField).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Encoder) void {
        for (self.dynamic_table.items) |field| {
            self.allocator.free(field.name);
            self.allocator.free(field.value);
        }
        self.dynamic_table.deinit();
    }

    pub fn encode(self: *Encoder, headers: std.StringHashMap([]const u8)) ![]u8 {
        var buffer = ArrayList(u8).init(self.allocator);
        errdefer buffer.deinit();

        var it = headers.iterator();
        while (it.next()) |entry| {
            try encodeField(&buffer, entry.key_ptr.*, entry.value_ptr.*);
        }

        return buffer.toOwnedSlice();
    }

    fn encodeField(buffer: *ArrayList(u8), name: []const u8, value: []const u8) !void {
        // Simple literal header field encoding
        try buffer.append(0x0); // New name
        try encodeString(buffer, name);
        try encodeString(buffer, value);
    }

    fn encodeString(buffer: *ArrayList(u8), str: []const u8) !void {
        try buffer.append(@intCast(str.len));
        try buffer.appendSlice(str);
    }
};

pub const Decoder = struct {
    dynamic_table: ArrayList(HeaderField),
    dynamic_size: usize,
    max_size: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Decoder {
        return Decoder{
            .dynamic_table = ArrayList(HeaderField).init(allocator),
            .dynamic_size = 0,
            .max_size = 4096,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Decoder) void {
        for (self.dynamic_table.items) |field| {
            self.allocator.free(field.name);
            self.allocator.free(field.value);
        }
        self.dynamic_table.deinit();
    }

    pub fn decode(self: *Decoder, encoded: []const u8) !std.StringHashMap([]const u8) {
        var headers = std.StringHashMap([]const u8).init(self.allocator);
        errdefer {
            var it = headers.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            headers.deinit();
        }

        var i: usize = 0;
        while (i < encoded.len) {
            const b = encoded[i];
            if (b & 0x80 != 0) {
                const index = try decodeInt(encoded[i..], 7);
                i += index.consumed;
                const field = try self.getIndexed(index.value);
                try appendHeader(self.allocator, &headers, field.name, field.value);
            } else if (b & 0x40 != 0) {
                const decoded = try self.decodeLiteral(encoded[i..], 6, true);
                i += decoded.consumed;
                try appendHeader(self.allocator, &headers, decoded.name, decoded.value);
            } else if (b & 0x20 != 0) {
                const size = try decodeInt(encoded[i..], 5);
                i += size.consumed;
                try self.updateMaxSize(size.value);
            } else {
                const decoded = try self.decodeLiteral(encoded[i..], 4, false);
                i += decoded.consumed;
                try appendHeader(self.allocator, &headers, decoded.name, decoded.value);
                self.allocator.free(decoded.name);
                self.allocator.free(decoded.value);
            }
        }

        return headers;
    }

    fn getIndexed(self: *Decoder, index: usize) !HeaderFieldConst {
        if (index == 0) return HpackError.InvalidIndex;
        if (index <= self.dynamic_table.items.len) {
            const pos = self.dynamic_table.items.len - index;
            const field = self.dynamic_table.items[pos];
            return .{ .name = field.name, .value = field.value };
        }
        const static_index = index - self.dynamic_table.items.len;
        if (static_index == 0 or static_index > static_table.len) return HpackError.InvalidIndex;
        return static_table[static_index - 1];
    }

    fn decodeLiteral(self: *Decoder, encoded: []const u8, prefix_bits: u8, add_to_table: bool) !DecodedLiteral {
        var consumed: usize = 0;
        const name_index = try decodeInt(encoded, prefix_bits);
        consumed += name_index.consumed;

        var name: []u8 = undefined;
        if (name_index.value == 0) {
            const name_res = try decodeString(self.allocator, encoded[consumed..]);
            consumed += name_res.consumed;
            name = name_res.value;
        } else {
            const indexed = try self.getIndexed(name_index.value);
            name = try self.allocator.dupe(u8, indexed.name);
        }

        const value_res = try decodeString(self.allocator, encoded[consumed..]);
        consumed += value_res.consumed;
        const value = value_res.value;

        if (add_to_table) {
            try self.addDynamic(name, value);
            return .{
                .name = name,
                .value = value,
                .consumed = consumed,
            };
        }

        return .{
            .name = name,
            .value = value,
            .consumed = consumed,
        };
    }

    fn addDynamic(self: *Decoder, name: []u8, value: []u8) !void {
        const entry_size = name.len + value.len + 32;
        if (entry_size > self.max_size) {
            self.allocator.free(name);
            self.allocator.free(value);
            self.dynamic_table.shrinkRetainingCapacity(0);
            self.dynamic_size = 0;
            return;
        }

        try self.dynamic_table.append(.{ .name = name, .value = value });
        self.dynamic_size += entry_size;

        while (self.dynamic_size > self.max_size and self.dynamic_table.items.len > 0) {
            const removed = self.dynamic_table.orderedRemove(0);
            self.dynamic_size -= removed.name.len + removed.value.len + 32;
            self.allocator.free(removed.name);
            self.allocator.free(removed.value);
        }
    }

    fn updateMaxSize(self: *Decoder, new_size: usize) !void {
        self.max_size = new_size;
        while (self.dynamic_size > self.max_size and self.dynamic_table.items.len > 0) {
            const removed = self.dynamic_table.orderedRemove(0);
            self.dynamic_size -= removed.name.len + removed.value.len + 32;
            self.allocator.free(removed.name);
            self.allocator.free(removed.value);
        }
    }
};

const HeaderField = struct {
    name: []const u8,
    value: []const u8,
    len: usize = 0,
};

const HeaderFieldConst = struct {
    name: []const u8,
    value: []const u8,
};

const DecodedLiteral = struct {
    name: []u8,
    value: []u8,
    consumed: usize,
};

const IntResult = struct {
    value: usize,
    consumed: usize,
};

fn decodeInt(data: []const u8, prefix_bits: u8) HpackError!IntResult {
    if (data.len == 0) return HpackError.BufferTooSmall;
    const first = data[0];
    const max_prefix: usize = (@as(usize, 1) << @as(u6, @intCast(prefix_bits))) - 1;
    var value: usize = first & @as(u8, @intCast(max_prefix));
    if (value < max_prefix) {
        return .{ .value = value, .consumed = 1 };
    }

    var m: usize = 0;
    var i: usize = 1;
    while (true) {
        if (i >= data.len) return HpackError.BufferTooSmall;
        const b = data[i];
        i += 1;
        value += (@as(usize, b & 0x7f)) << @as(u6, @intCast(m));
        if (b & 0x80 == 0) break;
        m += 7;
        if (m > 63) return HpackError.InvalidEncoding;
    }
    return .{ .value = value, .consumed = i };
}

const StringResult = struct {
    value: []u8,
    consumed: usize,
};

fn decodeString(allocator: std.mem.Allocator, data: []const u8) HpackError!StringResult {
    if (data.len == 0) return HpackError.BufferTooSmall;
    const huffman = (data[0] & 0x80) != 0;
    const len_res = try decodeInt(data, 7);
    var consumed = len_res.consumed;
    const len = len_res.value;
    if (data.len < consumed + len) return HpackError.BufferTooSmall;
    const raw = data[consumed .. consumed + len];
    consumed += len;

    if (!huffman) {
        return .{ .value = try allocator.dupe(u8, raw), .consumed = consumed };
    }

    const decoded = try huffmanDecode(allocator, raw);
    return .{ .value = decoded, .consumed = consumed };
}

fn appendHeader(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    name: []const u8,
    value: []const u8,
) !void {
    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);
    const value_copy = try allocator.dupe(u8, value);
    errdefer allocator.free(value_copy);
    try headers.put(name_copy, value_copy);
}

const static_table = [_]HeaderFieldConst{
    .{ .name = ":authority", .value = "" },
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":path", .value = "/" },
    .{ .name = ":path", .value = "/index.html" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":status", .value = "200" },
    .{ .name = ":status", .value = "204" },
    .{ .name = ":status", .value = "206" },
    .{ .name = ":status", .value = "304" },
    .{ .name = ":status", .value = "400" },
    .{ .name = ":status", .value = "404" },
    .{ .name = ":status", .value = "500" },
    .{ .name = "accept-charset", .value = "" },
    .{ .name = "accept-encoding", .value = "gzip, deflate" },
    .{ .name = "accept-language", .value = "" },
    .{ .name = "accept-ranges", .value = "" },
    .{ .name = "accept", .value = "" },
    .{ .name = "access-control-allow-origin", .value = "" },
    .{ .name = "age", .value = "" },
    .{ .name = "allow", .value = "" },
    .{ .name = "authorization", .value = "" },
    .{ .name = "cache-control", .value = "" },
    .{ .name = "content-disposition", .value = "" },
    .{ .name = "content-encoding", .value = "" },
    .{ .name = "content-language", .value = "" },
    .{ .name = "content-length", .value = "" },
    .{ .name = "content-location", .value = "" },
    .{ .name = "content-range", .value = "" },
    .{ .name = "content-type", .value = "" },
    .{ .name = "cookie", .value = "" },
    .{ .name = "date", .value = "" },
    .{ .name = "etag", .value = "" },
    .{ .name = "expect", .value = "" },
    .{ .name = "expires", .value = "" },
    .{ .name = "from", .value = "" },
    .{ .name = "host", .value = "" },
    .{ .name = "if-match", .value = "" },
    .{ .name = "if-modified-since", .value = "" },
    .{ .name = "if-none-match", .value = "" },
    .{ .name = "if-range", .value = "" },
    .{ .name = "if-unmodified-since", .value = "" },
    .{ .name = "last-modified", .value = "" },
    .{ .name = "link", .value = "" },
    .{ .name = "location", .value = "" },
    .{ .name = "max-forwards", .value = "" },
    .{ .name = "proxy-authenticate", .value = "" },
    .{ .name = "proxy-authorization", .value = "" },
    .{ .name = "range", .value = "" },
    .{ .name = "referer", .value = "" },
    .{ .name = "refresh", .value = "" },
    .{ .name = "retry-after", .value = "" },
    .{ .name = "server", .value = "" },
    .{ .name = "set-cookie", .value = "" },
    .{ .name = "strict-transport-security", .value = "" },
    .{ .name = "transfer-encoding", .value = "" },
    .{ .name = "user-agent", .value = "" },
    .{ .name = "vary", .value = "" },
    .{ .name = "via", .value = "" },
    .{ .name = "www-authenticate", .value = "" },
};

const HuffmanCode = struct {
    code: u32,
    len: u8,
};

const huffman_table = [_]HuffmanCode{
    .{ .code = 0x1ff8, .len = 13 }, .{ .code = 0x7fffd8, .len = 23 },
    .{ .code = 0xfffffe2, .len = 28 }, .{ .code = 0xfffffe3, .len = 28 },
    .{ .code = 0xfffffe4, .len = 28 }, .{ .code = 0xfffffe5, .len = 28 },
    .{ .code = 0xfffffe6, .len = 28 }, .{ .code = 0xfffffe7, .len = 28 },
    .{ .code = 0xfffffe8, .len = 28 }, .{ .code = 0xffffea, .len = 24 },
    .{ .code = 0x3ffffffc, .len = 30 }, .{ .code = 0xfffffe9, .len = 28 },
    .{ .code = 0xfffffea, .len = 28 }, .{ .code = 0x3ffffffd, .len = 30 },
    .{ .code = 0xfffffeb, .len = 28 }, .{ .code = 0xfffffec, .len = 28 },
    .{ .code = 0xfffffed, .len = 28 }, .{ .code = 0xfffffee, .len = 28 },
    .{ .code = 0xfffffef, .len = 28 }, .{ .code = 0xffffff0, .len = 28 },
    .{ .code = 0xffffff1, .len = 28 }, .{ .code = 0xffffff2, .len = 28 },
    .{ .code = 0x3ffffffe, .len = 30 }, .{ .code = 0xffffff3, .len = 28 },
    .{ .code = 0xffffff4, .len = 28 }, .{ .code = 0xffffff5, .len = 28 },
    .{ .code = 0xffffff6, .len = 28 }, .{ .code = 0xffffff7, .len = 28 },
    .{ .code = 0xffffff8, .len = 28 }, .{ .code = 0xffffff9, .len = 28 },
    .{ .code = 0xffffffa, .len = 28 }, .{ .code = 0xffffffb, .len = 28 },
    .{ .code = 0x14, .len = 6 }, .{ .code = 0x3f8, .len = 10 },
    .{ .code = 0x3f9, .len = 10 }, .{ .code = 0xffa, .len = 12 },
    .{ .code = 0x1ff9, .len = 13 }, .{ .code = 0x15, .len = 6 },
    .{ .code = 0xf8, .len = 8 }, .{ .code = 0x7fa, .len = 11 },
    .{ .code = 0x3fa, .len = 10 }, .{ .code = 0x3fb, .len = 10 },
    .{ .code = 0xf9, .len = 8 }, .{ .code = 0x7fb, .len = 11 },
    .{ .code = 0xfa, .len = 8 }, .{ .code = 0x16, .len = 6 },
    .{ .code = 0x17, .len = 6 }, .{ .code = 0x18, .len = 6 },
    .{ .code = 0x0, .len = 5 }, .{ .code = 0x1, .len = 5 },
    .{ .code = 0x2, .len = 5 }, .{ .code = 0x19, .len = 6 },
    .{ .code = 0x1a, .len = 6 }, .{ .code = 0x1b, .len = 6 },
    .{ .code = 0x1c, .len = 6 }, .{ .code = 0x1d, .len = 6 },
    .{ .code = 0x1e, .len = 6 }, .{ .code = 0x1f, .len = 6 },
    .{ .code = 0x5c, .len = 7 }, .{ .code = 0xfb, .len = 8 },
    .{ .code = 0x7ffc, .len = 15 }, .{ .code = 0x20, .len = 6 },
    .{ .code = 0xffb, .len = 12 }, .{ .code = 0x3fc, .len = 10 },
    .{ .code = 0x1ffa, .len = 13 }, .{ .code = 0x21, .len = 6 },
    .{ .code = 0x5d, .len = 7 }, .{ .code = 0x5e, .len = 7 },
    .{ .code = 0x5f, .len = 7 }, .{ .code = 0x60, .len = 7 },
    .{ .code = 0x61, .len = 7 }, .{ .code = 0x62, .len = 7 },
    .{ .code = 0x63, .len = 7 }, .{ .code = 0x64, .len = 7 },
    .{ .code = 0x65, .len = 7 }, .{ .code = 0x66, .len = 7 },
    .{ .code = 0x67, .len = 7 }, .{ .code = 0x68, .len = 7 },
    .{ .code = 0x69, .len = 7 }, .{ .code = 0x6a, .len = 7 },
    .{ .code = 0x6b, .len = 7 }, .{ .code = 0x6c, .len = 7 },
    .{ .code = 0x6d, .len = 7 }, .{ .code = 0x6e, .len = 7 },
    .{ .code = 0x6f, .len = 7 }, .{ .code = 0x70, .len = 7 },
    .{ .code = 0x71, .len = 7 }, .{ .code = 0x72, .len = 7 },
    .{ .code = 0xfc, .len = 8 }, .{ .code = 0x73, .len = 7 },
    .{ .code = 0xfd, .len = 8 }, .{ .code = 0x1ffb, .len = 13 },
    .{ .code = 0x7fff0, .len = 19 }, .{ .code = 0x1ffc, .len = 13 },
    .{ .code = 0x3ffc, .len = 14 }, .{ .code = 0x22, .len = 6 },
    .{ .code = 0x7ffd, .len = 15 }, .{ .code = 0x3, .len = 5 },
    .{ .code = 0x23, .len = 6 }, .{ .code = 0x4, .len = 5 },
    .{ .code = 0x24, .len = 6 }, .{ .code = 0x5, .len = 5 },
    .{ .code = 0x25, .len = 6 }, .{ .code = 0x26, .len = 6 },
    .{ .code = 0x27, .len = 6 }, .{ .code = 0x6, .len = 5 },
    .{ .code = 0x74, .len = 7 }, .{ .code = 0x75, .len = 7 },
    .{ .code = 0x28, .len = 6 }, .{ .code = 0x29, .len = 6 },
    .{ .code = 0x2a, .len = 6 }, .{ .code = 0x7, .len = 5 },
    .{ .code = 0x2b, .len = 6 }, .{ .code = 0x76, .len = 7 },
    .{ .code = 0x2c, .len = 6 }, .{ .code = 0x8, .len = 5 },
    .{ .code = 0x9, .len = 5 }, .{ .code = 0x2d, .len = 6 },
    .{ .code = 0x77, .len = 7 }, .{ .code = 0x78, .len = 7 },
    .{ .code = 0x79, .len = 7 }, .{ .code = 0x7a, .len = 7 },
    .{ .code = 0x7b, .len = 7 }, .{ .code = 0x7ffe, .len = 15 },
    .{ .code = 0x7fc, .len = 11 }, .{ .code = 0x3ffd, .len = 14 },
    .{ .code = 0x1ffd, .len = 13 }, .{ .code = 0xffffffc, .len = 28 },
    .{ .code = 0xfffe6, .len = 20 }, .{ .code = 0x3fffd2, .len = 22 },
    .{ .code = 0xfffe7, .len = 20 }, .{ .code = 0xfffe8, .len = 20 },
    .{ .code = 0x3fffd3, .len = 22 }, .{ .code = 0x3fffd4, .len = 22 },
    .{ .code = 0x3fffd5, .len = 22 }, .{ .code = 0x7fffd9, .len = 23 },
    .{ .code = 0x3fffd6, .len = 22 }, .{ .code = 0x7fffda, .len = 23 },
    .{ .code = 0x7fffdb, .len = 23 }, .{ .code = 0x7fffdc, .len = 23 },
    .{ .code = 0x7fffdd, .len = 23 }, .{ .code = 0x7fffde, .len = 23 },
    .{ .code = 0xffffeb, .len = 24 }, .{ .code = 0x7fffdf, .len = 23 },
    .{ .code = 0xffffec, .len = 24 }, .{ .code = 0xffffed, .len = 24 },
    .{ .code = 0x3fffd7, .len = 22 }, .{ .code = 0x7fffe0, .len = 23 },
    .{ .code = 0xffffee, .len = 24 }, .{ .code = 0x7fffe1, .len = 23 },
    .{ .code = 0x7fffe2, .len = 23 }, .{ .code = 0x7fffe3, .len = 23 },
    .{ .code = 0x7fffe4, .len = 23 }, .{ .code = 0x1fffdc, .len = 21 },
    .{ .code = 0x3fffd8, .len = 22 }, .{ .code = 0x7fffe5, .len = 23 },
    .{ .code = 0x3fffd9, .len = 22 }, .{ .code = 0x7fffe6, .len = 23 },
    .{ .code = 0x7fffe7, .len = 23 }, .{ .code = 0xffffef, .len = 24 },
    .{ .code = 0x3fffda, .len = 22 }, .{ .code = 0x1fffdd, .len = 21 },
    .{ .code = 0xfffe9, .len = 20 }, .{ .code = 0x3fffdb, .len = 22 },
    .{ .code = 0x3fffdc, .len = 22 }, .{ .code = 0x7fffe8, .len = 23 },
    .{ .code = 0x7fffe9, .len = 23 }, .{ .code = 0x1fffde, .len = 21 },
    .{ .code = 0x7fffea, .len = 23 }, .{ .code = 0x3fffdd, .len = 22 },
    .{ .code = 0x3fffde, .len = 22 }, .{ .code = 0xfffff0, .len = 24 },
    .{ .code = 0x1fffdf, .len = 21 }, .{ .code = 0x3fffdf, .len = 22 },
    .{ .code = 0x7fffeb, .len = 23 }, .{ .code = 0x7fffec, .len = 23 },
    .{ .code = 0x1fffe0, .len = 21 }, .{ .code = 0x1fffe1, .len = 21 },
    .{ .code = 0x3fffe0, .len = 22 }, .{ .code = 0x1fffe2, .len = 21 },
    .{ .code = 0x7fffed, .len = 23 }, .{ .code = 0x3fffe1, .len = 22 },
    .{ .code = 0x7fffee, .len = 23 }, .{ .code = 0x7fffef, .len = 23 },
    .{ .code = 0xfffea, .len = 20 }, .{ .code = 0x3fffe2, .len = 22 },
    .{ .code = 0x3fffe3, .len = 22 }, .{ .code = 0x3fffe4, .len = 22 },
    .{ .code = 0x7ffff0, .len = 23 }, .{ .code = 0x3fffe5, .len = 22 },
    .{ .code = 0x3fffe6, .len = 22 }, .{ .code = 0x7ffff1, .len = 23 },
    .{ .code = 0x3ffffe0, .len = 26 }, .{ .code = 0x3ffffe1, .len = 26 },
    .{ .code = 0xfffeb, .len = 20 }, .{ .code = 0x7fff1, .len = 19 },
    .{ .code = 0x3fffe7, .len = 22 }, .{ .code = 0x7ffff2, .len = 23 },
    .{ .code = 0x3fffe8, .len = 22 }, .{ .code = 0x1ffffec, .len = 25 },
    .{ .code = 0x3ffffe2, .len = 26 }, .{ .code = 0x3ffffe3, .len = 26 },
    .{ .code = 0x3ffffe4, .len = 26 }, .{ .code = 0x7ffffde, .len = 27 },
    .{ .code = 0x7ffffdf, .len = 27 }, .{ .code = 0x3ffffe5, .len = 26 },
    .{ .code = 0xfffff1, .len = 24 }, .{ .code = 0x1ffffed, .len = 25 },
    .{ .code = 0x7fff2, .len = 19 }, .{ .code = 0x1fffe3, .len = 21 },
    .{ .code = 0x3ffffe6, .len = 26 }, .{ .code = 0x7ffffe0, .len = 27 },
    .{ .code = 0x7ffffe1, .len = 27 }, .{ .code = 0x3ffffe7, .len = 26 },
    .{ .code = 0x7ffffe2, .len = 27 }, .{ .code = 0xfffff2, .len = 24 },
    .{ .code = 0x1fffe4, .len = 21 }, .{ .code = 0x1fffe5, .len = 21 },
    .{ .code = 0x3ffffe8, .len = 26 }, .{ .code = 0x3ffffe9, .len = 26 },
    .{ .code = 0xffffffd, .len = 28 }, .{ .code = 0x7ffffe3, .len = 27 },
    .{ .code = 0x7ffffe4, .len = 27 }, .{ .code = 0x7ffffe5, .len = 27 },
    .{ .code = 0xfffec, .len = 20 }, .{ .code = 0xfffff3, .len = 24 },
    .{ .code = 0xfffed, .len = 20 }, .{ .code = 0x1fffe6, .len = 21 },
    .{ .code = 0x3fffe9, .len = 22 }, .{ .code = 0x1fffe7, .len = 21 },
    .{ .code = 0x1fffe8, .len = 21 }, .{ .code = 0x7ffff3, .len = 23 },
    .{ .code = 0x3fffea, .len = 22 }, .{ .code = 0x3fffeb, .len = 22 },
    .{ .code = 0x1ffffee, .len = 25 }, .{ .code = 0x1ffffef, .len = 25 },
    .{ .code = 0xfffff4, .len = 24 }, .{ .code = 0xfffff5, .len = 24 },
    .{ .code = 0x3ffffea, .len = 26 }, .{ .code = 0x7ffff4, .len = 23 },
    .{ .code = 0x3ffffeb, .len = 26 }, .{ .code = 0x7ffffe6, .len = 27 },
    .{ .code = 0x3ffffec, .len = 26 }, .{ .code = 0x3ffffed, .len = 26 },
    .{ .code = 0x7ffffe7, .len = 27 }, .{ .code = 0x7ffffe8, .len = 27 },
    .{ .code = 0x7ffffe9, .len = 27 }, .{ .code = 0x7ffffea, .len = 27 },
    .{ .code = 0x7ffffeb, .len = 27 }, .{ .code = 0xffffffe, .len = 28 },
    .{ .code = 0x7ffffec, .len = 27 }, .{ .code = 0x7ffffed, .len = 27 },
    .{ .code = 0x7ffffee, .len = 27 }, .{ .code = 0x7ffffef, .len = 27 },
    .{ .code = 0x7fffff0, .len = 27 }, .{ .code = 0x3ffffee, .len = 26 },
    .{ .code = 0x3fffffff, .len = 30 },
};

const HuffmanNode = struct {
    left: i16 = -1,
    right: i16 = -1,
    sym: i16 = -1,
};

const max_huffman_nodes = 1024;

const huffman_tree = buildHuffmanTree();

fn buildHuffmanTree() [max_huffman_nodes]HuffmanNode {
    @setEvalBranchQuota(10000);
    const empty = HuffmanNode{};
    var nodes = [_]HuffmanNode{empty} ** max_huffman_nodes;
    var next: usize = 1;

    for (huffman_table, 0..) |entry, sym| {
        var node_idx: usize = 0;
        var bit: i32 = @as(i32, @intCast(entry.len)) - 1;
        while (bit >= 0) : (bit -= 1) {
            const bitval: u32 = (entry.code >> @intCast(bit)) & 1;
            const child_ptr = if (bitval == 0) &nodes[node_idx].left else &nodes[node_idx].right;
            if (child_ptr.* == -1) {
                if (next >= max_huffman_nodes) @compileError("huffman tree too small");
                child_ptr.* = @intCast(next);
                nodes[next] = empty;
                next += 1;
            }
            node_idx = @intCast(child_ptr.*);
        }
        nodes[node_idx].sym = @intCast(sym);
    }

    return nodes;
}

fn isEosPrefixNode(node_idx: usize) bool {
    var idx: usize = 0;
    while (true) {
        if (idx == node_idx) return true;
        const next = huffman_tree[idx].right;
        if (next < 0) return false;
        idx = @intCast(next);
    }
}

fn huffmanDecode(allocator: std.mem.Allocator, data: []const u8) HpackError![]u8 {
    var out = ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var node_idx: usize = 0;
    for (data) |byte| {
        var bit: i32 = 7;
        while (bit >= 0) : (bit -= 1) {
            const bitval = (byte >> @intCast(bit)) & 1;
            const next = if (bitval == 0) huffman_tree[node_idx].left else huffman_tree[node_idx].right;
            if (next < 0) return HpackError.InvalidHuffmanCode;
            node_idx = @intCast(next);
            const sym = huffman_tree[node_idx].sym;
            if (sym >= 0) {
                if (sym == 256) return HpackError.InvalidHuffmanCode;
                try out.append(@intCast(sym));
                node_idx = 0;
            }
        }
    }

    if (node_idx != 0 and !isEosPrefixNode(node_idx)) return HpackError.InvalidHuffmanCode;

    return out.toOwnedSlice();
}
