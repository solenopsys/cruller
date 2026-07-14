/// POSIX-like stat structure with birthtime support for node:fs.
/// Mirrors libuv's `uv_stat_t` (all `uint64_t` fields) so the native → JS
/// conversion matches Node.js exactly.
pub const PosixStat = extern struct {
    dev: u64,
    ino: u64,
    mode: u64,
    nlink: u64,
    uid: u64,
    gid: u64,
    rdev: u64,
    size: u64,
    blksize: u64,
    blocks: u64,

    /// Access time
    atim: bun.timespec,
    /// Modification time
    mtim: bun.timespec,
    /// Change time (metadata)
    ctim: bun.timespec,
    /// Birth time (creation time) - may be zero if not supported
    birthtim: bun.timespec,

    /// C's implicit integer → `uint64_t` conversion, i.e. what libuv does
    /// when copying platform `struct stat` fields into `uv_stat_t`.
    fn toU64(value: anytype) u64 {
        return switch (@typeInfo(@TypeOf(value)).int.signedness) {
            .signed => @bitCast(@as(i64, value)),
            .unsigned => value,
        };
    }

    /// Convert platform-specific bun.Stat to PosixStat
    pub fn init(stat_: *const bun.Stat) PosixStat {
        const atime_val = stat_.atime();
        const mtime_val = stat_.mtime();
        const ctime_val = stat_.ctime();
        const birthtime_val = if (Environment.isLinux)
            bun.timespec.epoch
        else
            stat_.birthtime();

        return PosixStat{
            .dev = toU64(stat_.dev),
            .ino = toU64(stat_.ino),
            .mode = toU64(stat_.mode),
            .nlink = toU64(stat_.nlink),
            .uid = toU64(stat_.uid),
            .gid = toU64(stat_.gid),
            .rdev = toU64(stat_.rdev),
            .size = toU64(stat_.size),
            .blksize = toU64(stat_.blksize),
            .blocks = toU64(stat_.blocks),
            .atim = .{ .sec = atime_val.sec, .nsec = atime_val.nsec },
            .mtim = .{ .sec = mtime_val.sec, .nsec = mtime_val.nsec },
            .ctim = .{ .sec = ctime_val.sec, .nsec = ctime_val.nsec },
            .birthtim = .{ .sec = birthtime_val.sec, .nsec = birthtime_val.nsec },
        };
    }

    pub fn atime(self: *const PosixStat) bun.timespec {
        return self.atim;
    }

    pub fn mtime(self: *const PosixStat) bun.timespec {
        return self.mtim;
    }

    pub fn ctime(self: *const PosixStat) bun.timespec {
        return self.ctim;
    }

    pub fn birthtime(self: *const PosixStat) bun.timespec {
        return self.birthtim;
    }

    /// Convert a raw kernel `struct stat` (as filled by fstatat64/fstat
    /// syscalls) into PosixStat.
    pub fn fromKernel(k: *const KernelStat) PosixStat {
        return PosixStat{
            .dev = k.dev,
            .ino = k.ino,
            .mode = k.mode,
            .nlink = k.nlink,
            .uid = k.uid,
            .gid = k.gid,
            .rdev = k.rdev,
            .size = toU64(k.size),
            .blksize = toU64(k.blksize),
            .blocks = toU64(k.blocks),
            .atim = k.atim,
            .mtim = k.mtim,
            .ctim = k.ctim,
            .birthtim = bun.timespec.epoch,
        };
    }
};

/// Linux kernel `struct stat` layout (glibc-compatible on these arches).
/// zig 0.16 removed std.os.linux Stat/std.c.Stat, but the raw fstatat64/fstat
/// syscalls still fill exactly this layout — NOT PosixStat/uv_stat_t.
pub const KernelStat = switch (builtin.cpu.arch) {
    .x86_64 => extern struct {
        dev: u64 = 0,
        ino: u64 = 0,
        nlink: u64 = 0,
        mode: u32 = 0,
        uid: u32 = 0,
        gid: u32 = 0,
        __pad0: u32 = 0,
        rdev: u64 = 0,
        size: i64 = 0,
        blksize: i64 = 0,
        blocks: i64 = 0,
        atim: bun.timespec = bun.timespec.epoch,
        mtim: bun.timespec = bun.timespec.epoch,
        ctim: bun.timespec = bun.timespec.epoch,
        __unused: [3]i64 = .{ 0, 0, 0 },
    },
    .aarch64 => extern struct {
        dev: u64 = 0,
        ino: u64 = 0,
        mode: u32 = 0,
        nlink: u32 = 0,
        uid: u32 = 0,
        gid: u32 = 0,
        rdev: u64 = 0,
        __pad: u64 = 0,
        size: i64 = 0,
        blksize: i32 = 0,
        __pad2: i32 = 0,
        blocks: i64 = 0,
        atim: bun.timespec = bun.timespec.epoch,
        mtim: bun.timespec = bun.timespec.epoch,
        ctim: bun.timespec = bun.timespec.epoch,
        __unused: [2]u32 = .{ 0, 0 },
    },
    else => @compileError("bzrt: only linux x86_64/aarch64 are supported"),
};

const builtin = @import("builtin");
const bun = @import("bun");
const Environment = bun.Environment;
