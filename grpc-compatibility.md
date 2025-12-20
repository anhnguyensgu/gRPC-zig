# gRPC Compatibility Tracking (Zig 0.15 branch)

This library is not yet wire-compatible with gRPC. Below is the checklist of gaps to close.

## Transport & HTTP/2
- [ ] Send full HTTP/2 client/server preface and SETTINGS; honor peer SETTINGS.
- [ ] Use dynamic stream IDs per RPC; support concurrent streams.
- [ ] Implement flow control (WINDOW_UPDATE), PING/PONG, GOAWAY handling.
- [ ] Use TLS with ALPN `h2` for production interop.

## Headers & Routing
- [ ] Emit/parse required headers: `:method POST`, `:scheme`, `:authority`, `:path=/pkg.Service/Method`, `content-type: application/grpc`, `te: trailers`.
- [ ] Support optional headers: `grpc-timeout`, `grpc-encoding`, `grpc-accept-encoding`, `user-agent`, auth metadata.
- [ ] Route RPCs by `:path` rather than custom envelopes.

## Message Framing
- [ ] Use gRPC message envelope: 1-byte compressed flag + 4-byte big-endian length before payload.
- [ ] Allow multiple messages per stream for streaming RPCs.
- [ ] Integrate framing with HTTP/2 DATA frames (no custom transport envelope).

## Compression
- [ ] Negotiate compression via `grpc-encoding`/`grpc-accept-encoding`.
- [ ] Support `gzip` for payload compression; leave HTTP/2 framing uncompressed.
- [ ] Compress/decompress only the framed message bytes, not headers/trailers.

## Trailers & Status
- [ ] Terminate RPCs with HTTP/2 trailers carrying `grpc-status` and optional `grpc-message`, `grpc-status-details-bin`.
- [ ] Map transport errors to appropriate HTTP/2 status and grpc-status codes.

## Metadata
- [ ] Handle arbitrary metadata; support `-bin` keys with base64 values.
- [ ] Preserve metadata ordering where required; surface to handlers/clients.

## Streaming Semantics
- [ ] Support client/server/bidi streaming lifecycles: HEADERS to open, DATA frames with framed messages, END_STREAM with trailers.
- [ ] Cleanly cancel/reset streams; propagate errors to grpc-status.

## Security
- [ ] Support TLS/ALPN and optional mTLS.
- [ ] Implement spec-compliant auth flows (e.g., bearer tokens in metadata), not custom JWT.

## Compliance & Tests
- [ ] Add conformance-style tests for framing, headers, trailers, compression, and streaming.
- [ ] Interop test against a reference gRPC server/client (e.g., grpc-go or grpc-java).
