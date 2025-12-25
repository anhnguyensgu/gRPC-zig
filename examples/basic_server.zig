const std = @import("std");
const GrpcServer = @import("server").GrpcServer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try GrpcServer.init(allocator, 50051, "");
    defer server.deinit();

    // Register handlers
    try server.handlers.append(.{
        .name = "SayHello",
        .handler_fn = sayHello,
    });
    
    // Register benchmark handler
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
    // Echo the request back with a timestamp for benchmarking
    const response = try std.fmt.allocPrint(allocator, "Echo: {s} (processed at {})", .{ request, std.time.milliTimestamp() });
    return response;
}
