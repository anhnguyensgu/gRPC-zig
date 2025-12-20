const std = @import("std");

pub const FrameType = enum(u8) {
    DATA = 0x0,
    HEADERS = 0x1,
    PRIORITY = 0x2,
    RST_STREAM = 0x3,
    SETTINGS = 0x4,
    PUSH_PROMISE = 0x5,
    PING = 0x6,
    GOAWAY = 0x7,
    WINDOW_UPDATE = 0x8,
    CONTINUATION = 0x9,
};

pub const FrameFlags = struct {
    pub const END_STREAM = 0x1;
    pub const END_HEADERS = 0x4;
    pub const PADDED = 0x8;
    pub const PRIORITY = 0x20;
};

pub const Frame = struct {
    length: u24,
    type: FrameType,
    flags: u8,
    stream_id: u31,
    payload: []const u8,

    pub fn init(allocator: std.mem.Allocator) !Frame {
        return Frame{
            .length = 0,
            .type = .DATA,
            .flags = 0,
            .stream_id = 0,
            .payload = try allocator.alloc(u8, 0),
        };
    }

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
    }

    pub fn encode(self: Frame, writer: anytype) !void {
        var header: [9]u8 = undefined;
        std.mem.writeInt(u24, header[0..3], self.length, .big);
        header[3] = @intFromEnum(self.type);
        header[4] = self.flags;
        const stream_bits: u32 = @intCast(self.stream_id);
        std.mem.writeInt(u32, header[5..9], stream_bits, .big);

        try writer.writeAll(&header);
        try writer.writeAll(self.payload);
    }

    pub fn decode(reader: anytype, allocator: std.mem.Allocator) !Frame {
        var frame = try Frame.init(allocator);

        var header: [9]u8 = undefined;
        try reader.readSliceAll(&header);

        frame.length = std.mem.readInt(u24, header[0..3], .big);
        frame.type = @enumFromInt(header[3]);
        frame.flags = header[4];
        const raw_stream_id = std.mem.readInt(u32, header[5..9], .big);
        frame.stream_id = @intCast(raw_stream_id & 0x7fff_ffff);

        const payload = try allocator.alloc(u8, frame.length);
        try reader.readSliceAll(payload);
        frame.payload = payload;

        return frame;
    }
};
