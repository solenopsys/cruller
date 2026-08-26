const std = @import("std");

pub const abi_version: u32 = 1;

pub const BufferRef = extern struct {
    pool_id: u32 = 0,
    buffer_id: u32 = 0,
    generation: u32 = 0,
    offset: u32 = 0,
    length: u32 = 0,

    pub fn isEmpty(self: BufferRef) bool {
        return self.length == 0;
    }
};

pub const MappedBuffer = extern struct {
    ptr: ?[*]u8 = null,
    len: usize = 0,

    pub fn slice(self: MappedBuffer) []u8 {
        if (self.len == 0) return &.{};
        return self.ptr.?[0..self.len];
    }
};

/// Transport-neutral access to bulk data. The direct implementation uses
/// heap allocations; a later implementation can map shared registered buffers
/// without changing either host or engine code.
pub const DataTransport = extern struct {
    context: ?*anyopaque,
    vtable: *const VTable,

    pub const VTable = extern struct {
        allocate: *const fn (?*anyopaque, usize, *BufferRef) callconv(.c) bool,
        map: *const fn (?*anyopaque, BufferRef, *MappedBuffer) callconv(.c) bool,
        retain: *const fn (?*anyopaque, BufferRef) callconv(.c) bool,
        release: *const fn (?*anyopaque, BufferRef) callconv(.c) void,
    };

    pub fn allocate(self: DataTransport, len: usize) error{ OutOfMemory, BufferTooLarge }!BufferRef {
        if (len > std.math.maxInt(u32)) return error.BufferTooLarge;
        var ref: BufferRef = .{};
        if (!self.vtable.allocate(self.context, len, &ref)) return error.OutOfMemory;
        return ref;
    }

    pub fn map(self: DataTransport, ref: BufferRef) error{InvalidBuffer}!MappedBuffer {
        var mapped: MappedBuffer = .{};
        if (!self.vtable.map(self.context, ref, &mapped)) return error.InvalidBuffer;
        return mapped;
    }

    pub fn retain(self: DataTransport, ref: BufferRef) error{InvalidBuffer}!void {
        if (!self.vtable.retain(self.context, ref)) return error.InvalidBuffer;
    }

    pub fn release(self: DataTransport, ref: BufferRef) void {
        self.vtable.release(self.context, ref);
    }
};

pub const MessageKind = enum(u16) {
    submit = 1,
    completion = 2,
    event = 3,
    cancel = 4,
    shutdown = 5,
    _,
};

/// Operations describe host-owned effects, not Bun modules. For example,
/// fetch is an HTTP resource opened by the VM and executed entirely by host.
pub const Operation = enum(u16) {
    none = 0,

    engine_loaded = 1,
    engine_started = 2,
    engine_stopped = 3,

    resource_open = 16,
    resource_close = 17,
    resource_read = 18,
    resource_write = 19,
    resource_control = 20,

    dns_resolve = 32,
    timer_arm = 33,
    random_fill = 34,

    http_request_start = 48,
    http_request_body = 49,
    http_request_end = 50,
    http_request_ready = 51,
    http_response_headers = 52,
    http_response_body = 53,
    http_response_end = 54,

    server_listen = 64,
    server_request = 65,
    server_response_start = 66,
    server_response_body = 67,
    server_response_end = 68,
    _,
};

pub const ResourceKind = enum(u8) {
    file = 1,
    tcp_stream = 2,
    tcp_listener = 3,
    udp_socket = 4,
    http_request = 5,
    http_server = 6,
    websocket = 7,
    process = 8,
    timer = 9,
    file_watch = 10,
    _,
};

pub const FileOpenFlags = packed struct(u32) {
    read: bool = false,
    write: bool = false,
    create: bool = false,
    truncate: bool = false,
    append: bool = false,
    exclusive: bool = false,
    _padding: u26 = 0,

    pub fn encode(self: FileOpenFlags) u64 {
        return @as(u64, @bitCast(self));
    }

    pub fn decode(value: u64) FileOpenFlags {
        return @bitCast(@as(u32, @truncate(value)));
    }
};

/// Fixed-layout wire message for both directions. Payload bytes always live in
/// DataTransport; pointers, file descriptors, JS values, and allocator-owned
/// slices must never appear here.
///
/// A non-empty payload transfers one owned reference when send succeeds. The
/// receiver must release it or transfer it in a later message. A failed send
/// leaves ownership with the sender.
pub const Command = extern struct {
    kind: u16 = @intFromEnum(MessageKind.submit),
    operation: u16 = @intFromEnum(Operation.none),
    status: i32 = 0,
    request_id: u64 = 0,
    resource_id: u64 = 0,
    payload: BufferRef = .{},
    arg0: u64 = 0,
    arg1: u64 = 0,

    pub fn init(kind: MessageKind, operation: Operation) Command {
        return .{
            .kind = @intFromEnum(kind),
            .operation = @intFromEnum(operation),
        };
    }

    pub fn messageKind(self: Command) MessageKind {
        return @enumFromInt(self.kind);
    }

    pub fn operationKind(self: Command) Operation {
        return @enumFromInt(self.operation);
    }
};

comptime {
    if (@sizeOf(Command) != 64) @compileError("Rt Command must remain exactly 64 bytes");
}

pub const CommandTransport = extern struct {
    context: ?*anyopaque,
    vtable: *const VTable,

    pub const VTable = extern struct {
        send: *const fn (?*anyopaque, *const Command) callconv(.c) bool,
        receive: *const fn (?*anyopaque, *Command) callconv(.c) bool,
        set_waker: *const fn (?*anyopaque, Waker) callconv(.c) void,
    };

    pub const Waker = extern struct {
        context: ?*anyopaque,
        wake: *const fn (?*anyopaque) callconv(.c) void,
    };

    pub fn send(self: CommandTransport, command: Command) error{TransportFull}!void {
        if (!self.vtable.send(self.context, &command)) return error.TransportFull;
    }

    pub fn receive(self: CommandTransport) ?Command {
        var command: Command = .{};
        if (!self.vtable.receive(self.context, &command)) return null;
        return command;
    }

    pub fn setWaker(self: CommandTransport, waker: Waker) void {
        self.vtable.set_waker(self.context, waker);
    }
};

pub const Duplex = extern struct {
    to_host: CommandTransport,
    to_engine: CommandTransport,
    data: DataTransport,
};

pub const EngineConfig = extern struct {
    abi: u32 = abi_version,
    flags: u32 = 0,
    io: Duplex,
};

/// Engine-neutral VM lifecycle. Concrete JSC/V8/QuickJS values never cross
/// this interface.
pub const Engine = extern struct {
    context: ?*anyopaque,
    vtable: *const VTable,

    pub const VTable = extern struct {
        load: *const fn (?*anyopaque, BufferRef, BufferRef) callconv(.c) i32,
        run: *const fn (?*anyopaque) callconv(.c) i32,
        poll: *const fn (?*anyopaque, u32) callconv(.c) u32,
        interrupt: *const fn (?*anyopaque) callconv(.c) void,
        destroy: *const fn (?*anyopaque) callconv(.c) void,
    };

    /// Load source bytes and a diagnostic module name. Neither buffer is a
    /// filesystem path and an engine must not perform I/O while loading it.
    pub fn load(self: Engine, source: BufferRef, name: BufferRef) error{EngineLoadFailed}!void {
        if (self.vtable.load(self.context, source, name) != 0) return error.EngineLoadFailed;
    }

    pub fn run(self: Engine) error{EngineRunFailed}!void {
        if (self.vtable.run(self.context) != 0) return error.EngineRunFailed;
    }

    pub fn poll(self: Engine, limit: u32) u32 {
        return self.vtable.poll(self.context, limit);
    }

    pub fn interrupt(self: Engine) void {
        self.vtable.interrupt(self.context);
    }

    pub fn destroy(self: Engine) void {
        self.vtable.destroy(self.context);
    }
};
