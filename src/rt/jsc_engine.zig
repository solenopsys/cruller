const std = @import("std");
const bun = @import("bun");
const contract = @import("./contract.zig");
const vm_bridge = @import("./vm_bridge.zig");

/// Thin production adapter around the existing JSC-backed runtime. Concrete
/// JSC values remain behind the transport-neutral engine contract.
pub const JscEngine = struct {
    allocator: std.mem.Allocator,
    config: contract.EngineConfig,
    bridge: vm_bridge.Bridge,
    source: ?[]u8 = null,
    name: ?[]u8 = null,
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

        bun.bun_js.runSource(self.allocator, self.source.?, self.name.?) catch return 3;
        self.config.io.to_host.send(contract.Command.init(.event, .engine_stopped)) catch return 4;
        return 0;
    }

    fn poll(context: ?*anyopaque, limit: u32) callconv(.c) u32 {
        const self: *JscEngine = @ptrCast(@alignCast(context.?));
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
