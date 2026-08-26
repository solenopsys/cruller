const std = @import("std");
const bun = @import("bun");
const contract = @import("./contract.zig");
const direct = @import("./direct.zig");
const DirectHost = @import("./direct_host.zig").Host;
const engine_selector = @import("./engine_selector.zig");

/// Production phase-one composition: strict host/engine interfaces with direct
/// in-process transports, all linked into the existing executable.
pub fn RuntimeFor(comptime kind: engine_selector.Kind) type {
    const Implementation = engine_selector.Implementation(kind);
    return struct {
        allocator: std.mem.Allocator,
        host_to_engine: direct.CommandChannel,
        engine_to_host: direct.CommandChannel,
        data_pool: direct.DataPool,
        host: DirectHost,
        implementation: Implementation,
        engine: contract.Engine,
        initialized: bool = false,

        const Self = @This();

        pub fn init(self: *Self, allocator: std.mem.Allocator) !void {
            self.allocator = allocator;
            self.host_to_engine = direct.CommandChannel.init(allocator);
            errdefer self.host_to_engine.deinit();
            self.engine_to_host = direct.CommandChannel.init(allocator);
            errdefer self.engine_to_host.deinit();
            self.data_pool = direct.DataPool.init(allocator);
            errdefer self.data_pool.deinit();

            try self.implementation.init(allocator, .{
                .io = .{
                    .to_host = self.engine_to_host.transport(),
                    .to_engine = self.host_to_engine.transport(),
                    .data = self.data_pool.transport(),
                },
            });
            self.engine = self.implementation.engine();
            self.host = DirectHost.init(allocator, self.implementation.config.io);
            try self.host.start();
            self.initialized = true;
        }

        pub fn deinit(self: *Self) void {
            if (!self.initialized) return;
            self.host.deinit();
            self.engine.destroy();
            self.data_pool.deinit();
            self.engine_to_host.deinit();
            self.host_to_engine.deinit();
            self.initialized = false;
        }

        pub fn loadEntryPath(self: *Self, entry_path: []const u8) !void {
            const source = try std.Io.Dir.cwd().readFileAlloc(bun.compat.io(), entry_path, self.allocator, .limited(std.math.maxInt(u32)));
            defer self.allocator.free(source);
            const source_ref = try self.data_pool.copy(source);
            defer self.data_pool.transport().release(source_ref);
            const name_ref = try self.data_pool.copy(entry_path);
            defer self.data_pool.transport().release(name_ref);
            try self.engine.load(source_ref, name_ref);
        }

        pub fn run(self: *Self) !void {
            try self.engine.run();
        }

        pub fn interrupt(self: *Self) void {
            self.engine.interrupt();
        }
    };
}

pub const Runtime = RuntimeFor(.jsc);

pub const Contract = contract;
