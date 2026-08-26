const std = @import("std");
const builtin = @import("builtin");
const bun = @import("bun");
const contract = @import("./contract.zig");

const Mutex = if (builtin.is_test) TestMutex else bun.Mutex;

const TestMutex = struct {
    state: std.atomic.Mutex = .unlocked,

    fn lock(self: *TestMutex) void {
        while (!self.state.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *TestMutex) void {
        self.state.unlock();
    }
};

/// In-process command transport used by the production monolith. Replacing
/// this type with an SPSC implementation does not affect the contract.
pub const CommandChannel = struct {
    allocator: std.mem.Allocator,
    mutex: Mutex = .{},
    queue: std.array_list.Managed(contract.Command),
    read_index: usize = 0,
    waker: ?contract.CommandTransport.Waker = null,

    pub fn init(allocator: std.mem.Allocator) CommandChannel {
        return .{
            .allocator = allocator,
            .queue = std.array_list.Managed(contract.Command).init(allocator),
        };
    }

    pub fn deinit(self: *CommandChannel) void {
        self.queue.deinit();
    }

    pub fn transport(self: *CommandChannel) contract.CommandTransport {
        return .{ .context = self, .vtable = &vtable };
    }

    fn send(context: ?*anyopaque, command: *const contract.Command) callconv(.c) bool {
        const self: *CommandChannel = @ptrCast(@alignCast(context.?));
        self.mutex.lock();
        self.queue.append(command.*) catch {
            self.mutex.unlock();
            return false;
        };
        const waker = self.waker;
        self.mutex.unlock();
        if (waker) |value| value.wake(value.context);
        return true;
    }

    fn receive(context: ?*anyopaque, out: *contract.Command) callconv(.c) bool {
        const self: *CommandChannel = @ptrCast(@alignCast(context.?));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.read_index >= self.queue.items.len) return false;
        out.* = self.queue.items[self.read_index];
        self.read_index += 1;
        if (self.read_index == self.queue.items.len) {
            self.queue.clearRetainingCapacity();
            self.read_index = 0;
        }
        return true;
    }

    fn setWaker(context: ?*anyopaque, waker: contract.CommandTransport.Waker) callconv(.c) void {
        const self: *CommandChannel = @ptrCast(@alignCast(context.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.waker = waker;
    }

    const vtable: contract.CommandTransport.VTable = .{
        .send = send,
        .receive = receive,
        .set_waker = setWaker,
    };
};

/// Heap-backed data plane for the monolithic build. Buffers are identified by
/// stable IDs now, so moving storage to mmap/io_uring registered buffers later
/// does not alter the engine boundary.
pub const DataPool = struct {
    const pool_id: u32 = 1;

    const Slot = struct {
        bytes: ?[]u8 = null,
        generation: u32 = 1,
        refs: u32 = 0,
    };

    allocator: std.mem.Allocator,
    mutex: Mutex = .{},
    slots: std.array_list.Managed(Slot),

    pub fn init(allocator: std.mem.Allocator) DataPool {
        return .{
            .allocator = allocator,
            .slots = std.array_list.Managed(Slot).init(allocator),
        };
    }

    pub fn deinit(self: *DataPool) void {
        for (self.slots.items) |slot| {
            if (slot.bytes) |bytes| self.allocator.free(bytes);
        }
        self.slots.deinit();
    }

    pub fn transport(self: *DataPool) contract.DataTransport {
        return .{ .context = self, .vtable = &vtable };
    }

    pub fn copy(self: *DataPool, bytes: []const u8) !contract.BufferRef {
        const data = self.transport();
        const ref = try data.allocate(bytes.len);
        errdefer data.release(ref);
        const mapped = try data.map(ref);
        @memcpy(mapped.slice(), bytes);
        return ref;
    }

    fn allocate(context: ?*anyopaque, len: usize, out: *contract.BufferRef) callconv(.c) bool {
        if (len > std.math.maxInt(u32)) return false;
        const self: *DataPool = @ptrCast(@alignCast(context.?));
        const bytes = self.allocator.alloc(u8, len) catch return false;

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.slots.items, 0..) |*slot, index| {
            if (slot.bytes == null) {
                slot.bytes = bytes;
                slot.refs = 1;
                out.* = makeRef(index, slot.generation, len);
                return true;
            }
        }

        self.slots.append(.{ .bytes = bytes, .refs = 1 }) catch {
            self.allocator.free(bytes);
            return false;
        };
        const index = self.slots.items.len - 1;
        out.* = makeRef(index, self.slots.items[index].generation, len);
        return true;
    }

    fn map(context: ?*anyopaque, ref: contract.BufferRef, out: *contract.MappedBuffer) callconv(.c) bool {
        const self: *DataPool = @ptrCast(@alignCast(context.?));
        self.mutex.lock();
        defer self.mutex.unlock();

        const slot = self.getSlot(ref) orelse return false;
        const bytes = slot.bytes.?;
        const offset: usize = ref.offset;
        const length: usize = ref.length;
        if (offset > bytes.len or length > bytes.len - offset) return false;
        out.* = .{ .ptr = bytes.ptr + offset, .len = length };
        return true;
    }

    fn retain(context: ?*anyopaque, ref: contract.BufferRef) callconv(.c) bool {
        const self: *DataPool = @ptrCast(@alignCast(context.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = self.getSlot(ref) orelse return false;
        if (slot.refs == std.math.maxInt(u32)) return false;
        slot.refs += 1;
        return true;
    }

    fn release(context: ?*anyopaque, ref: contract.BufferRef) callconv(.c) void {
        const self: *DataPool = @ptrCast(@alignCast(context.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = self.getSlot(ref) orelse return;
        if (slot.refs == 0) return;
        slot.refs -= 1;
        if (slot.refs != 0) return;

        self.allocator.free(slot.bytes.?);
        slot.bytes = null;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
    }

    fn getSlot(self: *DataPool, ref: contract.BufferRef) ?*Slot {
        if (ref.pool_id != pool_id) return null;
        const index: usize = ref.buffer_id;
        if (index >= self.slots.items.len) return null;
        const slot = &self.slots.items[index];
        if (slot.bytes == null or slot.generation != ref.generation) return null;
        return slot;
    }

    fn makeRef(index: usize, generation: u32, len: usize) contract.BufferRef {
        return .{
            .pool_id = pool_id,
            .buffer_id = @intCast(index),
            .generation = generation,
            .length = @intCast(len),
        };
    }

    const vtable: contract.DataTransport.VTable = .{
        .allocate = allocate,
        .map = map,
        .retain = retain,
        .release = release,
    };
};

test "command channel preserves FIFO order" {
    var channel = CommandChannel.init(std.testing.allocator);
    defer channel.deinit();

    const transport = channel.transport();
    var first = contract.Command.init(.submit, .resource_read);
    first.request_id = 41;
    var second = contract.Command.init(.cancel, .resource_read);
    second.request_id = 42;
    try transport.send(first);
    try transport.send(second);

    try std.testing.expectEqual(@as(u64, 41), transport.receive().?.request_id);
    try std.testing.expectEqual(@as(u64, 42), transport.receive().?.request_id);
    try std.testing.expect(transport.receive() == null);
}

test "data pool invalidates released buffer references" {
    var pool = DataPool.init(std.testing.allocator);
    defer pool.deinit();

    const transport = pool.transport();
    const old_ref = try pool.copy("entry.ts");
    try std.testing.expectEqualStrings("entry.ts", (try transport.map(old_ref)).slice());
    transport.release(old_ref);
    try std.testing.expectError(error.InvalidBuffer, transport.map(old_ref));

    const new_ref = try pool.copy("next.ts");
    defer transport.release(new_ref);
    try std.testing.expect(new_ref.generation != old_ref.generation);
}
