const std = @import("std");
const contract = @import("./contract.zig");
const vm_bridge = @import("./vm_bridge.zig");
const http_wire = @import("./http_wire.zig");

const TestChannel = struct {
    items: [8]contract.Command = undefined,
    read_index: usize = 0,
    write_index: usize = 0,

    fn transport(self: *TestChannel) contract.CommandTransport {
        return .{ .context = self, .vtable = &vtable };
    }

    fn send(context: ?*anyopaque, command: *const contract.Command) callconv(.c) bool {
        const self: *TestChannel = @ptrCast(@alignCast(context.?));
        if (self.write_index == self.items.len) return false;
        self.items[self.write_index] = command.*;
        self.write_index += 1;
        return true;
    }

    fn receive(context: ?*anyopaque, out: *contract.Command) callconv(.c) bool {
        const self: *TestChannel = @ptrCast(@alignCast(context.?));
        if (self.read_index == self.write_index) return false;
        out.* = self.items[self.read_index];
        self.read_index += 1;
        return true;
    }

    fn setWaker(_: ?*anyopaque, _: contract.CommandTransport.Waker) callconv(.c) void {}

    const vtable: contract.CommandTransport.VTable = .{ .send = send, .receive = receive, .set_waker = setWaker };
};

const TestData = struct {
    fn transport() contract.DataTransport {
        return .{ .context = null, .vtable = &vtable };
    }

    fn allocate(_: ?*anyopaque, _: usize, _: *contract.BufferRef) callconv(.c) bool {
        return false;
    }
    fn map(_: ?*anyopaque, _: contract.BufferRef, _: *contract.MappedBuffer) callconv(.c) bool {
        return false;
    }
    fn retain(_: ?*anyopaque, _: contract.BufferRef) callconv(.c) bool {
        return false;
    }
    fn release(_: ?*anyopaque, _: contract.BufferRef) callconv(.c) void {}

    const vtable: contract.DataTransport.VTable = .{
        .allocate = allocate,
        .map = map,
        .retain = retain,
        .release = release,
    };
};

test "VM submit is completed only by polling the host-to-engine stream" {
    var to_host: TestChannel = .{};
    var to_engine: TestChannel = .{};

    const io: contract.Duplex = .{
        .to_host = to_host.transport(),
        .to_engine = to_engine.transport(),
        .data = TestData.transport(),
    };
    var bridge = vm_bridge.Bridge.init(std.testing.allocator, io);
    defer bridge.deinit();

    const State = struct {
        called: bool = false,
        status: i32 = 0,

        fn onMessage(context: *anyopaque, command: contract.Command) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.called = true;
            self.status = command.status;
            return true;
        }
    };
    var state: State = .{};
    var submit = contract.Command.init(.submit, .resource_open);
    submit.request_id = bridge.allocateRequestId();
    try bridge.submit(submit, .{ .context = &state, .on_message = State.onMessage });

    const host_command = io.to_host.receive().?;
    try std.testing.expectEqual(contract.MessageKind.submit, host_command.messageKind());
    try std.testing.expect(!state.called);

    var completion = contract.Command.init(.completion, host_command.operationKind());
    completion.request_id = host_command.request_id;
    completion.status = -5;
    try io.to_engine.send(completion);
    try std.testing.expectEqual(@as(u32, 1), bridge.poll(1));
    try std.testing.expect(state.called);
    try std.testing.expectEqual(@as(i32, -5), state.status);
    try std.testing.expectEqual(@as(usize, 0), bridge.handlers.count());
}

test "HTTP wire codec rejects offsets outside the data buffer" {
    const headers = [_]http_wire.Header{
        .{ .name = "accept", .value = "application/json" },
        .{ .name = "x-test", .value = "yes" },
    };
    const bytes = try http_wire.encodeRequest(std.testing.allocator, .{
        .method = 1,
        .url = "https://example.com/data",
        .headers = &headers,
        .body = "payload",
    });
    defer std.testing.allocator.free(bytes);

    const decoded = try http_wire.decodeRequest(bytes);
    try std.testing.expectEqualStrings("https://example.com/data", decoded.url());
    try std.testing.expectEqualStrings("application/json", decoded.header(0).?.value);
    try std.testing.expectEqualStrings("payload", decoded.body());

    var corrupt = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupt);
    var prefix = std.mem.bytesAsValue(http_wire.RequestPrefix, corrupt[0..@sizeOf(http_wire.RequestPrefix)]);
    prefix.url.offset = std.math.maxInt(u32);
    try std.testing.expectError(error.InvalidPayload, http_wire.decodeRequest(corrupt));
}
