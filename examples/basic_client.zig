const std = @import("std");
const GrpcClient = @import("client").GrpcClient;
const authpb = @import("auth.pb.zig");
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try GrpcClient.init(allocator, "localhost", 50051);
    defer client.deinit();

    // Set authentication
    // try client.setAuth("secret-key");

    // Build a protobuf LoginRequest.
    var encoder = std.Io.Writer.Allocating.init(allocator);
    defer encoder.deinit();

    const email = "test@example.com";
    const password = "password123";
    const login_request = authpb.LoginRequest{
        .username = email,
        .password = password,
    };
    try login_request.encode(&encoder.writer, allocator);

    const request_bytes = try encoder.toOwnedSlice();
    defer allocator.free(request_bytes);

    // Make a gRPC unary call with the protobuf-encoded payload.
    // Update the path to match your Tonic service definition.
    const response_bytes = client.callGrpcUnary("/auth.AuthService/Login", request_bytes) catch |err| {
        if (err == error.GrpcStatusNotOk) {
            if (client.lastGrpcStatus()) |status| {
                std.debug.print("gRPC error: status={}, message={s}\n", .{
                    status.code,
                    status.message orelse "",
                });
            } else {
                std.debug.print("gRPC error: status unknown\n", .{});
            }
            return;
        }
        return err;
    };
    defer allocator.free(response_bytes);

    // Try to decode protobuf response; fall back to raw bytes.
    var reader = std.Io.Reader.fixed(response_bytes);
    var login_response = authpb.LoginResponse.decode(&reader, allocator) catch |err| {
        std.debug.print("Login response decode failed: {}\nRaw: {s}\n", .{ err, response_bytes });
        return;
    };
    defer login_response.deinit(allocator);

    std.debug.print("Login success: {}, message: {s}\n", .{ login_response.success, login_response.message });
    if (login_response.token.len != 0) {
        std.debug.print("Token: {s}\n", .{login_response.token});
    }
}
