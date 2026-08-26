const std = @import("std");
const contract = @import("./contract.zig");
const direct = @import("./direct.zig");
const QuickJsEngine = @import("./engine_selector.zig").Implementation(.quickjs);

const Harness = struct {
    to_host: direct.CommandChannel,
    to_engine: direct.CommandChannel,
    data: direct.DataPool,
    implementation: QuickJsEngine,

    fn init(self: *Harness, allocator: std.mem.Allocator) !void {
        self.to_host = direct.CommandChannel.init(allocator);
        errdefer self.to_host.deinit();
        self.to_engine = direct.CommandChannel.init(allocator);
        errdefer self.to_engine.deinit();
        self.data = direct.DataPool.init(allocator);
        errdefer self.data.deinit();
        try self.implementation.init(allocator, .{ .io = .{
            .to_host = self.to_host.transport(),
            .to_engine = self.to_engine.transport(),
            .data = self.data.transport(),
        } });
    }

    fn deinit(self: *Harness) void {
        self.implementation.engine().destroy();
        self.data.deinit();
        self.to_engine.deinit();
        self.to_host.deinit();
    }

    fn load(self: *Harness, source: []const u8) !void {
        const source_ref = try self.data.copy(source);
        defer self.data.transport().release(source_ref);
        const name_ref = try self.data.copy("engine-test.js");
        defer self.data.transport().release(name_ref);
        try self.implementation.engine().load(source_ref, name_ref);
    }
};

fn runScript(source: []const u8) !void {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    try harness.load(source);
    try harness.implementation.engine().run();
    try std.testing.expectEqual(contract.Operation.engine_started, harness.to_host.transport().receive().?.operationKind());
    try std.testing.expectEqual(contract.Operation.engine_stopped, harness.to_host.transport().receive().?.operationKind());
}

test "QuickJS executes source buffers through Engine" {
    const scripts = [_][]const u8{
        "globalThis.answer = 6 * 7; if (answer !== 42) throw new Error('math');",
        "const values = [1, 2, 3, 4]; if (values.map(x => x * x).join(',') !== '1,4,9,16') throw new Error('array');",
        "const value = JSON.parse('{\"ok\":true,\"n\":9}'); if (!value.ok || value.n !== 9) throw new Error('json');",
    };
    for (scripts) |script| try runScript(script);
}

test "QuickJS reports script exceptions through Engine.run" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    try harness.load("throw new Error('expected')");
    try std.testing.expectError(error.EngineRunFailed, harness.implementation.engine().run());
}

test "QuickJS handles bundled SSR requests through command and data streams" {
    const source =
        \\globalThis.__crullerHandle = function(input) {
        \\  const request = JSON.parse(input);
        \\  const title = request.path === "/about" ? "About" : "Home";
        \\  return JSON.stringify({
        \\    status: 200,
        \\    headers: [["content-type", "text/html; charset=utf-8"]],
        \\    body: "<!doctype html><h1>" + title + "</h1>"
        \\  });
        \\};
    ;

    var harness: Harness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    try harness.load(source);

    const requests = [_][]const u8{
        "{\"method\":\"GET\",\"path\":\"/\",\"headers\":[],\"body\":\"\"}",
        "{\"method\":\"GET\",\"path\":\"/about\",\"headers\":[],\"body\":\"\"}",
    };
    for (requests, 1..) |request, request_id| {
        var command = contract.Command.init(.event, .server_request);
        command.request_id = request_id;
        command.payload = try harness.data.copy(request);
        try harness.to_engine.transport().send(command);
    }
    try harness.to_engine.transport().send(contract.Command.init(.shutdown, .none));

    try harness.implementation.engine().run();
    try std.testing.expectEqual(contract.Operation.engine_started, harness.to_host.transport().receive().?.operationKind());

    const expected = [_][]const u8{
        "{\"status\":200,\"headers\":[[\"content-type\",\"text/html; charset=utf-8\"]],\"body\":\"<!doctype html><h1>Home</h1>\"}",
        "{\"status\":200,\"headers\":[[\"content-type\",\"text/html; charset=utf-8\"]],\"body\":\"<!doctype html><h1>About</h1>\"}",
    };
    for (expected, 1..) |expected_response, request_id| {
        const response = harness.to_host.transport().receive().?;
        try std.testing.expectEqual(contract.Operation.server_response_end, response.operationKind());
        try std.testing.expectEqual(@as(u64, request_id), response.request_id);
        try std.testing.expectEqual(@as(i32, 0), response.status);
        try std.testing.expectEqualStrings(expected_response, (try harness.data.transport().map(response.payload)).slice());
        harness.data.transport().release(response.payload);
    }
    try std.testing.expectEqual(contract.Operation.engine_stopped, harness.to_host.transport().receive().?.operationKind());
}
