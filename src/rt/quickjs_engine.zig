const std = @import("std");
const contract = @import("./contract.zig");
const qjs = @import("./qjs_api.zig");
const vm_bridge = @import("./vm_bridge.zig");
const server_dispatch = @import("./server_dispatch.zig");

/// QuickJS implementation of the same source-buffer Engine contract as JSC.
/// It deliberately exposes no filesystem or network API to JavaScript.
pub const QuickJsEngine = struct {
    allocator: std.mem.Allocator,
    config: contract.EngineConfig,
    bridge: vm_bridge.Bridge,
    runtime: ?*qjs.Runtime,
    source: ?[]u8 = null,
    name: ?[]u8 = null,
    state: State = .created,

    const State = enum { created, loaded, running, destroyed };

    pub fn init(self: *QuickJsEngine, allocator: std.mem.Allocator, config: contract.EngineConfig) !void {
        if (config.abi != contract.abi_version) return error.UnsupportedRuntimeAbi;
        const runtime = qjs.qjs_rt_new() orelse return error.OutOfMemory;
        self.* = .{
            .allocator = allocator,
            .config = config,
            .bridge = vm_bridge.Bridge.init(allocator, config.io),
            .runtime = runtime,
        };
    }

    pub fn engine(self: *QuickJsEngine) contract.Engine {
        return .{ .context = self, .vtable = &vtable };
    }

    fn load(context: ?*anyopaque, source_ref: contract.BufferRef, name_ref: contract.BufferRef) callconv(.c) i32 {
        const self: *QuickJsEngine = @ptrCast(@alignCast(context.?));
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
        const self: *QuickJsEngine = @ptrCast(@alignCast(context.?));
        if (self.state != .loaded) return 1;
        self.state = .running;
        self.config.io.to_host.send(contract.Command.init(.event, .engine_started)) catch return 2;
        vm_bridge.install(&self.bridge);
        defer vm_bridge.uninstall(&self.bridge);

        var output_ptr: ?[*]u8 = null;
        var output_len: usize = 0;
        const rc = qjs.qjs_rt_load(
            self.runtime,
            self.source.?.ptr,
            self.source.?.len,
            self.name.?.ptr,
            self.name.?.len,
            &output_ptr,
            &output_len,
        );
        defer qjs.qjs_free(output_ptr, output_len);
        if (rc != 0) return if (rc > 0) 3 else 4;

        if (qjs.qjs_rt_has_fn(self.runtime, server_dispatch.handler_name.ptr, server_dispatch.handler_name.len) == 1) {
            while (true) {
                const result = self.pumpServer(std.math.maxInt(u32));
                if (result.stopped) break;
                if (result.processed == 0) idleWait();
            }
        }
        self.config.io.to_host.send(contract.Command.init(.event, .engine_stopped)) catch return 5;
        return 0;
    }

    fn poll(context: ?*anyopaque, limit: u32) callconv(.c) u32 {
        const self: *QuickJsEngine = @ptrCast(@alignCast(context.?));
        return self.pumpServer(limit).processed;
    }

    fn pumpServer(self: *QuickJsEngine, limit: u32) server_dispatch.PumpResult {
        return server_dispatch.pump(self.allocator, self.config.io, &self.bridge, .{
            .context = self,
            .call = callHandler,
        }, limit);
    }

    fn callHandler(context: *anyopaque, input: []const u8, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *QuickJsEngine = @ptrCast(@alignCast(context));
        var output_ptr: ?[*]u8 = null;
        var output_len: usize = 0;
        const rc = qjs.qjs_rt_call(
            self.runtime,
            server_dispatch.handler_name.ptr,
            server_dispatch.handler_name.len,
            input.ptr,
            input.len,
            &output_ptr,
            &output_len,
        );
        defer qjs.qjs_free(output_ptr, output_len);
        if (rc != 0) return error.HandlerFailed;
        return allocator.dupe(u8, if (output_ptr) |ptr| ptr[0..output_len] else &.{});
    }

    fn idleWait() void {
        var duration: std.c.timespec = .{ .sec = 0, .nsec = 100_000 };
        _ = std.c.nanosleep(&duration, null);
    }

    fn interrupt(context: ?*anyopaque) callconv(.c) void {
        const self: *QuickJsEngine = @ptrCast(@alignCast(context.?));
        // The sibling wrapper enforces a bounded call. Lowering the next-call
        // budget is the only interrupt control in its existing public ABI.
        qjs.qjs_rt_set_timeout_ms(self.runtime, 1);
    }

    fn destroy(context: ?*anyopaque) callconv(.c) void {
        const self: *QuickJsEngine = @ptrCast(@alignCast(context.?));
        if (self.state == .destroyed) return;
        if (self.source) |source| self.allocator.free(source);
        if (self.name) |name| self.allocator.free(name);
        self.source = null;
        self.name = null;
        self.bridge.deinit();
        qjs.qjs_rt_free(self.runtime);
        self.runtime = null;
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
