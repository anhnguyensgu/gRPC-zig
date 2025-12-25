const std = @import("std");
const ArrayList = std.array_list.Managed;

const c = @cImport({
    @cInclude("zlib.h");
});

pub const Compression = struct {
    pub const Algorithm = enum {
        none,
        gzip,
        deflate,
    };

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Compression {
        return .{ .allocator = allocator };
    }

    pub fn compress(self: *Compression, data: []const u8, algorithm: Algorithm) ![]u8 {
        switch (algorithm) {
            .none => return self.allocator.dupe(u8, data),
            .gzip, .deflate => return self.deflateImpl(data, algorithm),
        }
    }

    pub fn decompress(self: *Compression, data: []const u8, algorithm: Algorithm) ![]u8 {
        switch (algorithm) {
            .none => return self.allocator.dupe(u8, data),
            .gzip, .deflate => return self.inflateImpl(data, algorithm),
        }
    }

    fn windowBits(algorithm: Algorithm) i32 {
        return switch (algorithm) {
            .gzip => 15 + 16, // gzip header
            .deflate => 15, // zlib wrapper
            .none => 15,
        };
    }

    fn deflateImpl(self: *Compression, data: []const u8, algorithm: Algorithm) ![]u8 {
        var stream: c.z_stream = std.mem.zeroes(c.z_stream);
        stream.next_in = @ptrCast(@constCast(data.ptr));
        stream.avail_in = @intCast(data.len);

        const init_result = c.deflateInit2_(
            &stream,
            c.Z_DEFAULT_COMPRESSION,
            c.Z_DEFLATED,
            windowBits(algorithm),
            8,
            c.Z_DEFAULT_STRATEGY,
            c.zlibVersion(),
            @sizeOf(c.z_stream),
        );
        if (init_result != c.Z_OK) return error.CompressionFailed;
        defer _ = c.deflateEnd(&stream);

        var output = ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        var chunk: [16384]u8 = undefined;
        while (true) {
            stream.next_out = @ptrCast(chunk[0..].ptr);
            stream.avail_out = @intCast(chunk.len);

            const status = c.deflate(&stream, c.Z_FINISH);
            if (status == c.Z_STREAM_ERROR or status == c.Z_DATA_ERROR) return error.CompressionFailed;

            const written = chunk.len - @as(usize, stream.avail_out);
            try output.appendSlice(chunk[0..written]);

            if (status == c.Z_STREAM_END) break;
        }

        return output.toOwnedSlice();
    }

    fn inflateImpl(self: *Compression, data: []const u8, algorithm: Algorithm) ![]u8 {
        var stream: c.z_stream = std.mem.zeroes(c.z_stream);
        stream.next_in = @ptrCast(@constCast(data.ptr));
        stream.avail_in = @intCast(data.len);

        const init_result = c.inflateInit2_(
            &stream,
            windowBits(algorithm),
            c.zlibVersion(),
            @sizeOf(c.z_stream),
        );
        if (init_result != c.Z_OK) return error.DecompressionFailed;
        defer _ = c.inflateEnd(&stream);

        var output = ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        var chunk: [16384]u8 = undefined;
        while (true) {
            stream.next_out = @ptrCast(chunk[0..].ptr);
            stream.avail_out = @intCast(chunk.len);

            const status = c.inflate(&stream, c.Z_NO_FLUSH);
            if (status == c.Z_STREAM_ERROR or status == c.Z_DATA_ERROR or status == c.Z_MEM_ERROR) {
                return error.DecompressionFailed;
            }

            const written = chunk.len - @as(usize, stream.avail_out);
            try output.appendSlice(chunk[0..written]);

            if (status == c.Z_STREAM_END) break;
            if (stream.avail_in == 0 and written == 0) break;
        }

        return output.toOwnedSlice();
    }
};
