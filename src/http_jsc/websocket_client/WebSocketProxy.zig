/// WebSocketProxy encapsulates proxy state for WebSocket connections through HTTP/HTTPS proxies.
/// This struct holds only the fields needed after the initial CONNECT request.
/// Fields like proxy_port, proxy_authorization, and proxy_headers are used
/// only during connect() and freed immediately after building the CONNECT request.
const WebSocketProxy = @This();

/// Target hostname for SNI during TLS handshake
priv_target_host: []const u8,
/// Whether target uses TLS (wss://)
priv_target_is_https: bool,
/// WebSocket upgrade request to send after CONNECT succeeds
priv_websocket_request_buf: []u8,
/// TLS tunnel for wss:// through HTTP proxy
priv_tunnel: ?*WebSocketProxyTunnel = null,

/// Initialize a new WebSocketProxy
pub fn init(
    target_host: []const u8,
    target_is_https: bool,
    websocket_request_buf: []u8,
) WebSocketProxy {
    return .{
        .priv_target_host = target_host,
        .priv_target_is_https = target_is_https,
        .priv_websocket_request_buf = websocket_request_buf,
    };
}

/// Get the target hostname for SNI during TLS handshake
pub fn getTargetHost(self: *const WebSocketProxy) []const u8 {
    return self.priv_target_host;
}

/// Check if the target uses HTTPS (wss://)
pub fn isTargetHttps(self: *const WebSocketProxy) bool {
    return self.priv_target_is_https;
}

/// Get the TLS tunnel for wss:// through HTTP proxy
pub fn getTunnel(self: *const WebSocketProxy) ?*WebSocketProxyTunnel {
    return self.priv_tunnel;
}

/// Set the TLS tunnel
pub fn setTunnel(self: *WebSocketProxy, new_tunnel: ?*WebSocketProxyTunnel) void {
    self.priv_tunnel = new_tunnel;
}

/// Take ownership of the WebSocket request buffer, clearing the internal reference.
/// The caller is responsible for freeing the returned buffer.
pub fn takeWebsocketRequestBuf(self: *WebSocketProxy) []u8 {
    const buf = self.priv_websocket_request_buf;
    self.priv_websocket_request_buf = &[_]u8{};
    return buf;
}

/// Clean up all allocated resources
pub fn deinit(self: *WebSocketProxy) void {
    bun.default_allocator.free(self.priv_target_host);
    if (self.priv_websocket_request_buf.len > 0) {
        bun.default_allocator.free(self.priv_websocket_request_buf);
    }
    if (self.priv_tunnel) |tunnel| {
        self.priv_tunnel = null;
        tunnel.shutdown();
        tunnel.deref();
    }
}

const WebSocketProxyTunnel = @import("./WebSocketProxyTunnel.zig");
const bun = @import("bun");
