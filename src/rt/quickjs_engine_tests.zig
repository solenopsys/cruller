const std = @import("std");
const contract = @import("./contract.zig");
const QuickJsEngine = @import("./engine_selector.zig").Implementation(.quickjs);

const Channel = struct {
    items: [8]contract.Command = undefined,
    read_index: usize = 0,
    write_index: usize = 0,

    fn transport(self: *Channel) contract.CommandTransport {
        return .{ .context = self, .vtable = &vtable };
    }
    fn send(context: ?*anyopaque, command: *const contract.Command) callconv(.c) bool {
        const self: *Channel = @ptrCast(@alignCast(context.?));
        if (self.write_index == self.items.len) return false;
        self.items[self.write_index] = command.*;
        self.write_index += 1;
        return true;
    }
    fn receive(context: ?*anyopaque, out: *contract.Command) callconv(.c) bool {
        const self: *Channel = @ptrCast(@alignCast(context.?));
        if (self.read_index == self.write_index) return false;
        out.* = self.items[self.read_index];
        self.read_index += 1;
        return true;
    }
    fn setWaker(_: ?*anyopaque, _: contract.CommandTransport.Waker) callconv(.c) void {}
    const vtable: contract.CommandTransport.VTable = .{ .send = send, .receive = receive, .set_waker = setWaker };
};

const Data = struct {
    source: []const u8,
    name: []const u8,

    fn transport(self: *Data) contract.DataTransport {
        return .{ .context = self, .vtable = &vtable };
    }
    fn allocate(_: ?*anyopaque, _: usize, _: *contract.BufferRef) callconv(.c) bool {
        return false;
    }
    fn map(context: ?*anyopaque, ref: contract.BufferRef, out: *contract.MappedBuffer) callconv(.c) bool {
        const self: *Data = @ptrCast(@alignCast(context.?));
        const bytes = switch (ref.buffer_id) {
            1 => self.source,
            2 => self.name,
            else => return false,
        };
        out.* = .{ .ptr = @constCast(bytes.ptr), .len = bytes.len };
        return true;
    }
    fn retain(_: ?*anyopaque, _: contract.BufferRef) callconv(.c) bool {
        return true;
    }
    fn release(_: ?*anyopaque, _: contract.BufferRef) callconv(.c) void {}
    const vtable: contract.DataTransport.VTable = .{
        .allocate = allocate,
        .map = map,
        .retain = retain,
        .release = release,
    };
};

fn runScript(source: []const u8) !void {
    var to_host: Channel = .{};
    var to_engine: Channel = .{};
    var data: Data = .{ .source = source, .name = "engine-test.js" };
    var implementation: QuickJsEngine = undefined;
    try implementation.init(std.testing.allocator, .{ .io = .{
        .to_host = to_host.transport(),
        .to_engine = to_engine.transport(),
        .data = data.transport(),
    } });
    const engine = implementation.engine();
    defer engine.destroy();
    try engine.load(.{ .buffer_id = 1, .length = @intCast(source.len) }, .{ .buffer_id = 2, .length = @intCast(data.name.len) });
    try engine.run();
    try std.testing.expectEqual(contract.Operation.engine_started, to_host.transport().receive().?.operationKind());
    try std.testing.expectEqual(contract.Operation.engine_stopped, to_host.transport().receive().?.operationKind());
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
    var to_host: Channel = .{};
    var to_engine: Channel = .{};
    var data: Data = .{ .source = "throw new Error('expected')", .name = "failure.js" };
    var implementation: QuickJsEngine = undefined;
    try implementation.init(std.testing.allocator, .{ .io = .{
        .to_host = to_host.transport(),
        .to_engine = to_engine.transport(),
        .data = data.transport(),
    } });
    const engine = implementation.engine();
    defer engine.destroy();
    try engine.load(.{ .buffer_id = 1, .length = @intCast(data.source.len) }, .{ .buffer_id = 2, .length = @intCast(data.name.len) });
    try std.testing.expectError(error.EngineRunFailed, engine.run());
}
