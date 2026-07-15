#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def edit(relative: str, replacements: list[tuple[str, str, int]]) -> None:
    path = ROOT / relative
    text = path.read_text()
    for old, new, expected in replacements:
        found = text.count(old)
        if found != expected:
            raise SystemExit(f"{relative}: expected {expected}, found {found}: {old[:100]!r}")
        text = text.replace(old, new)
    path.write_text(text)
    print(relative)


edit("src/runtime/server/RequestContext.zig", [("            _ = globalThis;\n", "", 1)])
edit("src/bun.zig", [
    ("std.fs.File.OpenFlags", "std.Io.Dir.OpenFileOptions", 2),
    (") !std.fs.File {", ") !std.Io.File {", 3),
    ("return std.fs.File{ .handle = res.cast() };", "return std.Io.File{ .handle = res.cast(), .flags = .{ .nonblocking = false } };", 1),
    ("        std.posix.close(prev_fd);", "        FD.fromNative(prev_fd).close();", 1),
    ("        return std.fs.cwd().openFileZ(file_path, .{});", "        return std.Io.Dir.cwd().openFile(compat.io(), file_path, .{ .path_only = true });", 1),
    ("    return std.fs.File{\n        .handle = fd,\n    };", "    return std.Io.File{\n        .handle = fd,\n        .flags = .{ .nonblocking = false },\n    };", 1),
    ("    var it = try std.fs.path.componentIterator(sub_path);", "    var it = std.fs.path.componentIterator(sub_path);", 1),
    ("        bun.js_parser.StringVoidMap.Pool,\n", "", 1),
])
edit("src/bundler/analyze_transpiled_module.zig", [
    ("            .strings_lens = .{},", "            .strings_lens = .empty,", 1),
    ("std.AutoArrayHashMap(", "std.AutoArrayHashMapUnmanaged(", 2),
    (".requested_modules = std.AutoArrayHashMapUnmanaged(StringID, FetchParameters).init(allocator)", ".requested_modules = .empty", 1),
    ("self.requested_modules.deinit();", "self.requested_modules.deinit(self.gpa);", 1),
    ("self.requested_modules.getOrPut(import_record_path)", "self.requested_modules.getOrPut(self.gpa, import_record_path)", 1),
    ("self.requested_modules.reIndex()", "self.requested_modules.reIndex(self.gpa)", 1),
    ("std.AutoArrayHashMapUnmanaged(StringID, struct { module_name: StringID, import_name: StringID, record_kinds_idx: usize, is_namespace: bool }).init(bun.default_allocator)", "std.AutoArrayHashMapUnmanaged(StringID, struct { module_name: StringID, import_name: StringID, record_kinds_idx: usize, is_namespace: bool }).empty", 1),
    ("local_name_to_module_name.deinit();", "local_name_to_module_name.deinit(bun.default_allocator);", 1),
    ("local_name_to_module_name.put(", "local_name_to_module_name.put(bun.default_allocator, ", 2),
])
edit("src/jsc/rare_data.zig", [
    ("cron_jobs: std.ArrayListUnmanaged(*bun.api.cron.CronJob) = .{},", "cron_jobs: std.ArrayListUnmanaged(*bun.api.cron.CronJob) = .empty,", 1),
    ("cleanup_hooks: std.ArrayListUnmanaged(CleanupHook) = .{},", "cleanup_hooks: std.ArrayListUnmanaged(CleanupHook) = .empty,", 1),
])
edit("src/resolver/fs.zig", [
    ("threadlocal var tmpdir_handle: ?std.fs.Dir = null;", "threadlocal var tmpdir_handle: ?std.Io.Dir = null;", 1),
    ("pub fn tmpdir(fs: *FileSystem) !std.fs.Dir", "pub fn tmpdir(fs: *FileSystem) !std.Io.Dir", 1),
])
edit("src/resolver/resolver.zig", [
    ("this_dir.openDirZ(bun.pathLiteral(\"node_modules/.bin\"), .{})", "this_dir.openDir(bun.compat.io(), bun.pathLiteral(\"node_modules/.bin\"), .{})", 1),
])
edit("src/router/router.zig", [
    ("dedupe_dynamic: std.AutoArrayHashMap(u32, string)", "dedupe_dynamic: std.AutoArrayHashMapUnmanaged(u32, string)", 1),
    (".dedupe_dynamic = std.AutoArrayHashMap(u32, string).init(allocator)", ".dedupe_dynamic = .empty", 1),
    ("this.dedupe_dynamic.getOrPutValue(route.full_hash, route.abs_path.slice())", "this.dedupe_dynamic.getOrPutValue(this.allocator, route.full_hash, route.abs_path.slice())", 1),
    ("this.dedupe_dynamic.deinit();", "this.dedupe_dynamic.deinit(this.allocator);", 1),
])
edit("src/runtime/dns_jsc/dns.zig", [
    ("        if (this.getChannelOrError(vm.global)) |channel| {\n            if (this.anyRequestsPending()) {\n                c_ares.ares_process_fd(channel, c_ares.ARES_SOCKET_BAD, c_ares.ARES_SOCKET_BAD);\n                _ = this.addTimer(now);\n            }\n        } else {}", "        const channel = this.getChannelOrError(vm.global) catch return;\n        if (this.anyRequestsPending()) {\n            c_ares.ares_process_fd(channel, c_ares.ARES_SOCKET_BAD, c_ares.ARES_SOCKET_BAD);\n            _ = this.addTimer(now);\n        }", 1),
])
edit("src/runtime/server/ServerConfig.zig", [
    ("if ((ssl_config.server_name orelse \"\")[0] == 0)", "if (ssl_config.server_name == null or ssl_config.server_name.?[0] == 0)", 1),
])
edit("src/runtime/webcore/blob/copy_file.zig", [
    ("posix.S.ISFIFO(stat.mode) and posix.S.ISFIFO(this.destination_file_store.mode)", "posix.S.ISFIFO(@intCast(stat.mode)) and posix.S.ISFIFO(@intCast(this.destination_file_store.mode))", 1),
])
edit("src/sys/fd.zig", [
    ("return .fromNative(dir.fd);", "return .fromNative(dir.handle);", 1),
    ("return .{ .handle = fd.native() };", "return .{ .handle = fd.native(), .flags = .{ .nonblocking = false } };", 1),
    ("return .{ .fd = fd.native() };", "return .{ .handle = fd.native() };", 1),
])

print("applied checked Zig 0.16 frontier migrations")
