const std = @import("std");
const ArrayList = std.array_list.Managed;
const transport = @import("transport.zig");
const compression = @import("features/compression.zig");
const auth = @import("features/auth.zig");
const health = @import("features/health.zig");

pub const Handler = struct {
    name: []const u8,
    handler_fn: *const fn ([]const u8, std.mem.Allocator) anyerror![]u8,
};

pub const GrpcServer = struct {
    allocator: std.mem.Allocator,
    address: std.net.Address,
    server: std.net.Server,
    handlers: ArrayList(Handler),
    compression: compression.Compression,
    auth: auth.Auth,
    health_check: health.HealthCheck,

    pub fn init(allocator: std.mem.Allocator, port: u16, secret_key: []const u8) !GrpcServer {
        const address = try std.net.Address.parseIp("127.0.0.1", port);
        return GrpcServer{
            .allocator = allocator,
            .address = address,
            .server = try std.net.Address.listen(address, .{}),
            .handlers = ArrayList(Handler).init(allocator),
            .compression = compression.Compression.init(allocator),
            .auth = auth.Auth.init(allocator, secret_key),
            .health_check = health.HealthCheck.init(allocator),
        };
    }

    pub fn deinit(self: *GrpcServer) void {
        self.handlers.deinit();
        self.server.deinit();
        self.health_check.deinit();
    }

    pub fn start(self: *GrpcServer) !void {
        try self.health_check.setStatus("grpc.health.v1.Health", .SERVING);
        std.log.info("Server listening on {any}", .{self.server.listen_address});

        while (true) {
            const connection = try self.server.accept();
            try self.handleConnection(connection);
        }
    }

    fn handleConnection(self: *GrpcServer, conn: std.net.Server.Connection) !void {
        var trans = try transport.Transport.init(self.allocator, conn.stream);
        defer trans.deinit();

        while (true) {
            var message = trans.readMessage() catch |err| switch (err) {
                error.ConnectionClosed => break,
                else => return err,
            };
            defer message.deinit();

            try self.auth.verifyToken(message.headers.get("authorization") orelse "");

            const decompressed = try self.compression.decompress(message.data, message.compression_algorithm);
            defer self.allocator.free(decompressed);

            for (self.handlers.items) |handler| {
                const response = try handler.handler_fn(decompressed, self.allocator);
                defer self.allocator.free(response);

                var response_headers = std.StringHashMap([]const u8).init(self.allocator);
                defer response_headers.deinit();

                try trans.writeMessage(&response_headers, response, message.compression_algorithm);
            }
        }
    }
};
