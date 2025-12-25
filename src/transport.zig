const std = @import("std");
const net = std.net;
const ArrayList = std.array_list.Managed;
const compression = @import("features/compression.zig");
const http2 = struct {
    pub const connection = @import("http2/connection.zig");
    pub const frame = @import("http2/frame.zig");
    pub const stream = @import("http2/stream.zig");
    pub const hpack = @import("http2/hpack.zig");
};

pub const TransportError = error{
    ConnectionClosed,
    InvalidHeader,
    PayloadTooLarge,
    CompressionNotSupported,
    Http2Error,
    GrpcStatusNotOk,
};

pub const GrpcStatusView = struct {
    code: u32,
    message: ?[]const u8,
};

pub const Message = struct {
    allocator: std.mem.Allocator,
    headers: std.StringHashMap([]const u8),
    data: []const u8,
    compression_algorithm: compression.Compression.Algorithm,

    pub fn deinit(self: *Message) void {
        var it = self.headers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();
        self.allocator.free(self.data);
    }
};

pub const Role = enum {
    client,
    server,
};

pub const Transport = struct {
    stream: net.Stream,
    read_buf: []u8,
    write_buf: []u8,
    allocator: std.mem.Allocator,
    http2_conn: ?http2.connection.Connection,
    next_stream_id: u31,
    hpack_decoder: http2.hpack.Decoder,
    last_grpc_status: ?u32,
    last_grpc_message: ?[]u8,

    pub fn init(allocator: std.mem.Allocator, stream: net.Stream, role: Role) !Transport {
        var transport = Transport{
            .stream = stream,
            .read_buf = try allocator.alloc(u8, 1024 * 64),
            .write_buf = try allocator.alloc(u8, 1024 * 64),
            .allocator = allocator,
            .http2_conn = null,
            .next_stream_id = 1,
            .hpack_decoder = try http2.hpack.Decoder.init(allocator),
            .last_grpc_status = null,
            .last_grpc_message = null,
        };

        // Initialize HTTP/2 connection
        transport.http2_conn = try http2.connection.Connection.init(allocator);
        try transport.setupHttp2(role);

        return transport;
    }

    fn serializeMessage(self: *Transport, headers: *const std.StringHashMap([]const u8), data: []const u8, compression_alg: compression.Compression.Algorithm) ![]u8 {
        var buffer = ArrayList(u8).init(self.allocator);
        errdefer buffer.deinit();

        try buffer.append(@intFromEnum(compression_alg));

        const header_count: u16 = @intCast(headers.count());
        try buffer.writer().writeInt(u16, header_count, .big);

        var it = headers.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const value = entry.value_ptr.*;

            try buffer.writer().writeInt(u16, @intCast(name.len), .big);
            try buffer.writer().writeInt(u16, @intCast(value.len), .big);
            try buffer.appendSlice(name);
            try buffer.appendSlice(value);
        }

        try buffer.writer().writeInt(u32, @intCast(data.len), .big);
        try buffer.appendSlice(data);

        return buffer.toOwnedSlice();
    }

    fn deserializeMessage(self: *Transport, payload: []const u8) !Message {
        var index: usize = 0;
        if (payload.len < 1 + 2 + 4) return TransportError.InvalidHeader;

        const compression_tag: u8 = payload[index];
        index += 1;

        const headers_len = (@as(u16, payload[index]) << 8) | payload[index + 1];
        index += 2;

        var headers = std.StringHashMap([]const u8).init(self.allocator);
        errdefer {
            var cleanup_it = headers.iterator();
            while (cleanup_it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            headers.deinit();
        }

        for (0..headers_len) |_| {
            if (index + 4 > payload.len) return TransportError.InvalidHeader;
            const name_len = (@as(u16, payload[index]) << 8) | payload[index + 1];
            const value_len = (@as(u16, payload[index + 2]) << 8) | payload[index + 3];
            index += 4;

            if (index + name_len + value_len > payload.len) return TransportError.InvalidHeader;

            const name = payload[index .. index + name_len];
            index += name_len;
            const value = payload[index .. index + value_len];
            index += value_len;

            const name_copy = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(name_copy);
            const value_copy = try self.allocator.dupe(u8, value);
            errdefer self.allocator.free(value_copy);

            try headers.put(name_copy, value_copy);
        }

        if (index + 4 > payload.len) return TransportError.InvalidHeader;
        const data_len = (@as(u32, payload[index]) << 24) |
            (@as(u32, payload[index + 1]) << 16) |
            (@as(u32, payload[index + 2]) << 8) |
            @as(u32, payload[index + 3]);
        index += 4;
        if (index + data_len > payload.len) return TransportError.InvalidHeader;

        const data_copy = try self.allocator.dupe(u8, payload[index .. index + data_len]);

        return Message{
            .allocator = self.allocator,
            .headers = headers,
            .data = data_copy,
            .compression_algorithm = @enumFromInt(compression_tag),
        };
    }

    pub fn deinit(self: *Transport) void {
        if (self.http2_conn) |*conn| {
            conn.deinit();
        }
        self.hpack_decoder.deinit();
        self.clearLastGrpcStatus();
        self.allocator.free(self.read_buf);
        self.allocator.free(self.write_buf);
        self.stream.close();
    }

    pub fn lastGrpcStatus(self: *Transport) ?GrpcStatusView {
        const code = self.last_grpc_status orelse return null;
        return .{ .code = code, .message = self.last_grpc_message };
    }

    fn clearLastGrpcStatus(self: *Transport) void {
        if (self.last_grpc_message) |msg| {
            self.allocator.free(msg);
        }
        self.last_grpc_message = null;
        self.last_grpc_status = null;
    }

    fn setupHttp2(self: *Transport, role: Role) !void {
        var reader = self.stream.reader(self.read_buf);
        var writer = self.stream.writer(self.write_buf);

        if (role == .client) {
            // Client sends the HTTP/2 connection preface.
            try writer.interface.writeAll(http2.connection.Connection.PREFACE);
        } else {
            // Server expects the client preface.
            var preface_buf: [http2.connection.Connection.PREFACE.len]u8 = undefined;
            try reader.interface().readSliceAll(&preface_buf);
            if (!std.mem.eql(u8, preface_buf[0..], http2.connection.Connection.PREFACE)) {
                return TransportError.Http2Error;
            }
        }

        // Both sides send an initial SETTINGS frame.
        var settings_frame = try http2.frame.Frame.init(self.allocator);
        defer settings_frame.deinit(self.allocator);

        settings_frame.type = .SETTINGS;
        settings_frame.flags = 0;
        settings_frame.stream_id = 0;
        // Add your settings here.

        try settings_frame.encode(&writer.interface);
        try writer.interface.flush();

        // Read peer SETTINGS.
        var peer_settings = try http2.frame.Frame.decode(reader.interface(), self.allocator);
        defer peer_settings.deinit(self.allocator);
        if (peer_settings.type != .SETTINGS) {
            return TransportError.Http2Error;
        }

        try self.sendSettingsAck();
    }

    fn sendSettingsAck(self: *Transport) !void {
        var ack = try http2.frame.Frame.init(self.allocator);
        defer ack.deinit(self.allocator);

        ack.type = .SETTINGS;
        ack.flags = 0x1; // ACK
        ack.stream_id = 0;
        ack.length = 0;

        var writer = self.stream.writer(self.write_buf);
        try ack.encode(&writer.interface);
        try writer.interface.flush();
    }

    const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    fn encodeHeaderBlock(self: *Transport, headers: []const Header) ![]u8 {
        var buffer = ArrayList(u8).init(self.allocator);
        errdefer buffer.deinit();

        for (headers) |header| {
            try encodeLiteralHeader(&buffer, header.name, header.value);
        }

        return buffer.toOwnedSlice();
    }

    fn encodeLiteralHeader(buffer: *ArrayList(u8), name: []const u8, value: []const u8) !void {
        // Literal header field without indexing, literal name.
        try encodeInt(buffer, 4, 0, 0x00);
        try encodeString(buffer, name);
        try encodeString(buffer, value);
    }

    fn encodeString(buffer: *ArrayList(u8), str: []const u8) !void {
        // Huffman flag = 0, length encoded with 7-bit prefix.
        try encodeInt(buffer, 7, str.len, 0x00);
        try buffer.appendSlice(str);
    }

    fn encodeInt(buffer: *ArrayList(u8), prefix_bits: u8, value: usize, prefix: u8) !void {
        const max_prefix: usize = (@as(usize, 1) << @as(u6, @intCast(prefix_bits))) - 1;
        if (value < max_prefix) {
            try buffer.append(prefix | @as(u8, @intCast(value)));
            return;
        }

        try buffer.append(prefix | @as(u8, @intCast(max_prefix)));
        var n = value - max_prefix;
        while (n >= 128) {
            try buffer.append(@as(u8, @intCast(n & 0x7f)) | 0x80);
            n >>= 7;
        }
        try buffer.append(@as(u8, @intCast(n)));
    }

    pub fn writeGrpcRequest(
        self: *Transport,
        path: []const u8,
        authority: []const u8,
        scheme: []const u8,
        message: []const u8,
    ) !u31 {
        if (message.len > std.math.maxInt(u32)) return TransportError.PayloadTooLarge;

        const stream_id = self.next_stream_id;
        self.next_stream_id += 2;

        var headers = ArrayList(Header).init(self.allocator);
        defer headers.deinit();

        try headers.append(.{ .name = ":method", .value = "POST" });
        try headers.append(.{ .name = ":path", .value = path });
        try headers.append(.{ .name = ":scheme", .value = scheme });
        try headers.append(.{ .name = ":authority", .value = authority });
        try headers.append(.{ .name = "content-type", .value = "application/grpc" });
        try headers.append(.{ .name = "te", .value = "trailers" });
        try headers.append(.{ .name = "grpc-encoding", .value = "identity" });
        try headers.append(.{ .name = "grpc-accept-encoding", .value = "identity" });
        try headers.append(.{ .name = "user-agent", .value = "grpc-zig/0.1" });

        const header_block = try self.encodeHeaderBlock(headers.items);

        var headers_frame = try http2.frame.Frame.init(self.allocator);
        defer headers_frame.deinit(self.allocator);
        self.allocator.free(headers_frame.payload);

        headers_frame.type = .HEADERS;
        headers_frame.flags = http2.frame.FrameFlags.END_HEADERS;
        headers_frame.stream_id = stream_id;
        headers_frame.payload = header_block;
        headers_frame.length = @intCast(header_block.len);

        var data_frame = try http2.frame.Frame.init(self.allocator);
        defer data_frame.deinit(self.allocator);
        self.allocator.free(data_frame.payload);

        const grpc_payload = try self.encodeGrpcPayload(message);
        data_frame.type = .DATA;
        data_frame.flags = http2.frame.FrameFlags.END_STREAM;
        data_frame.stream_id = stream_id;
        data_frame.payload = grpc_payload;
        data_frame.length = @intCast(grpc_payload.len);

        var writer = self.stream.writer(self.write_buf);
        try headers_frame.encode(&writer.interface);
        try data_frame.encode(&writer.interface);
        try writer.interface.flush();

        return stream_id;
    }

    fn encodeGrpcPayload(self: *Transport, message: []const u8) ![]u8 {
        const total_len = 5 + message.len;
        var payload = try self.allocator.alloc(u8, total_len);
        payload[0] = 0; // compression flag = 0 (identity)
        std.mem.writeInt(u32, payload[1..5], @intCast(message.len), .big);
        @memcpy(payload[5..], message);
        return payload;
    }

    pub fn readGrpcResponse(self: *Transport, stream_id: u31) ![]u8 {
        self.clearLastGrpcStatus();
        var reader = self.stream.reader(self.read_buf);
        var body = ArrayList(u8).init(self.allocator);
        defer body.deinit();

        var end_stream = false;
        var grpc_status: ?u32 = null;
        while (!end_stream) {
            var frame = http2.frame.Frame.decode(reader.interface(), self.allocator) catch |err| switch (err) {
                error.EndOfStream, error.ReadFailed => return TransportError.ConnectionClosed,
                else => return err,
            };
            defer frame.deinit(self.allocator);

            if (frame.stream_id != stream_id) {
                continue;
            }

            switch (frame.type) {
                .DATA => {
                    try body.appendSlice(frame.payload);
                    if (frame.flags & 0x1 != 0) end_stream = true;
                },
                .HEADERS => {
                    var headers = try self.hpack_decoder.decode(frame.payload);
                    defer freeHeaderMap(self.allocator, &headers);
                    if (headers.get("grpc-status")) |status_str| {
                        grpc_status = std.fmt.parseInt(u32, status_str, 10) catch null;
                    }
                    if (headers.get("grpc-message")) |msg| {
                        if (self.last_grpc_message) |old| self.allocator.free(old);
                        self.last_grpc_message = try self.allocator.dupe(u8, msg);
                    }
                    if (frame.flags & 0x1 != 0) end_stream = true;
                },
                .SETTINGS => {
                    if (frame.flags & 0x1 == 0) try self.sendSettingsAck();
                },
                .PING, .WINDOW_UPDATE => {},
                else => return TransportError.Http2Error,
            }
        }

        const full = try body.toOwnedSlice();
        defer self.allocator.free(full);
        if (full.len < 5) {
            if (grpc_status != null) self.last_grpc_status = grpc_status;
            if (grpc_status != null and grpc_status.? != 0) return TransportError.GrpcStatusNotOk;
            return TransportError.InvalidHeader;
        }

        if (full[0] != 0) return TransportError.CompressionNotSupported;
        const msg_len = std.mem.readInt(u32, full[1..5], .big);
        const total = 5 + @as(usize, msg_len);
        if (full.len < total) return TransportError.InvalidHeader;

        if (grpc_status != null) self.last_grpc_status = grpc_status;
        if (grpc_status != null and grpc_status.? != 0) return TransportError.GrpcStatusNotOk;
        return self.allocator.dupe(u8, full[5..total]);
    }

    pub fn readMessage(self: *Transport) !Message {
        var reader = self.stream.reader(self.read_buf);
        while (true) {
            var frame = http2.frame.Frame.decode(reader.interface(), self.allocator) catch |err| switch (err) {
                error.EndOfStream, error.ReadFailed => return TransportError.ConnectionClosed,
                else => return err,
            };
            defer frame.deinit(self.allocator);

            switch (frame.type) {
                .DATA => return try self.deserializeMessage(frame.payload),
                .SETTINGS => {
                    if (frame.flags & 0x1 == 0) try self.sendSettingsAck();
                    continue;
                },
                .PING, .WINDOW_UPDATE => continue,
                else => return TransportError.Http2Error,
            }
        }
    }

    pub fn writeMessage(self: *Transport, headers: *const std.StringHashMap([]const u8), message: []const u8, compression_alg: compression.Compression.Algorithm) !void {
        var data_frame = try http2.frame.Frame.init(self.allocator);
        defer data_frame.deinit(self.allocator);
        self.allocator.free(data_frame.payload);

        const encoded = try self.serializeMessage(headers, message, compression_alg);

        data_frame.type = .DATA;
        data_frame.flags = http2.frame.FrameFlags.END_STREAM;
        data_frame.stream_id = 1; // Use appropriate stream ID
        data_frame.payload = encoded;
        data_frame.length = @intCast(encoded.len);

        var writer = self.stream.writer(self.write_buf);
        try data_frame.encode(&writer.interface);
        try writer.interface.flush();
    }
};

fn freeHeaderMap(allocator: std.mem.Allocator, headers: *std.StringHashMap([]const u8)) void {
    var it = headers.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    headers.deinit();
}
