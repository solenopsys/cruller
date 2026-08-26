const std = @import("std");
const bun = @import("bun");
const contract = @import("./contract.zig");
const vm_bridge = @import("./vm_bridge.zig");
const server_dispatch = @import("./server_dispatch.zig");

/// Thin production adapter around the existing JSC-backed runtime. Concrete
/// JSC values remain behind the transport-neutral engine contract.
pub const JscEngine = struct {
    allocator: std.mem.Allocator,
    config: contract.EngineConfig,
    bridge: vm_bridge.Bridge,
    source: ?[]u8 = null,
    name: ?[]u8 = null,
    global: ?*bun.jsc.JSGlobalObject = null,
    state: State = .created,

    const State = enum { created, loaded, running, destroyed };

    pub fn init(self: *JscEngine, allocator: std.mem.Allocator, config: contract.EngineConfig) !void {
        if (config.abi != contract.abi_version) return error.UnsupportedRuntimeAbi;
        self.* = .{
            .allocator = allocator,
            .config = config,
            .bridge = vm_bridge.Bridge.init(allocator, config.io),
        };
    }

    pub fn engine(self: *JscEngine) contract.Engine {
        return .{ .context = self, .vtable = &vtable };
    }

    fn load(context: ?*anyopaque, source_ref: contract.BufferRef, name_ref: contract.BufferRef) callconv(.c) i32 {
        const self: *JscEngine = @ptrCast(@alignCast(context.?));
        if (self.state != .created) return 1;
        const source = (self.config.io.data.map(source_ref) catch return 2).slice();
        const name = (self.config.io.data.map(name_ref) catch return 3).slice();
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null) return 4;
        self.source = self.allocator.dupe(u8, source) catch return 5;
        self.name = self.allocator.dupe(u8, name) catch {
            self.allocator.free(self.source.?);
            self.source = null;
            return 5;
        };

        self.state = .loaded;
        return 0;
    }

    fn run(context: ?*anyopaque) callconv(.c) i32 {
        const self: *JscEngine = @ptrCast(@alignCast(context.?));
        if (self.state != .loaded) return 1;
        self.state = .running;
        self.config.io.to_host.send(contract.Command.init(.event, .engine_started)) catch return 2;
        vm_bridge.install(&self.bridge);
        defer vm_bridge.uninstall(&self.bridge);

        bun.bun_js.runSourceWithHook(self.allocator, self.source.?, self.name.?, .{
            .context = self,
            .call = sourceLoaded,
        }) catch return 3;
        self.config.io.to_host.send(contract.Command.init(.event, .engine_stopped)) catch return 4;
        return 0;
    }

    fn sourceLoaded(context: *anyopaque, global: *bun.jsc.JSGlobalObject) void {
        const self: *JscEngine = @ptrCast(@alignCast(context));
        const maybe_function = global.toJSValue().get(global, server_dispatch.handler_name) catch return;
        const function = maybe_function orelse return;
        if (!function.isCallable()) return;

        self.global = global;
        defer self.global = null;
        while (true) {
            const result = self.pumpServer(std.math.maxInt(u32));
            if (result.stopped) break;
            if (result.processed == 0) bun.compat.nanosleep(0, 100_000);
        }
    }

    fn pumpServer(self: *JscEngine, limit: u32) server_dispatch.PumpResult {
        return server_dispatch.pump(self.allocator, self.config.io, &self.bridge, .{
            .context = self,
            .call = callHandler,
        }, limit);
    }

    fn callHandler(context: *anyopaque, input: []const u8, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *JscEngine = @ptrCast(@alignCast(context));
        const global = self.global orelse return error.EngineNotRunning;
        const function = (try global.toJSValue().get(global, server_dispatch.handler_name)) orelse
            return error.HandlerMissing;
        if (!function.isCallable()) return error.HandlerMissing;

        var input_string = bun.jsc.ZigString.init(input);
        const value = try function.call(global, global.toJSValue(), &.{input_string.toJS(global)});
        return try value.toUTF8Bytes(global, allocator);
    }

    fn poll(context: ?*anyopaque, limit: u32) callconv(.c) u32 {
        const self: *JscEngine = @ptrCast(@alignCast(context.?));
        if (self.global != null) return self.pumpServer(limit).processed;
        return self.bridge.poll(limit);
    }

    fn interrupt(context: ?*anyopaque) callconv(.c) void {
        const self: *JscEngine = @ptrCast(@alignCast(context.?));
        _ = self;
        if (bun.jsc.VirtualMachine.getOrNull()) |vm| vm.jsc_vm.notifyNeedTermination();
    }

    fn destroy(context: ?*anyopaque) callconv(.c) void {
        const self: *JscEngine = @ptrCast(@alignCast(context.?));
        if (self.state == .destroyed) return;
        if (self.source) |source| self.allocator.free(source);
        if (self.name) |name| self.allocator.free(name);
        self.source = null;
        self.name = null;
        self.bridge.deinit();
        self.state = .destroyed;
    }

    const vtable: contract.Engine.VTable = .{
        .load = load,
        .run = run,
        .poll = poll,
        .interrupt = interrupt,
        .destroy = destroy,
    };
};
