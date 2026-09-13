//! ssr-run: ONE binary — the same SSR bundle, engine selected at runtime
//! by the `--engine=quickjs|v8` flag (jsc runs the same bundle through bun,
//! see ssr-run/jsc_ssr_check.js: standalone does not link the bun monolith).
//!
//! Usage:
//!   zig build ssr-run -- --bundle ../ssr-preact/dist/bundle.js --engine quickjs
//!   ./zig-out/bin/ssr-run --bundle <path> --engine v8 [--repeat N] [--json]
//!
//! The request format is hardcoded (5 SSR vectors: /, /about, /nope, bad-json,
//! /calc; or 1 hw vector); responses are checked against the node-run
//! expectations; a mismatch exits with code 1. Peak RSS is printed to stderr
//! (getrusage RU_MAXRSS); harness memory is O(1), so RSS reflects the engine,
//! not the run's buffers.

const std = @import("std");
const contract = @import("./contract.zig");
const QuickJsEngine = @import("./quickjs_engine.zig").QuickJsEngine;
const V8Engine = @import("./v8_engine.zig").V8Engine;

// standalone: the engine is selected at compile time via -Dengine, so this
// file imports only contract + engine_selector + ONE engine.
// direct.zig pulls in "bun" (Mutex) — this is a minimal local copy of the
// pool on a std.atomic spinlock, with no bun dependency. The copy is
// deliberate: ssr-run must build with plain zig and no monolith
// codegen/build_options.
//
// Harness memory is kept O(1) in the request count (otherwise RSS would
// measure the harness buffers instead of the engine):
//   * Producer — a virtual to_engine: it holds no queue, it synthesizes the
//     next server_request on the pump's demand plus the final shutdown;
//   * Sink — a virtual to_host: it validates and releases each response
//     inside send instead of accumulating them until the end of the run.

const Producer = struct {
    data: *Pool,
    vectors: []const []const u8,
    total: usize,
    emitted: usize = 0,
    finished: bool = false,

    fn transport(self: *Producer) contract.CommandTransport {
        return .{ .context = self, .vtable = &vtable };
    }

    fn send(_: ?*anyopaque, _: *const contract.Command) callconv(.c) bool {
        return false;
    }

    fn receive(context: ?*anyopaque, out: *contract.Command) callconv(.c) bool {
        const self: *Producer = @ptrCast(@alignCast(context.?));
        if (self.emitted >= self.total) {
            if (self.finished) return false;
            self.finished = true;
            out.* = contract.Command.init(.shutdown, .none);
            return true;
        }
        const request = self.vectors[self.emitted % self.vectors.len];
        const data = self.data.transport();
        const ref = data.allocate(request.len) catch return false;
        const mapped = data.map(ref) catch {
            data.release(ref);
            return false;
        };
        @memcpy(mapped.slice(), request);
        self.emitted += 1;
        var command = contract.Command.init(.event, .server_request);
        command.request_id = self.emitted;
        command.payload = ref;
        out.* = command;
        return true;
    }

    fn setWaker(_: ?*anyopaque, _: contract.CommandTransport.Waker) callconv(.c) void {}

    const vtable: contract.CommandTransport.VTable = .{ .send = send, .receive = receive, .set_waker = setWaker };
};

fn Sink(comptime Writer: type) type {
    return struct {
        data: *Pool,
        engine_kind: EngineKind,
        active_vectors: []const []const u8,
        is_hw: bool,
        json_out: bool,
        out: *Writer,
        responses: usize = 0,
        failed: usize = 0,
        seen_started: bool = false,
        seen_stopped: bool = false,
        first_json: bool = true,

        fn transport(self: *@This()) contract.CommandTransport {
            return .{ .context = self, .vtable = &vtable };
        }

        fn send(context: ?*anyopaque, command: *const contract.Command) callconv(.c) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            switch (command.operationKind()) {
                .engine_started => {
                    self.seen_started = true;
                    return true;
                },
                .engine_stopped => {
                    self.seen_stopped = true;
                    return true;
                },
                .server_response_end => {},
                else => return true,
            }
            self.responses += 1;
            const data = self.data.transport();
            if (command.payload.isEmpty()) {
                self.failed += 1;
                return true;
            }
            const mapped = data.map(command.payload) catch return true;
            defer data.release(command.payload);
            const body = mapped.slice();
            const vec_index = (self.responses - 1) % self.active_vectors.len;
            const ok = if (self.is_hw) std.mem.eql(u8, body, "hw") else checkVector(vec_index, body);
            if (!ok) self.failed += 1;
            if (self.json_out) {
                if (!self.first_json) self.out.interface.writeAll(",\n") catch {};
                self.first_json = false;
                if (self.is_hw) {
                    self.out.interface.print("  {{\"request_id\":{d},\"ok\":{s},\"response\":\"{s}\"}}", .{
                        command.request_id,
                        if (ok) "true" else "false",
                        body,
                    }) catch {};
                } else {
                    self.out.interface.print("  {{\"request_id\":{d},\"ok\":{s},\"response\":{s}}}", .{
                        command.request_id,
                        if (ok) "true" else "false",
                        body,
                    }) catch {};
                }
            } else {
                self.out.interface.print("[{s}/{d}] req={d} status={d} ok={s}\n", .{
                    @tagName(self.engine_kind),
                    self.responses,
                    command.request_id,
                    command.status,
                    if (ok) "yes" else "NO",
                }) catch {};
            }
            return true;
        }

        fn receive(_: ?*anyopaque, _: *contract.Command) callconv(.c) bool {
            return false;
        }

        fn setWaker(_: ?*anyopaque, _: contract.CommandTransport.Waker) callconv(.c) void {}

        const vtable: contract.CommandTransport.VTable = .{ .send = send, .receive = receive, .set_waker = setWaker };
    };
}

const Pool = struct {
    const pool_id: u32 = 1;
    const Slot = struct {
        bytes: ?[]u8 = null,
        generation: u32 = 1,
        refs: u32 = 0,
    };

    allocator: std.mem.Allocator,
    mutex: std.atomic.Mutex = .unlocked,
    slots: std.array_list.Managed(Slot),
    // Indices of slots whose `bytes == null`, so `allocate` is O(1) instead
    // of scanning `slots` from the start. Without this, queueing N requests
    // grows the pool and every allocate rescans the whole live prefix,
    // turning the hw workload (N ~ 1e5) into O(N^2) harness time and
    // swamping the per-request cost being measured.
    free: std.array_list.Managed(u32),

    fn init(allocator: std.mem.Allocator) Pool {
        return .{
            .allocator = allocator,
            .slots = std.array_list.Managed(Slot).init(allocator),
            .free = std.array_list.Managed(u32).init(allocator),
        };
    }

    fn deinit(self: *Pool) void {
        for (self.slots.items) |slot| {
            if (slot.bytes) |bytes| self.allocator.free(bytes);
        }
        self.slots.deinit();
        self.free.deinit();
    }

    fn transport(self: *Pool) contract.DataTransport {
        return .{ .context = self, .vtable = &vtable };
    }

    fn copy(self: *Pool, bytes: []const u8) !contract.BufferRef {
        const data = self.transport();
        const ref = try data.allocate(bytes.len);
        errdefer data.release(ref);
        const mapped = try data.map(ref);
        @memcpy(mapped.slice(), bytes);
        return ref;
    }

    fn lock(self: *Pool) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn allocate(context: ?*anyopaque, len: usize, out: *contract.BufferRef) callconv(.c) bool {
        if (len > std.math.maxInt(u32)) return false;
        const self: *Pool = @ptrCast(@alignCast(context.?));
        const bytes = self.allocator.alloc(u8, len) catch return false;
        self.lock();
        defer self.mutex.unlock();
        if (self.free.pop()) |index| {
            const slot = &self.slots.items[index];
            slot.bytes = bytes;
            slot.refs = 1;
            out.* = .{ .pool_id = pool_id, .buffer_id = index, .generation = slot.generation, .length = @intCast(len) };
            return true;
        }
        self.slots.append(.{ .bytes = bytes, .refs = 1 }) catch {
            self.allocator.free(bytes);
            return false;
        };
        const index = self.slots.items.len - 1;
        out.* = .{ .pool_id = pool_id, .buffer_id = @intCast(index), .generation = self.slots.items[index].generation, .length = @intCast(len) };
        return true;
    }

    fn map(context: ?*anyopaque, ref: contract.BufferRef, out: *contract.MappedBuffer) callconv(.c) bool {
        const self: *Pool = @ptrCast(@alignCast(context.?));
        self.lock();
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
        const self: *Pool = @ptrCast(@alignCast(context.?));
        self.lock();
        defer self.mutex.unlock();
        const slot = self.getSlot(ref) orelse return false;
        if (slot.refs == std.math.maxInt(u32)) return false;
        slot.refs += 1;
        return true;
    }

    fn release(context: ?*anyopaque, ref: contract.BufferRef) callconv(.c) void {
        const self: *Pool = @ptrCast(@alignCast(context.?));
        self.lock();
        defer self.mutex.unlock();
        const slot = self.getSlot(ref) orelse return;
        if (slot.refs == 0) return;
        slot.refs -= 1;
        if (slot.refs != 0) return;
        self.allocator.free(slot.bytes.?);
        slot.bytes = null;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        self.free.append(ref.buffer_id) catch {};
    }

    fn getSlot(self: *Pool, ref: contract.BufferRef) ?*Slot {
        if (ref.pool_id != pool_id) return null;
        const index: usize = ref.buffer_id;
        if (index >= self.slots.items.len) return null;
        const slot = &self.slots.items[index];
        if (slot.bytes == null or slot.generation != ref.generation) return null;
        return slot;
    }

    const vtable: contract.DataTransport.VTable = .{
        .allocate = allocate,
        .map = map,
        .retain = retain,
        .release = release,
    };
};

const EngineKind = enum { quickjs, v8 };

const Implementation = union(EngineKind) {
    quickjs: QuickJsEngine,
    v8: V8Engine,
};

// SSR workload: 5 vectors (see checkVector for expectations).
const ssr_vectors = [_][]const u8{
    "{\"method\":\"GET\",\"path\":\"/\",\"headers\":[],\"body\":\"\"}",
    "{\"method\":\"GET\",\"path\":\"/about\",\"headers\":[],\"body\":\"\"}",
    "{\"method\":\"GET\",\"path\":\"/nope\",\"headers\":[],\"body\":\"\"}",
    "{oops",
    "{\"method\":\"GET\",\"path\":\"/calc\",\"headers\":[],\"body\":\"\"}",
};

// hw workload: one request, handler returns the literal bytes `hw`, no
// JSON envelope and no compute — the pure dispatch/call ceiling.
const hw_vectors = [_][]const u8{
    "{\"method\":\"GET\",\"path\":\"/\",\"headers\":[],\"body\":\"\"}",
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    var bundle: []const u8 = "";
    var engine_name: []const u8 = "quickjs";
    var workload: []const u8 = "ssr";
    var repeat: usize = 1;
    var json_out = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_out = true;
        } else if (std.mem.eql(u8, arg, "--workload")) {
            workload = args.next() orelse return error.MissingWorkload;
        } else if (std.mem.startsWith(u8, arg, "--workload=")) {
            workload = arg["--workload=".len..];
        } else if (std.mem.startsWith(u8, arg, "--engine=")) {
            engine_name = arg["--engine=".len..];
        } else if (std.mem.eql(u8, arg, "--engine")) {
            engine_name = args.next() orelse return error.MissingEngine;
        } else if (std.mem.startsWith(u8, arg, "--bundle=")) {
            bundle = arg["--bundle=".len..];
        } else if (std.mem.eql(u8, arg, "--bundle")) {
            bundle = args.next() orelse return error.MissingBundle;
        } else if (std.mem.startsWith(u8, arg, "--repeat=")) {
            repeat = try std.fmt.parseInt(usize, arg["--repeat=".len..], 10);
        } else if (std.mem.eql(u8, arg, "--repeat")) {
            const value = args.next() orelse return error.MissingRepeat;
            repeat = try std.fmt.parseInt(usize, value, 10);
        }
    }
    const engine_kind = std.meta.stringToEnum(EngineKind, engine_name) orelse {
        std.debug.print("usage: ssr-run --bundle <bundle.js> --engine quickjs|v8 [--workload ssr|hw] [--repeat N] [--json]\n", .{});
        return error.MissingEngine;
    };
    if (bundle.len == 0) {
        std.debug.print("usage: ssr-run --bundle <bundle.js> --engine quickjs|v8 [--workload ssr|hw] [--repeat N] [--json]\n", .{});
        return error.MissingBundle;
    }

    const is_hw = std.mem.eql(u8, workload, "hw");
    if (!is_hw and !std.mem.eql(u8, workload, "ssr")) {
        std.debug.print("unknown --workload {s} (want ssr|hw)\n", .{workload});
        return error.BadWorkload;
    }
    const active_vectors: []const []const u8 = if (is_hw) &hw_vectors else &ssr_vectors;

    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, bundle, allocator, .limited(std.math.maxInt(u32)));

    // One process = one engine. The pool/transports are local, without "bun".
    var data = Pool.init(allocator);
    defer data.deinit();

    const total = active_vectors.len * repeat;
    var producer: Producer = .{ .data = &data, .vectors = active_vectors, .total = total };

    var out_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    var sink: Sink(@TypeOf(stdout)) = .{
        .data = &data,
        .engine_kind = engine_kind,
        .active_vectors = active_vectors,
        .is_hw = is_hw,
        .json_out = json_out,
        .out = &stdout,
    };

    const io: contract.Duplex = .{
        .to_host = sink.transport(),
        .to_engine = producer.transport(),
        .data = data.transport(),
    };

    var implementation: Implementation = switch (engine_kind) {
        .quickjs => .{ .quickjs = undefined },
        .v8 => .{ .v8 = undefined },
    };
    const engine: contract.Engine = switch (engine_kind) {
        .quickjs => blk: {
            try implementation.quickjs.init(allocator, .{ .io = io });
            break :blk implementation.quickjs.engine();
        },
        .v8 => blk: {
            try implementation.v8.init(allocator, .{ .io = io });
            break :blk implementation.v8.engine();
        },
    };

    const source_ref = try data.copy(source);
    defer data.transport().release(source_ref);
    const name_ref = try data.copy("bundle.js");
    defer data.transport().release(name_ref);
    try engine.load(source_ref, name_ref);

    if (json_out) try stdout.interface.writeAll("[\n");
    const started_ns = monotonicNs();
    try engine.run();
    const elapsed_ns = monotonicNs() - started_ns;
    if (json_out) try stdout.interface.writeAll("\n]\n");
    try stdout.interface.flush();

    if (!sink.seen_started) return error.NoStarted;
    if (!sink.seen_stopped) return error.NoStopped;
    if (sink.responses != total) {
        std.debug.print("FAIL: got {d} responses, want {d}\n", .{ sink.responses, total });
        return error.ResponseCount;
    }
    const responses = sink.responses;
    const failed = sink.failed;

    const rss_kb = peakRssKb();
    // Summary line for the README table: engine, response count, wall time,
    // req/s, peak RSS, mismatch count. Parsed by bench_all.sh by prefix.
    const elapsed_ms: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const rps: f64 = if (elapsed_ns > 0)
        @as(f64, @floatFromInt(responses)) * 1_000_000_000.0 / @as(f64, @floatFromInt(elapsed_ns))
    else
        0;
    std.debug.print("{s}: {d} responses, {d} failed, peak RSS {d} kB\n", .{
        @tagName(engine_kind), responses, failed, rss_kb,
    });
    std.debug.print("BENCH engine={s} responses={d} failed={d} elapsed_ms={d:.1} rps={d:.0} peak_rss_kb={d}\n", .{
        @tagName(engine_kind), responses, failed, elapsed_ms, rps, rss_kb,
    });

    engine.destroy();
    if (failed != 0) std.process.exit(1);
}

/// Check against the expectations from the node run of bundle.js:
/// 0:/ -> 200 + <title>Home</title> + Rendered on /
/// 1:/about -> 200 + <title>About</title> + Rendered on /about
/// 2:/nope -> 200 + Home (fallback) + Rendered on /nope
/// 3:bad-json -> 400 + bad request
/// 4:/calc -> 200 + the exact deterministic result
///   (result=502474356, iterations=100000). Exact equality in sequence:
///   any engine divergence is a mismatch, not noise.
fn checkVector(index: usize, body: []const u8) bool {
    const has = struct {
        fn has(haystack: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, haystack, needle) != null;
        }
    }.has;
    switch (index) {
        0 => return has(body, "\"status\":200") and has(body, "<title>Home</title>") and has(body, "Rendered on /"),
        1 => return has(body, "\"status\":200") and has(body, "<title>About</title>") and has(body, "Rendered on /about"),
        2 => return has(body, "\"status\":200") and has(body, "<title>Home</title>") and has(body, "Rendered on /nope"),
        3 => return has(body, "\"status\":400") and has(body, "bad request"),
        4 => return has(body, "\"status\":200") and has(body, "\\\"result\\\":502474356") and has(body, "\\\"iterations\\\":100000"),
        else => return false,
    }
}

fn peakRssKb() usize {
    // Linux: ru_maxrss is in kilobytes.
    const usage = std.posix.getrusage(std.c.rusage.SELF);
    return @intCast(usage.maxrss);
}

fn monotonicNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}
