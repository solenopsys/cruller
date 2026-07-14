#!/usr/bin/env python3
"""Apply checked, mechanical Zig 0.16 migrations from the current error set."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

REPLACEMENTS = {
    "src/bun_alloc/memory.zig": [
        (
            "    if (allocator.remap(@constCast(slice), slice.len)) |new| return new;\n"
            "    defer allocator.free(slice);\n"
            "    return allocator.dupe(Child, slice);",
            "    defer allocator.free(slice);\n"
            "    return allocator.dupe(Child, slice);",
        ),
    ],
    "src/bake/bake.zig": [
        ("pub const empty: StringRefList = .{ .strings = .{} };",
         "pub const empty: StringRefList = .{ .strings = .empty };")
    ],
    "src/bundler/analyze_transpiled_module.zig": [
        ("            .strings_buf = .{},", "            .strings_buf = .empty,")
    ],
    "src/runtime/api/bun/js_bun_spawn_bindings.zig": [
        ("        .stdio_pipes = .{},", "        .stdio_pipes = .empty,")
    ],
    "src/runtime/webcore/blob/copy_file.zig": [
        (
            "posix.S.ISREG(stat.mode) and (posix.S.ISREG(this.destination_file_store.mode)",
            "posix.S.ISREG(@intCast(stat.mode)) and (posix.S.ISREG(@intCast(this.destination_file_store.mode))",
        )
    ],
    "src/resolver/fs.zig": [
        (
            "std.fs.openFileAbsoluteZ(absolute_path_c, .{ .mode = .read_only })",
            "std.Io.Dir.openFileAbsolute(bun.compat.io(), absolute_path_c, .{ .mode = .read_only })",
        )
    ],
    "src/sys/fd.zig": [
        ("pub fn fromStdDir(dir: std.fs.Dir) FD", "pub fn fromStdDir(dir: std.Io.Dir) FD"),
        ("pub fn stdFile(fd: FD) std.fs.File", "pub fn stdFile(fd: FD) std.Io.File"),
        ("pub fn stdDir(fd: FD) std.fs.Dir", "pub fn stdDir(fd: FD) std.Io.Dir"),
    ],
    "src/bun.zig": [
        ("std.posix.fchdir(prev_fd)", "bun.compat.fchdir(prev_fd)"),
        ("std.posix.fchdir(fd)", "bun.compat.fchdir(fd)"),
    ],
}


def main() -> None:
    changed = 0
    for relative, replacements in REPLACEMENTS.items():
        path = ROOT / relative
        text = path.read_text()
        original = text
        for old, new in replacements:
            count = text.count(old)
            if count != 1:
                raise SystemExit(f"{relative}: expected one occurrence, found {count}: {old!r}")
            text = text.replace(old, new, 1)
        if text != original:
            path.write_text(text)
            changed += 1
            print(relative)
    print(f"updated {changed} files")


if __name__ == "__main__":
    main()
