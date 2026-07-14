//! bzrt: компат-шим для API, удалённых в zig 0.16.
//! Центральная точка получения Io — потом заменить на настоящий Io.Threaded.
const std = @import("std");

pub fn io() std.Io {
    return std.Options.debug_io;
}

pub fn fchdir(fd: std.posix.fd_t) !void {
    if (std.c.fchdir(fd) != 0) return error.Unexpected;
}

pub fn nanosleep(secs: u64, nanos: u64) void {
    var ts: std.c.timespec = .{ .sec = @intCast(secs), .nsec = @intCast(nanos) };
    _ = std.c.nanosleep(&ts, null);
}

/// Замена std.time.Timer (удалён в 0.16) на монотонных часах libc.
pub const Timer = struct {
    started: i128,

    pub fn start() error{TimerUnsupported}!Timer {
        return .{ .started = now() };
    }
    pub fn read(self: *Timer) u64 {
        return @intCast(now() - self.started);
    }
    pub fn reset(self: *Timer) void {
        self.started = now();
    }
    pub fn lap(self: *Timer) u64 {
        const t = now();
        const d = t - self.started;
        self.started = t;
        return @intCast(d);
    }
    fn now() i128 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    }
};

/// Замена std.once (удалён в 0.16); мьютекс — pthread, т.к. libc всегда слинкован.
pub fn once(comptime f: fn () void) Once(f) {
    return .{};
}

pub fn Once(comptime f: fn () void) type {
    return struct {
        done: std.atomic.Value(bool) = .init(false),
        handle: std.c.pthread_mutex_t = .{},

        pub fn call(self: *@This()) void {
            if (self.done.load(.acquire)) return;
            std.debug.assert(std.c.pthread_mutex_lock(&self.handle) == .SUCCESS);
            defer std.debug.assert(std.c.pthread_mutex_unlock(&self.handle) == .SUCCESS);
            if (!self.done.load(.monotonic)) {
                f();
                self.done.store(true, .release);
            }
        }
    };
}

/// Managed-обёртки над ArrayHashMap (0.16 оставил только unmanaged).
pub fn ArrayHashMapManaged(comptime K: type, comptime V: type, comptime Context: type, comptime store_hash: bool) type {
    return struct {
        unmanaged: Unmanaged = .empty,
        allocator: std.mem.Allocator,

        pub const Unmanaged = std.ArrayHashMapUnmanaged(K, V, Context, store_hash);
        pub const Entry = Unmanaged.Entry;
        pub const GetOrPutResult = Unmanaged.GetOrPutResult;
        pub const Iterator = Unmanaged.Iterator;
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }
        pub fn initContext(allocator: std.mem.Allocator, _: Context) Self {
            return .{ .allocator = allocator };
        }
        pub fn deinit(self: *Self) void {
            self.unmanaged.deinit(self.allocator);
        }
        pub fn count(self: Self) usize {
            return self.unmanaged.count();
        }
        pub fn get(self: Self, key: anytype) ?V {
            return self.unmanaged.get(key);
        }
        pub fn getPtr(self: Self, key: anytype) ?*V {
            return self.unmanaged.getPtr(key);
        }
        pub fn getEntry(self: Self, key: anytype) ?Entry {
            return self.unmanaged.getEntry(key);
        }
        pub fn getIndex(self: Self, key: anytype) ?usize {
            return self.unmanaged.getIndex(key);
        }
        pub fn contains(self: Self, key: anytype) bool {
            return self.unmanaged.contains(key);
        }
        pub fn put(self: *Self, key: K, value: V) !void {
            return self.unmanaged.put(self.allocator, key, value);
        }
        pub fn getOrPut(self: *Self, key: K) !GetOrPutResult {
            return self.unmanaged.getOrPut(self.allocator, key);
        }
        pub fn getOrPutValue(self: *Self, key: K, value: V) !GetOrPutResult {
            return self.unmanaged.getOrPutValue(self.allocator, key, value);
        }
        pub fn swapRemove(self: *Self, key: anytype) bool {
            return self.unmanaged.swapRemove(key);
        }
        pub fn orderedRemove(self: *Self, key: anytype) bool {
            return self.unmanaged.orderedRemove(key);
        }
        pub fn fetchSwapRemove(self: *Self, key: anytype) ?Unmanaged.KV {
            return self.unmanaged.fetchSwapRemove(key);
        }
        pub fn iterator(self: *const Self) Iterator {
            return self.unmanaged.iterator();
        }
        pub fn keys(self: Self) []K {
            return self.unmanaged.keys();
        }
        pub fn values(self: Self) []V {
            return self.unmanaged.values();
        }
        pub fn ensureTotalCapacity(self: *Self, n: usize) !void {
            return self.unmanaged.ensureTotalCapacity(self.allocator, n);
        }
        pub fn ensureUnusedCapacity(self: *Self, n: usize) !void {
            return self.unmanaged.ensureUnusedCapacity(self.allocator, n);
        }
        pub fn clearRetainingCapacity(self: *Self) void {
            self.unmanaged.clearRetainingCapacity();
        }
        pub fn clearAndFree(self: *Self) void {
            self.unmanaged.clearAndFree(self.allocator);
        }
    };
}

pub fn AutoArrayHashMapManaged(comptime K: type, comptime V: type) type {
    return struct {
        unmanaged: Unmanaged = .empty,
        allocator: std.mem.Allocator,

        pub const Unmanaged = std.AutoArrayHashMapUnmanaged(K, V);
        pub const Entry = Unmanaged.Entry;
        pub const GetOrPutResult = Unmanaged.GetOrPutResult;
        pub const Iterator = Unmanaged.Iterator;
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }
        pub fn deinit(self: *Self) void {
            self.unmanaged.deinit(self.allocator);
        }
        pub fn count(self: Self) usize {
            return self.unmanaged.count();
        }
        pub fn get(self: Self, key: K) ?V {
            return self.unmanaged.get(key);
        }
        pub fn getPtr(self: Self, key: K) ?*V {
            return self.unmanaged.getPtr(key);
        }
        pub fn contains(self: Self, key: K) bool {
            return self.unmanaged.contains(key);
        }
        pub fn put(self: *Self, key: K, value: V) !void {
            return self.unmanaged.put(self.allocator, key, value);
        }
        pub fn getOrPut(self: *Self, key: K) !GetOrPutResult {
            return self.unmanaged.getOrPut(self.allocator, key);
        }
        pub fn swapRemove(self: *Self, key: K) bool {
            return self.unmanaged.swapRemove(key);
        }
        pub fn swapRemoveAt(self: *Self, index: usize) void {
            self.unmanaged.swapRemoveAt(index);
        }
        pub fn fetchSwapRemove(self: *Self, key: K) ?Unmanaged.KV {
            return self.unmanaged.fetchSwapRemove(key);
        }
        pub fn orderedRemove(self: *Self, key: K) bool {
            return self.unmanaged.orderedRemove(key);
        }
        pub fn iterator(self: *const Self) Iterator {
            return self.unmanaged.iterator();
        }
        pub fn keys(self: Self) []K {
            return self.unmanaged.keys();
        }
        pub fn values(self: Self) []V {
            return self.unmanaged.values();
        }
        pub fn capacity(self: Self) usize {
            return self.unmanaged.entries.capacity;
        }
        pub fn shrinkAndFree(self: *Self, n: usize) void {
            self.unmanaged.shrinkAndFree(self.allocator, n);
        }
        pub fn fetchOrderedRemove(self: *Self, key: K) ?Unmanaged.KV {
            return self.unmanaged.fetchOrderedRemove(key);
        }
        pub fn fetchPut(self: *Self, key: K, value: V) !?Unmanaged.KV {
            return self.unmanaged.fetchPut(self.allocator, key, value);
        }
        pub fn fetchRemove(self: *Self, key: K) ?Unmanaged.KV {
            return self.unmanaged.fetchSwapRemove(key);
        }
    };
}

pub fn intToEnum(comptime E: type, integer: anytype) error{InvalidEnumTag}!E {
    return std.enums.fromInt(E, integer) orelse error.InvalidEnumTag;
}

pub fn isatty(fd: anytype) bool {
    return std.c.isatty(@intCast(fd)) != 0;
}

pub fn timestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

pub fn milliTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
}

/// Замена std.crypto.random (в 0.16 csprng переехал в Io) на getrandom(2).
pub fn rand() std.Random {
    return .{ .ptr = undefined, .fillFn = randFill };
}
fn randFill(_: *anyopaque, buf: []u8) void {
    var i: usize = 0;
    while (i < buf.len) {
        const rc = std.os.linux.getrandom(buf[i..].ptr, buf.len - i, 0);
        const signed: isize = @bitCast(rc);
        if (signed < 0) continue;
        i += rc;
    }
}

/// 0.15 std.io.GenericWriter: минимально достаточная копия.
pub fn GenericWriter(
    comptime Context: type,
    comptime WriteError: type,
    comptime writeFn: fn (context: Context, bytes: []const u8) WriteError!usize,
) type {
    return struct {
        context: Context,

        pub const Error = WriteError;
        const Self = @This();

        pub fn write(self: Self, bytes: []const u8) Error!usize {
            return writeFn(self.context, bytes);
        }
        pub fn writeAll(self: Self, bytes: []const u8) Error!void {
            var i: usize = 0;
            while (i < bytes.len) i += try writeFn(self.context, bytes[i..]);
        }
        pub fn writeByte(self: Self, byte: u8) Error!void {
            try self.writeAll(&[1]u8{byte});
        }
        pub fn writeByteNTimes(self: Self, byte: u8, n: usize) Error!void {
            var i: usize = 0;
            while (i < n) : (i += 1) try self.writeByte(byte);
        }
        pub fn writeBytesNTimes(self: Self, bytes: []const u8, n: usize) Error!void {
            var i: usize = 0;
            while (i < n) : (i += 1) try self.writeAll(bytes);
        }
        pub fn writeInt(self: Self, comptime T: type, value: T, comptime endian: std.builtin.Endian) Error!void {
            var b: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
            std.mem.writeInt(T, &b, value, endian);
            try self.writeAll(&b);
        }
        pub fn writeStruct(self: Self, value: anytype) Error!void {
            try self.writeAll(std.mem.asBytes(&value));
        }

        pub const Adapter = struct {
            context: Context,
            err: ?WriteError = null,
            new_interface: std.Io.Writer,

            fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
                const a: *Adapter = @alignCast(@fieldParentPtr("new_interface", w));
                var written: usize = 0;
                const buffered = w.buffered();
                if (buffered.len > 0) {
                    a.writeAllInner(buffered) catch |e| {
                        a.err = e;
                        return error.WriteFailed;
                    };
                    w.end = 0;
                }
                for (data[0 .. data.len - 1]) |chunk| {
                    a.writeAllInner(chunk) catch |e| {
                        a.err = e;
                        return error.WriteFailed;
                    };
                    written += chunk.len;
                }
                const last = data[data.len - 1];
                var i: usize = 0;
                while (i < splat) : (i += 1) {
                    a.writeAllInner(last) catch |e| {
                        a.err = e;
                        return error.WriteFailed;
                    };
                    written += last.len;
                }
                return written;
            }
            fn writeAllInner(a: *Adapter, bytes: []const u8) WriteError!void {
                var i: usize = 0;
                while (i < bytes.len) i += try writeFn(a.context, bytes[i..]);
            }
            const vtable: std.Io.Writer.VTable = .{ .drain = drain };
        };

        pub fn adaptToNewApi(self: Self, buf: []u8) Adapter {
            return .{
                .context = self.context,
                .new_interface = .{ .buffer = buf, .vtable = &Adapter.vtable },
            };
        }

        pub fn print(self: Self, comptime fmt: []const u8, args: anytype) Error!void {
            var buf: [256]u8 = undefined;
            var adapter: Adapter = .{
                .context = self.context,
                .new_interface = .{ .buffer = &buf, .vtable = &Adapter.vtable },
            };
            adapter.new_interface.print(fmt, args) catch {
                if (adapter.err) |e| return e;
                unreachable; // fixed-буфер дренится в writeFn, другой причины нет
            };
            adapter.new_interface.flush() catch {
                if (adapter.err) |e| return e;
                unreachable;
            };
        }

        pub fn any(self: *const Self) Self {
            return self.*;
        }
    };
}

/// 0.15 std.io.GenericReader: минимально достаточная копия.
pub fn GenericReader(
    comptime Context: type,
    comptime ReadError: type,
    comptime readFn: fn (context: Context, buffer: []u8) ReadError!usize,
) type {
    return struct {
        context: Context,

        pub const Error = ReadError;
        pub const NoEofError = ReadError || error{EndOfStream};
        const Self = @This();

        pub fn read(self: Self, buffer: []u8) Error!usize {
            return readFn(self.context, buffer);
        }
        pub fn readAll(self: Self, buffer: []u8) Error!usize {
            var i: usize = 0;
            while (i < buffer.len) {
                const n = try readFn(self.context, buffer[i..]);
                if (n == 0) break;
                i += n;
            }
            return i;
        }
        pub fn readNoEof(self: Self, buffer: []u8) NoEofError!void {
            if ((try self.readAll(buffer)) != buffer.len) return error.EndOfStream;
        }
        pub fn readByte(self: Self) NoEofError!u8 {
            var b: [1]u8 = undefined;
            try self.readNoEof(&b);
            return b[0];
        }
        pub fn readBytesNoEof(self: Self, comptime n: usize) NoEofError![n]u8 {
            var b: [n]u8 = undefined;
            try self.readNoEof(&b);
            return b;
        }
        pub fn readInt(self: Self, comptime T: type, comptime endian: std.builtin.Endian) NoEofError!T {
            const b = try self.readBytesNoEof(@divExact(@typeInfo(T).int.bits, 8));
            return std.mem.readInt(T, &b, endian);
        }
        pub fn readStruct(self: Self, comptime T: type) NoEofError!T {
            var res: [1]T = undefined;
            try self.readNoEof(std.mem.sliceAsBytes(res[0..]));
            return res[0];
        }
        pub fn readEnum(self: Self, comptime E: type, comptime endian: std.builtin.Endian) (NoEofError || error{InvalidValue})!E {
            const tag = try self.readInt(@typeInfo(E).@"enum".tag_type, endian);
            return std.enums.fromInt(E, tag) orelse error.InvalidValue;
        }
        pub fn skipBytes(self: Self, n: u64, _: anytype) NoEofError!void {
            var i: u64 = 0;
            var b: [64]u8 = undefined;
            while (i < n) {
                const chunk = @min(n - i, b.len);
                try self.readNoEof(b[0..chunk]);
                i += chunk;
            }
        }
    };
}

pub fn listWriter(list: anytype) GenericWriter(@TypeOf(list), std.mem.Allocator.Error, listWriteFn(@TypeOf(list))) {
    return .{ .context = list };
}
fn listWriteFn(comptime L: type) fn (L, []const u8) std.mem.Allocator.Error!usize {
    return struct {
        fn write(l: L, bytes: []const u8) std.mem.Allocator.Error!usize {
            try l.appendSlice(bytes);
            return bytes.len;
        }
    }.write;
}

/// 0.15 std.io.FixedBufferStream (writer+reader над срезом).
pub fn fixedBufferStream(buffer: anytype) FixedBufferStream(@TypeOf(buffer)) {
    return .{ .buffer = switch (@typeInfo(@TypeOf(buffer))) {
        .pointer => |ptr| switch (ptr.size) {
            .one => buffer, // *[N]u8 коэрсится в срез ниже по типу поля
            else => buffer,
        },
        else => @compileError("fixedBufferStream: ожидается срез или указатель на массив"),
    }, .pos = 0 };
}

pub fn FixedBufferStream(comptime BufferPtr: type) type {
    const is_const = switch (@typeInfo(BufferPtr)) {
        .pointer => |ptr| ptr.is_const or switch (@typeInfo(ptr.child)) {
            .array => ptr.is_const,
            else => false,
        },
        else => @compileError("bad type"),
    };
    const Slice = if (is_const) []const u8 else []u8;
    return struct {
        buffer: Slice,
        pos: usize,

        pub const ReadError = error{};
        pub const WriteError = error{NoSpaceLeft};
        pub const Reader = GenericReader(*Self, ReadError, readFn);
        pub const Writer = if (is_const) void else GenericWriter(*Self, WriteError, writeFn);
        const Self = @This();

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }
        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }
        pub fn write(self: *Self, bytes: []const u8) WriteError!usize {
            return writeFn(self, bytes);
        }
        fn readFn(self: *Self, dest: []u8) ReadError!usize {
            const n = @min(dest.len, self.buffer.len - self.pos);
            @memcpy(dest[0..n], self.buffer[self.pos..][0..n]);
            self.pos += n;
            return n;
        }
        fn writeFn(self: *Self, bytes: []const u8) WriteError!usize {
            if (comptime is_const) unreachable;
            if (bytes.len == 0) return 0;
            if (self.pos >= self.buffer.len) return error.NoSpaceLeft;
            const n = @min(bytes.len, self.buffer.len - self.pos);
            @memcpy(@constCast(self.buffer[self.pos..][0..n]), bytes[0..n]);
            self.pos += n;
            if (n == 0) return error.NoSpaceLeft;
            return n;
        }
        pub fn getWritten(self: Self) Slice {
            return self.buffer[0..self.pos];
        }
        pub fn getPos(self: Self) usize {
            return self.pos;
        }
        pub fn seekTo(self: *Self, pos: u64) !void {
            self.pos = @min(@as(usize, @intCast(pos)), self.buffer.len);
        }
        pub fn reset(self: *Self) void {
            self.pos = 0;
        }
    };
}

/// 0.15 std.net.Address: только то, что использует bun (v4/v6 + формат).
pub const NetAddress = extern union {
    any: std.posix.sockaddr,
    in: extern struct {
        sa: std.posix.sockaddr.in,

        pub fn getPort(self: @This()) u16 {
            return std.mem.bigToNative(u16, self.sa.port);
        }
    },
    in6: extern struct {
        sa: std.posix.sockaddr.in6,

        pub fn getPort(self: @This()) u16 {
            return std.mem.bigToNative(u16, self.sa.port);
        }
    },

    pub fn initIp4(bytes: [4]u8, port: u16) NetAddress {
        return .{ .in = .{ .sa = .{
            .port = std.mem.nativeToBig(u16, port),
            .addr = @bitCast(bytes),
        } } };
    }
    pub fn initIp6(bytes: [16]u8, port: u16, flowinfo: u32, scope_id: u32) NetAddress {
        return .{ .in6 = .{ .sa = .{
            .port = std.mem.nativeToBig(u16, port),
            .flowinfo = flowinfo,
            .addr = bytes,
            .scope_id = scope_id,
        } } };
    }
    pub fn initPosix(sa: *align(4) const std.posix.sockaddr) NetAddress {
        return switch (sa.family) {
            std.posix.AF.INET => .{ .in = .{ .sa = @as(*const std.posix.sockaddr.in, @ptrCast(sa)).* } },
            std.posix.AF.INET6 => .{ .in6 = .{ .sa = @as(*const std.posix.sockaddr.in6, @ptrCast(sa)).* } },
            else => unreachable,
        };
    }
    pub fn getPort(self: NetAddress) u16 {
        return switch (self.any.family) {
            std.posix.AF.INET => std.mem.bigToNative(u16, self.in.sa.port),
            std.posix.AF.INET6 => std.mem.bigToNative(u16, self.in6.sa.port),
            else => unreachable,
        };
    }
    pub fn format(self: NetAddress, writer: anytype) !void {
        switch (self.any.family) {
            std.posix.AF.INET => {
                const bytes: [4]u8 = @bitCast(self.in.sa.addr);
                try writer.print("{d}.{d}.{d}.{d}:{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3], self.getPort() });
            },
            std.posix.AF.INET6 => {
                try writer.writeAll("[");
                var i: usize = 0;
                while (i < 16) : (i += 2) {
                    if (i != 0) try writer.writeAll(":");
                    try writer.print("{x}", .{std.mem.readInt(u16, self.in6.sa.addr[i..][0..2], .big)});
                }
                try writer.print("]:{d}", .{self.getPort()});
            },
            else => unreachable,
        }
    }
};
