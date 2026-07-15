#!/usr/bin/env python3
"""Remove npm-on-import and standalone-compiler residue from bzrt runtime."""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def rewrite(rel: str, transform):
    path = ROOT / rel
    before = path.read_text()
    after = transform(before)
    if after == before:
        raise RuntimeError(f"{rel}: expected a change")
    path.write_text(after)
    print(rel)


def sub_once(text: str, pattern: str, replacement: str, rel: str, flags=0) -> str:
    result, count = re.subn(pattern, replacement, text, count=1, flags=flags)
    if count != 1:
        raise RuntimeError(f"{rel}: expected one match, got {count}")
    return result


def async_module(text: str) -> str:
    replacement = '''    pub const Queue = struct {
        /// Package installation during module resolution is intentionally disabled.
        pub fn enqueue(_: *Queue, _: *JSGlobalObject, _: anytype) void {
            unreachable;
        }

        pub fn onDependencyError(_: *anyopaque, _: Dependency, _: Install.DependencyID, _: anyerror) void {}
        pub fn onWakeHandler(_: *anyopaque, _: *PackageManager) void {}
        pub fn onPoll(_: *Queue) void {}

        pub fn vm(this: *Queue) *VirtualMachine {
            return @alignCast(@fieldParentPtr("modules", this));
        }
    };

'''
    return sub_once(
        text,
        r"    pub const Queue = struct \{.*?\n    pub fn init\(",
        replacement + "    pub fn init(",
        "src/jsc/AsyncModule.zig",
        re.S,
    )


def module_loader(text: str) -> str:
    rel = "src/jsc/ModuleLoader.zig"
    text = sub_once(
        text,
        r"pub fn resolveEmbeddedFile\(.*?\n\}\n\npub export fn Bun__getDefaultLoader",
        '''pub fn resolveEmbeddedFile(_: *VirtualMachine, _: *bun.PathBuffer, _: []const u8, _: []const u8) ?[]const u8 {
    return null;
}

pub export fn Bun__getDefaultLoader''',
        rel,
        re.S,
    )
    text = sub_once(
        text,
        r"            if \(parse_result\.pending_imports\.len > 0\) \{.*?\n            \}\n\n            if \(!jsc_vm\.macro_mode\)",
        '''            if (parse_result.pending_imports.len > 0) {
                // bzrt never installs packages while loading production modules.
                return error.UnexpectedPendingResolution;
            }

            if (!jsc_vm.macro_mode)''',
        rel,
        re.S,
    )
    text = sub_once(
        text,
        r"        \.html => \{.*?\n        \},\n\n        else => \{",
        '''        .html => return error.NotSupported,

        else => {''',
        rel,
        re.S,
    )
    text = text.replace(
        '        .@"bun:wrap" => .{',
        '        .@"node:path/win32" => null,\n        .@"bun:wrap" => .{',
        1,
    )
    text = sub_once(
        text,
        r"    \} else if \(jsc_vm\.standalone_module_graph\) \|graph\| \{.*?\n    \}\n\n    return null;",
        '''    }

    return null;''',
        rel,
        re.S,
    )
    return text


def node_process(text: str) -> str:
    return sub_once(
        text,
        r"    // For compiled/standalone executables,.*?\n    var args = try",
        "    var args = try",
        "src/runtime/node/node_process.zig",
        re.S,
    )


def web_worker(text: str) -> str:
    rel = "src/jsc/web_worker.zig"
    text = sub_once(
        text,
        r"    if \(this\.execArgv\) \|exec_argv\| parse_new_args: \{.*?\n    \}\n\n    this\.arena =",
        "    this.arena =",
        rel,
        re.S,
    )
    text = sub_once(
        text,
        r"    if \(parent\.standalone_module_graph\) \|graph\| \{.*?\n    \}\n\n    if \(bun\.webcore\.ObjectURLRegistry\.isBlobURL",
        "    if (bun.webcore.ObjectURLRegistry.isBlobURL",
        rel,
        re.S,
    )
    return text


def blob(text: str) -> str:
    return sub_once(
        text,
        r"\n                if \(vm\.standalone_module_graph\) \|graph\| \{.*?\n                \}\n\n                path_or_fd\.toThreadSafe\(\);",
        "\n                path_or_fd.toThreadSafe();",
        "src/runtime/webcore/Blob.zig",
        re.S,
    )


def parsed_source_map(text: str) -> str:
    return sub_once(
        text,
        r"\npub fn standaloneModuleGraphData\(.*?\n\}\n",
        "\n",
        "src/sourcemap/ParsedSourceMap.zig",
        re.S,
    )


def js_printer(text: str) -> str:
    rel = "src/js_printer/js_printer.zig"
    text = text.replace("\n    mangled_props: ?*const bun.bundle_v2.MangledProps,\n", "\n", 1)
    return sub_once(
        text,
        r"            // TODO: we don't support that\n            if \(p\.options\.mangled_props != null\) \{.*?\n            \}\n            return p\.renamer",
        "            return p.renamer",
        rel,
        re.S,
    )


if "bun.bundle_v2.MangledProps" not in (ROOT / "src/js_printer/js_printer.zig").read_text():
    print("package/standalone cleanup already applied")
    raise SystemExit(0)

rewrite("src/jsc/AsyncModule.zig", async_module)
rewrite("src/jsc/ModuleLoader.zig", module_loader)
rewrite("src/runtime/node/node_process.zig", node_process)
rewrite("src/jsc/web_worker.zig", web_worker)
rewrite("src/runtime/webcore/Blob.zig", blob)
rewrite("src/sourcemap/ParsedSourceMap.zig", parsed_source_map)
rewrite("src/js_printer/js_printer.zig", js_printer)

for rel in (
    "src/interchange/json.zig",
    "src/runtime/api/TOMLObject.zig",
    "src/runtime/server/server.zig",
    "src/bundler/transpiler.zig",
):
    rewrite(rel, lambda text: text.replace("                    .mangled_props = null,\n", "").replace("            .mangled_props = null,\n", "").replace("        .mangled_props = null,\n", "").replace(".{ .mangled_props = null }", ".{}"))

rewrite(
    "src/jsc/rare_data.zig",
    lambda text: text.replace(
        "stat_watchers_for_isolation: std.ArrayListUnmanaged(*StatWatcher) = .{},",
        "stat_watchers_for_isolation: std.ArrayListUnmanaged(*StatWatcher) = .empty,",
    ),
)
