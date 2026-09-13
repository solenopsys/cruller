//! ssr-run: ОДИН бинарь — один и тот же SSR-бандл, движок выбирается
//! в рантайме флагом `--engine=quickjs|v8` (jsc — тем же бандлом через bun,
//! см. ssr-run/jsc_ssr_check.js: standalone не линкует монолит bun).
//!
//! Использование:
//!   zig build ssr-run -- --bundle ../ssr-preact/dist/bundle.js --engine quickjs
//!   ./zig-out/bin/ssr-run --bundle <path> --engine v8 [--repeat N] [--json]
//!
//! Формат запросов захардкожен (4 вектора: /, /about, /nope, bad-json),
//! ответы сверяются с ожиданиями из node-прогона; несовпадение = exit 1.
//! Peak RSS печатается в stderr (getrusage RU_MAXRSS).

const std = @import("std");
const contract = @import("./contract.zig");
const QuickJsEngine = @import("./quickjs_engine.zig").QuickJsEngine;
const V8Engine = @import("./v8_engine.zig").V8Engine;

// standalone: движок выбирается compile-time через -Dengine, поэтому файл
// импортирует только contract + engine_selector + ОДИН engine.
// direct.zig тянет "bun" (Mutex) — здесь своя минимальная копия канала и
// пула на std.atomic спинлоке, без bun-зависимости. Копия намеренная:
// ssr-run обязан собираться голым zig без codegen/build_options монолита.

const Channel = struct {
    allocator: std.mem.Allocator,
    mutex: std.atomic.Mutex = .unlocked,
    queue: std.array_list.Managed(contract.Command),
    read_index: usize = 0,

    fn init(allocator: std.mem.Allocator) Channel {
        return .{ .allocator = allocator, .queue = std.array_list.Managed(contract.Command).init(allocator) };
    }

    fn deinit(self: *Channel) void {
        self.queue.deinit();
    }

    fn transport(self: *Channel) contract.CommandTransport {
        return .{ .context = self, .vtable = &vtable };
    }

    fn lock(self: *Channel) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn send(context: ?*anyopaque, command: *const contract.Command) callconv(.c) bool {
        const self: *Channel = @ptrCast(@alignCast(context.?));
        self.lock();
        defer self.mutex.unlock();
        self.queue.append(command.*) catch return false;
        return true;
    }

    fn receive(context: ?*anyopaque, out: *contract.Command) callconv(.c) bool {
        const self: *Channel = @ptrCast(@alignCast(context.?));
        self.lock();
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

    fn setWaker(_: ?*anyopaque, _: contract.CommandTransport.Waker) callconv(.c) void {}

    const vtable: contract.CommandTransport.VTable = .{ .send = send, .receive = receive, .set_waker = setWaker };
};

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

    fn init(allocator: std.mem.Allocator) Pool {
        return .{ .allocator = allocator, .slots = std.array_list.Managed(Slot).init(allocator) };
    }

    fn deinit(self: *Pool) void {
        for (self.slots.items) |slot| {
            if (slot.bytes) |bytes| self.allocator.free(bytes);
        }
        self.slots.deinit();
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
        for (self.slots.items, 0..) |*slot, index| {
            if (slot.bytes == null) {
                slot.bytes = bytes;
                slot.refs = 1;
                out.* = .{ .pool_id = pool_id, .buffer_id = @intCast(index), .generation = slot.generation, .length = @intCast(len) };
                return true;
            }
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

const vectors = [_][]const u8{
    "{\"method\":\"GET\",\"path\":\"/\",\"headers\":[],\"body\":\"\"}",
    "{\"method\":\"GET\",\"path\":\"/about\",\"headers\":[],\"body\":\"\"}",
    "{\"method\":\"GET\",\"path\":\"/nope\",\"headers\":[],\"body\":\"\"}",
    "{oops",
    "{\"method\":\"GET\",\"path\":\"/calc\",\"headers\":[],\"body\":\"\"}",
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    var bundle: []const u8 = "";
    var engine_name: []const u8 = "quickjs";
    var repeat: usize = 1;
    var json_out = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_out = true;
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
        std.debug.print("usage: ssr-run --bundle <bundle.js> --engine quickjs|v8 [--repeat N] [--json]\n", .{});
        return error.MissingEngine;
    };
    if (bundle.len == 0) {
        std.debug.print("usage: ssr-run --bundle <bundle.js> --engine quickjs|v8 [--repeat N] [--json]\n", .{});
        return error.MissingBundle;
    }

    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, bundle, allocator, .limited(std.math.maxInt(u32)));

    // Один процесс = один движок. Каналы/пул — локальные, без "bun".
    var to_host = Channel.init(allocator);
    defer to_host.deinit();
    var to_engine = Channel.init(allocator);
    defer to_engine.deinit();
    var data = Pool.init(allocator);
    defer data.deinit();

    var implementation: Implementation = switch (engine_kind) {
        .quickjs => .{ .quickjs = undefined },
        .v8 => .{ .v8 = undefined },
    };
    const engine: contract.Engine = switch (engine_kind) {
        .quickjs => blk: {
            try implementation.quickjs.init(allocator, .{ .io = .{
                .to_host = to_host.transport(),
                .to_engine = to_engine.transport(),
                .data = data.transport(),
            } });
            break :blk implementation.quickjs.engine();
        },
        .v8 => blk: {
            try implementation.v8.init(allocator, .{ .io = .{
                .to_host = to_host.transport(),
                .to_engine = to_engine.transport(),
                .data = data.transport(),
            } });
            break :blk implementation.v8.engine();
        },
    };

    const source_ref = try data.copy(source);
    defer data.transport().release(source_ref);
    const name_ref = try data.copy("bundle.js");
    defer data.transport().release(name_ref);
    try engine.load(source_ref, name_ref);

    // Заранее кладём N повторов каждого вектора + shutdown.
    const total = vectors.len * repeat;
    for (0..repeat) |_| {
        for (vectors, 1..) |request, index| {
            // request_id должен быть стабилен между повторами? Нет —
            // выдаём сквозные id, ответы сверяем по порядку.
            _ = index;
            var command = contract.Command.init(.event, .server_request);
            command.request_id = 0; // перезапишем ниже
            command.payload = try data.copy(request);
            try to_engine.transport().send(command);
        }
    }
    // Перенумеруем request_id по порядку (1..total).
    {
        var id: u64 = 1;
        var i: usize = 0;
        while (i < to_engine.queue.items.len) : (i += 1) {
            if (to_engine.queue.items[i].operationKind() == .server_request) {
                to_engine.queue.items[i].request_id = id;
                id += 1;
            }
        }
    }
    try to_engine.transport().send(contract.Command.init(.shutdown, .none));

    const started_ns = monotonicNs();
    try engine.run();
    const elapsed_ns = monotonicNs() - started_ns;

    // Собираем ответы: engine_started, total x server_response_end, engine_stopped.
    const started = to_host.transport().receive() orelse return error.NoStarted;
    if (started.operationKind() != .engine_started) return error.BadStarted;

    var failed: usize = 0;
    var responses: usize = 0;
    // Ответы — в stdout (Io.File.stdout, построчно, без буфера): их парсит
    // run_all_ssr.sh и складывает в out-<engine>.json для cmp.
    // Диагностика (ok/NO, peak RSS) — в stderr через std.debug.print.
    var out_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    if (json_out) try stdout.interface.writeAll("[\n");
    var first_json = true;
    while (responses < total) {
        const response = to_host.transport().receive() orelse break;
        if (response.operationKind() != .server_response_end) return error.BadResponse;
        responses += 1;
        const mapped = try data.transport().map(response.payload);
        defer data.transport().release(response.payload);
        const body = mapped.slice();
        const vec_index = (responses - 1) % vectors.len;
        const ok = checkVector(vec_index, body);
        if (!ok) failed += 1;
        if (json_out) {
            if (!first_json) try stdout.interface.writeAll(",\n");
            first_json = false;
            try stdout.interface.print("  {{\"request_id\":{d},\"ok\":{s},\"response\":{s}}}", .{
                response.request_id,
                if (ok) "true" else "false",
                body,
            });
        } else {
            try stdout.interface.print("[{s}/{d}] req={d} status={d} ok={s}\n", .{
                @tagName(engine_kind),
                responses,
                response.request_id,
                response.status,
                if (ok) "yes" else "NO",
            });
        }
    }
    if (json_out) try stdout.interface.writeAll("\n]\n");
    try stdout.interface.flush();

    const stopped = to_host.transport().receive() orelse return error.NoStopped;
    if (stopped.operationKind() != .engine_stopped) return error.BadStopped;
    if (responses != total) {
        std.debug.print("FAIL: got {d} responses, want {d}\n", .{ responses, total });
        return error.ResponseCount;
    }

    const rss_kb = peakRssKb();
    // Сводная строка для README-таблицы: движок, число ответов, wall-time,
    // req/s, peak RSS, число несовпадений. Парсится bench_all.sh по префиксу.
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

/// Сверка с ожиданиями из node-прогона bundle.js:
/// 0:/ -> 200 + <title>Home</title> + Rendered on /
/// 1:/about -> 200 + <title>About</title> + Rendered on /about
/// 2:/nope -> 200 + Home (фолбэк) + Rendered on /nope
/// 3:bad-json -> 400 + bad request
/// 4:/calc -> 200 + точный детерминированный результат
///   (result=502474356, iterations=100000). Строгое равенство подряд:
///   расхождение движков = mismatch, а не шум.
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
    // Linux: ru_maxrss в килобайтах.
    const usage = std.posix.getrusage(std.c.rusage.SELF);
    return @intCast(usage.maxrss);
}

fn monotonicNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}
