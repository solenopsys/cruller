const std = @import("std");
const contract = @import("./contract.zig");

pub const Handler = struct {
    context: *anyopaque,
    /// Return true after the terminal completion/event.
    on_message: *const fn (*anyopaque, contract.Command) bool,
};

/// VM-local completion registry. Handler pointers never enter a transport
/// message and are only invoked by the VM thread while draining to_engine.
pub const Bridge = struct {
    allocator: std.mem.Allocator,
    io: contract.Duplex,
    handlers: std.AutoHashMapUnmanaged(u64, Handler) = .empty,
    next_request_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, io: contract.Duplex) Bridge {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Bridge) void {
        _ = self.poll(std.math.maxInt(u32));
        self.handlers.deinit(self.allocator);
    }

    pub fn allocateRequestId(self: *Bridge) u64 {
        const id = self.next_request_id;
        self.next_request_id +%= 1;
        if (self.next_request_id == 0) self.next_request_id = 1;
        return id;
    }

    pub fn submit(self: *Bridge, command: contract.Command, handler: Handler) !void {
        if (command.messageKind() != .submit or command.request_id == 0)
            return error.InvalidSubmit;
        try self.handlers.put(self.allocator, command.request_id, handler);
        errdefer _ = self.handlers.remove(command.request_id);
        try self.io.to_host.send(command);
    }

    pub fn cancel(self: *Bridge, request_id: u64, operation: contract.Operation) !void {
        var command = contract.Command.init(.cancel, operation);
        command.request_id = request_id;
        try self.io.to_host.send(command);
    }

    pub fn send(self: *Bridge, command: contract.Command) !void {
        if (command.request_id == 0) return error.InvalidSubmit;
        try self.io.to_host.send(command);
    }

    pub fn setWaker(self: *Bridge, waker: contract.CommandTransport.Waker) void {
        self.io.to_engine.setWaker(waker);
    }

    pub fn poll(self: *Bridge, limit: u32) u32 {
        var count: u32 = 0;
        while (count < limit) {
            const command = self.io.to_engine.receive() orelse break;
            count += 1;
            self.dispatch(command);
        }
        return count;
    }

    pub fn dispatch(self: *Bridge, command: contract.Command) void {
        if (self.handlers.get(command.request_id)) |handler| {
            if (handler.on_message(handler.context, command))
                _ = self.handlers.remove(command.request_id);
        } else if (!command.payload.isEmpty()) {
            self.io.data.release(command.payload);
        }
    }
};

threadlocal var current: ?*Bridge = null;

pub fn install(bridge: *Bridge) void {
    current = bridge;
}

pub fn uninstall(bridge: *Bridge) void {
    if (current == bridge) current = null;
}

pub fn get() ?*Bridge {
    return current;
}

pub fn pollCurrent(limit: u32) u32 {
    return if (current) |bridge| bridge.poll(limit) else 0;
}

pub fn setCurrentWaker(waker: contract.CommandTransport.Waker) void {
    if (current) |bridge| bridge.setWaker(waker);
}
