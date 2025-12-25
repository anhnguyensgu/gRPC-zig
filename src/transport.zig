const std = @import("std");
const net = std.net;
const ArrayList = std.array_list.Managed;
const compression = @import("features/compression.zig");
const http2 = struct {
    pub const connection = @import("http2/connection.zig");
    pub const frame = @import("http2/frame.zig");
    pub const stream = @import("http2/stream.zig");
};

pub const TransportError = error{
    ConnectionClosed,
    InvalidHeader,
    PayloadTooLarge,
    CompressionNotSupported,
    Http2Error,
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

    pub fn init(allocator: std.mem.Allocator, stream: net.Stream, role: Role) !Transport {
        var transport = Transport{
            .stream = stream,
            .read_buf = try allocator.alloc(u8, 1024 * 64),
            .write_buf = try allocator.alloc(u8, 1024 * 64),
            .allocator = allocator,
            .http2_conn = null,
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
        self.allocator.free(self.read_buf);
        self.allocator.free(self.write_buf);
        self.stream.close();
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
                .SETTINGS, .PING, .WINDOW_UPDATE => continue,
                else => return TransportError.Http2Error,
            }
        }
    }

    pub fn writeMessage(self: *Transport, headers: *const std.StringHashMap([]const u8), message: []const u8, compression_alg: compression.Compression.Algorithm) !void {
        var data_frame = try http2.frame.Frame.init(self.allocator);
        defer data_frame.deinit(self.allocator);

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
