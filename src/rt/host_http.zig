const std = @import("std");
const bun = @import("bun");
const contract = @import("./contract.zig");
const wire = @import("./http_wire.zig");

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: contract.Duplex,
    mutex: bun.Mutex = .{},
    requests: std.AutoHashMapUnmanaged(u64, *Request) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: contract.Duplex) Manager {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn start(self: *Manager, command: contract.Command) void {
        defer if (!command.payload.isEmpty()) self.io.data.release(command.payload);
        Request.create(self, command) catch |err| {
            var completion = contract.Command.init(.completion, .http_response_end);
            completion.request_id = command.request_id;
            completion.status = switch (err) {
                error.OutOfMemory => -12,
                else => -22,
            };
            self.io.to_engine.send(completion) catch {};
        };
    }

    pub fn cancel(self: *Manager, command: contract.Command) void {
        self.mutex.lock();
        const request = self.requests.get(command.request_id);
        self.mutex.unlock();
        if (request) |value| bun.http.http_thread.scheduleShutdown(&value.http);
    }

    pub fn writeBody(self: *Manager, command: contract.Command) void {
        defer if (!command.payload.isEmpty()) self.io.data.release(command.payload);
        const request = self.find(command.request_id) orelse return;
        const buffer = request.stream_buffer orelse return;
        const mapped = self.io.data.map(command.payload) catch return;
        const acquired = buffer.acquire();
        defer buffer.release();
        _ = acquired.write(mapped.slice()) catch return;
        bun.http.http_thread.scheduleRequestWrite(&request.http, .data);
    }

    pub fn endBody(self: *Manager, command: contract.Command) void {
        const request = self.find(command.request_id) orelse return;
        bun.http.http_thread.scheduleRequestWrite(&request.http, .end);
    }

    fn find(self: *Manager, request_id: u64) ?*Request {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.requests.get(request_id);
    }

    fn add(self: *Manager, request: *Request) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requests.put(self.allocator, request.request_id, request);
    }

    fn remove(self: *Manager, request_id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.requests.remove(request_id);
    }
};

const Request = struct {
    manager: *Manager,
    request_id: u64,
    wire_bytes: []u8,
    headers: bun.http.Headers,
    response_buffer: bun.MutableString,
    stream_buffer: ?*bun.http.ThreadSafeStreamBuffer = null,
    http: bun.http.AsyncHTTP,

    fn create(manager: *Manager, command: contract.Command) !void {
        const mapped = try manager.io.data.map(command.payload);
        const wire_bytes = try manager.allocator.dupe(u8, mapped.slice());
        errdefer manager.allocator.free(wire_bytes);
        const decoded = try wire.decodeRequest(wire_bytes);
        if (decoded.prefix.method > @intFromEnum(bun.http.Method.UNSUBSCRIBE)) return error.InvalidMethod;

        var self = try manager.allocator.create(Request);
        errdefer manager.allocator.destroy(self);
        self.* = .{
            .manager = manager,
            .request_id = command.request_id,
            .wire_bytes = wire_bytes,
            .headers = .{ .allocator = manager.allocator },
            .response_buffer = .{ .allocator = manager.allocator, .list = .empty },
            .http = undefined,
        };
        errdefer self.headers.deinit();
        for (0..decoded.prefix.header_count) |index| {
            const header = decoded.header(index).?;
            try self.headers.append(header.name, header.value);
        }

        const flags: wire.RequestFlags = @bitCast(decoded.prefix.flags);
        const proxy_bytes = range(decoded.bytes, decoded.prefix.proxy);
        const proxy = if (proxy_bytes.len > 0) bun.URL.parse(proxy_bytes) else null;
        const hostname = range(decoded.bytes, decoded.prefix.hostname);
        const unix_socket = range(decoded.bytes, decoded.prefix.unix_socket);
        const redirect: bun.http.FetchRedirect = @enumFromInt(decoded.prefix.redirect);
        self.http = bun.http.AsyncHTTP.init(
            manager.allocator,
            @enumFromInt(decoded.prefix.method),
            bun.URL.parse(decoded.url()),
            self.headers.entries,
            self.headers.buf.items,
            &self.response_buffer,
            decoded.body(),
            bun.http.HTTPClientResult.Callback.New(*Request, callback).init(self),
            redirect,
            .{
                .http_proxy = proxy,
                .hostname = if (hostname.len > 0) @constCast(hostname) else null,
                .unix_socket_path = if (unix_socket.len > 0) bun.jsc.ZigString.Slice.init(manager.allocator, unix_socket) else null,
                .disable_timeout = flags.disable_timeout,
                .disable_keepalive = flags.disable_keepalive,
                .disable_decompression = flags.disable_decompression,
                .reject_unauthorized = flags.reject_unauthorized,
            },
        );
        self.http.client.flags.force_http1 = flags.force_http1;
        self.http.client.flags.force_http2 = flags.force_http2;
        self.http.client.flags.force_http3 = flags.force_http3;
        if (flags.streaming_body) {
            const buffer = bun.http.ThreadSafeStreamBuffer.new(.{});
            self.stream_buffer = buffer;
            self.http.client.flags.is_streaming_request_body = true;
            self.http.request_body = .{ .stream = .{ .buffer = buffer, .ended = false } };
        }

        try manager.add(self);
        errdefer manager.remove(self.request_id);
        bun.http.HTTPThread.init(&.{});
        var batch: bun.ThreadPool.Batch = .{};
        self.http.schedule(manager.allocator, &batch);
        bun.http.http_thread.schedule(batch);
    }

    fn callback(self: *Request, _: *bun.http.AsyncHTTP, result: bun.http.HTTPClientResult) void {
        if (result.can_stream) {
            var ready = contract.Command.init(.event, .http_request_ready);
            ready.request_id = self.request_id;
            ready.arg0 = @intFromBool(result.is_http2);
            self.manager.io.to_engine.send(ready) catch {};
        }
        if (result.metadata) |metadata_value| {
            var metadata = metadata_value;
            defer metadata.deinit(self.manager.allocator);
            self.sendMetadata(metadata) catch self.sendTerminal(-12, 3);
        }

        if (result.body) |body| {
            if (body.list.items.len > 0) {
                self.sendBytes(.event, .http_response_body, body.list.items, 0, 0) catch self.sendTerminal(-12, 3);
                body.reset();
            }
        }

        if (!result.has_more) {
            const reason: u64 = if (result.isTimeout()) 1 else if (result.isAbort()) 2 else if (!result.isSuccess()) 3 else 0;
            self.sendTerminal(if (result.isSuccess()) 0 else -5, reason);
            self.destroy();
        }
    }

    fn sendMetadata(self: *Request, metadata: bun.http.HTTPResponseMetadata) !void {
        const response_headers = metadata.response.headers.list;
        var headers = try self.manager.allocator.alloc(wire.Header, response_headers.len);
        defer self.manager.allocator.free(headers);
        for (response_headers, 0..) |header, index| {
            headers[index] = .{ .name = header.name, .value = header.value };
        }
        const encoded = try wire.encodeResponse(self.manager.allocator, .{
            .status_code = metadata.response.status_code,
            .url = metadata.url,
            .status_text = metadata.response.status,
            .headers = headers,
        });
        defer self.manager.allocator.free(encoded);
        try self.sendBytes(.event, .http_response_headers, encoded, 0, 0);
    }

    fn sendTerminal(self: *Request, status: i32, reason: u64) void {
        var command = contract.Command.init(.completion, .http_response_end);
        command.request_id = self.request_id;
        command.status = status;
        command.arg0 = reason;
        self.manager.io.to_engine.send(command) catch {};
    }

    fn sendBytes(self: *Request, kind: contract.MessageKind, operation: contract.Operation, bytes: []const u8, status: i32, arg0: u64) !void {
        const ref = try self.manager.io.data.allocate(bytes.len);
        errdefer self.manager.io.data.release(ref);
        const mapped = try self.manager.io.data.map(ref);
        @memcpy(mapped.slice(), bytes);
        var command = contract.Command.init(kind, operation);
        command.request_id = self.request_id;
        command.status = status;
        command.arg0 = arg0;
        command.payload = ref;
        try self.manager.io.to_engine.send(command);
    }

    fn destroy(self: *Request) void {
        self.manager.remove(self.request_id);
        if (self.stream_buffer) |buffer| buffer.deref();
        self.headers.deinit();
        self.response_buffer.deinit();
        self.manager.allocator.free(self.wire_bytes);
        self.manager.allocator.destroy(self);
    }

    fn range(bytes: []const u8, value: wire.Range) []const u8 {
        return bytes[value.offset..][0..value.length];
    }
};
