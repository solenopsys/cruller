pub const panic = _bun.crash_handler.panic;
pub const std_options = std.Options{
    .enable_segfault_handler = false,
};

pub const io_mode = .blocking;

comptime {
    _bun.assert(builtin.target.cpu.arch.endian() == .little);
}

pub extern "c" var _environ: ?*anyopaque;
pub extern "c" var environ: ?*anyopaque;

pub fn main(init: std.process.Init.Minimal) void {
    _bun.crash_handler.init();

    if (Environment.isPosix) {
        var act: _bun.sys.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = _bun.sys.sigemptyset(),
            .flags = 0,
        };
        _bun.sys.sigaction(@intFromEnum(std.posix.SIG.PIPE), &act, null);
        _bun.sys.sigaction(@intFromEnum(std.posix.SIG.XFSZ), &act, null);
    }

    if (Environment.isDebug) {
        _bun.debug_allocator_data.backing = .init;
    }

    // This should appear before we make any calls at all to libuv.
    // So it's safest to put it very early in the main function.
    if (Environment.isWindows) {
        _ = _bun.windows.libuv.uv_replace_allocator(
            &_bun.mimalloc.mi_malloc,
            &_bun.mimalloc.mi_realloc,
            &_bun.mimalloc.mi_calloc,
            &_bun.mimalloc.mi_free,
        );
        _bun.handleOom(_bun.windows.env.convertEnvToWTF8());
        environ = @ptrCast(std.os.environ.ptr);
        _environ = @ptrCast(std.os.environ.ptr);
    }

    _bun.start_time = blk: {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0)
            if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0)
                break :blk 0;
        break :blk @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
    };
    _bun.initArgv(init.args) catch |err| {
        Output.panic("Failed to initialize argv: {s}\n", .{@errorName(err)});
    };

    Output.Source.Stdio.init();
    defer Output.flush();

    _bun.StackCheck.configureThread();
    _bun.ParentDeathWatchdog.install();

    // bzrt: src/cli/ (arg parsing, subcommands) is fully removed — minimal
    // process entrypoint per tz.md. argv[0] is the executable itself;
    // argv[1] is the pre-built entry file to run, except for the two
    // version-reporting flags the build system's own smoke test relies on.
    if (_bun.argv.len > 1 and _bun.strings.eqlComptime(_bun.argv[1], "--version")) {
        Output.writer().writeAll(_bun.Global.package_json_version ++ "\n") catch {};
        _bun.Global.exit(0);
    } else if (_bun.argv.len > 1 and _bun.strings.eqlComptime(_bun.argv[1], "--revision")) {
        Output.writer().writeAll(_bun.Global.package_json_version_with_revision ++ "\n") catch {};
        _bun.Global.exit(0);
    } else if (_bun.argv.len > 1) {
        _bun.bun_js.runEntryFile(_bun.default_allocator, _bun.argv[1]) catch |err| {
            Output.panic("Failed to run entry file: {s}\n", .{@errorName(err)});
        };
    } else {
        Output.errGeneric("Usage: {s} path/to/script.js", .{if (_bun.argv.len > 0) _bun.argv[0] else "bun-debug"});
        Output.flush();
        _bun.Global.exit(1);
    }
    _bun.Global.exit(0);
}

pub export fn Bun__panic(msg: [*]const u8, len: usize) noreturn {
    Output.panic("{s}", .{msg[0..len]});
}

// -- Zig Standard Library Additions --
pub fn copyForwards(comptime T: type, dest: []T, source: []const T) void {
    if (source.len == 0) {
        return;
    }
    _bun.copy(T, dest[0..source.len], source);
}
pub fn copyBackwards(comptime T: type, dest: []T, source: []const T) void {
    if (source.len == 0) {
        return;
    }
    _bun.copy(T, dest[0..source.len], source);
}
pub fn eqlBytes(src: []const u8, dest: []const u8) bool {
    return _bun.c.memcmp(src.ptr, dest.ptr, src.len) == 0;
}
// -- End Zig Standard Library Additions --

// Claude thinks its @import("root").bun when it's @import("bun").
const bun = @compileError("Deprecated: Use @import(\"bun\") instead");

const builtin = @import("builtin");
const std = @import("std");

const _bun = @import("bun");
const Environment = _bun.Environment;
const Output = _bun.Output;
