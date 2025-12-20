const std = @import("std");
const ArrayList = std.array_list.Managed;
const crypto = std.crypto;

pub const AuthError = error{
    InvalidToken,
    Unauthorized,
    TokenExpired,
};

pub const Auth = struct {
    const TokenHeader = struct {
        alg: []const u8,
        typ: []const u8,
    };

    const TokenPayload = struct {
        sub: []const u8,
        exp: i64,
        iat: i64,
    };

    secret_key: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, secret_key: []const u8) Auth {
        return .{
            .allocator = allocator,
            .secret_key = secret_key,
        };
    }

    pub fn verifyToken(self: *Auth, token: []const u8) !void {
        // Basic JWT verification
        var parts = std.mem.splitScalar(u8, token, '.');
        const header_b64 = parts.next() orelse return AuthError.InvalidToken;
        const payload_b64 = parts.next() orelse return AuthError.InvalidToken;
        const signature = parts.next() orelse return AuthError.InvalidToken;

        // Verify signature
        var hash = crypto.auth.hmac.sha2.HmacSha256.init(self.secret_key);
        hash.update(header_b64);
        hash.update(".");
        hash.update(payload_b64);
        
        var expected_signature: [crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
        hash.final(&expected_signature);

        if (!std.mem.eql(u8, signature, &expected_signature)) {
            return AuthError.InvalidToken;
        }
    }

    pub fn generateToken(self: *Auth, subject: []const u8, expires_in: i64) ![]u8 {
        const now = std.time.timestamp();
        
        const header = TokenHeader{
            .alg = "HS256",
            .typ = "JWT",
        };

        const payload = TokenPayload{
            .sub = subject,
            .exp = now + expires_in,
            .iat = now,
        };

        const header_json = try std.json.Stringify.valueAlloc(self.allocator, header, .{});
        defer self.allocator.free(header_json);

        const payload_json = try std.json.Stringify.valueAlloc(self.allocator, payload, .{});
        defer self.allocator.free(payload_json);

        var token = ArrayList(u8).init(self.allocator);
        defer token.deinit();

        try token.appendSlice(header_json);
        try token.append('.');
        try token.appendSlice(payload_json);

        return token.toOwnedSlice();
    }
};
