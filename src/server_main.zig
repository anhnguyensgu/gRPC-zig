const std = @import("std");
const GrpcServer = @import("server").GrpcServer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try GrpcServer.init(allocator, 50051, "secret-key");
    defer server.deinit();

    try server.handlers.append(.{
        .name = "SayHello",
        .handler_fn = sayHello,
    });

    try server.handlers.append(.{
        .name = "Benchmark",
        .handler_fn = benchmarkHandler,
    });

    try server.start();
}

fn sayHello(request: []const u8, allocator: std.mem.Allocator) ![]u8 {
    _ = request;
    return allocator.dupe(u8, "Hello from gRPC!");
}

fn benchmarkHandler(request: []const u8, allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(allocator, "Echo: {s} (processed at {})", .{
        request,
        std.time.milliTimestamp(),
    });
}
