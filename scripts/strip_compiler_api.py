#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def replace_exact(text: str, old: str, new: str, expected: int = 1) -> str:
    found = text.count(old)
    if found != expected:
        raise SystemExit(f"expected {expected} occurrences, found {found}: {old[:100]!r}")
    return text.replace(old, new)


def remove_between(text: str, start: str, end: str) -> str:
    if text.count(start) != 1:
        raise SystemExit(f"non-unique range start: {start!r}")
    a = text.index(start)
    b = text.find(end, a)
    if b < 0:
        raise SystemExit(f"missing range end: {end!r}")
    return text[:a] + text[b:]


path = ROOT / "src/runtime/api.zig"
text = path.read_text()
for line in (
    "pub const HTMLBundle = server.HTMLBundle;\n",
    'pub const BuildArtifact = @import("./api/JSBundler.zig").BuildArtifact;\n',
    'pub const JSBundler = @import("./api/JSBundler.zig").JSBundler;\n',
    'pub const JSTranspiler = @import("./api/JSTranspiler.zig");\n',
):
    text = replace_exact(text, line, "")
path.write_text(text)


path = ROOT / "src/jsc/generated_classes_list.zig"
text = path.read_text()
for block in (
    '''    pub const Bundler = api.JSBundler;
    pub const JSBundler = Bundler;
    pub const Transpiler = api.JSTranspiler;
    pub const JSTranspiler = Transpiler;
''',
    "    pub const BuildArtifact = api.BuildArtifact;\n",
    "    pub const FrameworkFileSystemRouter = bun.bake.FrameworkRouter.JSFrameworkRouter;\n",
    "    pub const HTMLBundle = api.HTMLBundle;\n",
):
    text = replace_exact(text, block, "")
path.write_text(text)


path = ROOT / "src/runtime/api/BunObject.zig"
text = path.read_text()
for line in (
    "    pub const build = toJSCallback(Bun.JSBundler.buildFn);\n",
    "    pub const registerMacro = toJSCallback(Bun.registerMacro);\n",
    "    pub const Transpiler = toJSLazyPropertyCallback(Bun.getTranspilerConstructor);\n",
    "    pub const embeddedFiles = toJSLazyPropertyCallback(Bun.getEmbeddedFiles);\n",
    '        @export(&BunObject.Transpiler, .{ .name = lazyPropertyCallbackName("Transpiler") });\n',
    '        @export(&BunObject.embeddedFiles, .{ .name = lazyPropertyCallbackName("embeddedFiles") });\n',
    '        @export(&BunObject.build, .{ .name = callbackName("build") });\n',
    '        @export(&BunObject.registerMacro, .{ .name = callbackName("registerMacro") });\n',
    "const JSBundler = bun.jsc.API.JSBundler;\n",
    "const Transpiler = bun.jsc.API.JSTranspiler;\n",
):
    text = replace_exact(text, line, "")
text = remove_between(text, "pub fn registerMacro(", "pub fn getCWD(")
text = remove_between(text, "pub fn getTranspilerConstructor(", "pub fn getFileSystemRouter(")
text = remove_between(text, "pub fn getEmbeddedFiles(", "pub fn getSemver(")
path.write_text(text)


path = ROOT / "src/jsc/bindings/BunObject+exports.h"
text = path.read_text()
for line in ("    macro(Transpiler) \\\n", "    macro(build) \\\n", "    macro(registerMacro) \\\n"):
    text = replace_exact(text, line, "")
path.write_text(text)


path = ROOT / "src/jsc/bindings/BunObject.cpp"
text = path.read_text()
for token in ("Transpiler", "embeddedFiles", "build", "registerMacro"):
    lines = [line for line in text.splitlines(keepends=True) if not (line.lstrip().startswith(token) and "BunObject_" in line)]
    new = "".join(lines)
    if new == text:
        raise SystemExit(f"missing BunObject table entry: {token}")
    text = new
path.write_text(text)


(ROOT / "src/runtime/api/JSBundler.classes.ts").write_text(
    'import { define } from "../../codegen/class-definitions";\n\nvoid define;\nexport default [];\n'
)

path = ROOT / "src/runtime/api/filesystem_router.classes.ts"
text = path.read_text()
text = remove_between(text, '  define({\n    name: "FrameworkFileSystemRouter",', '  define({\n    name: "MatchedRoute",')
path.write_text(text)

path = ROOT / "src/runtime/server/server.classes.ts"
text = path.read_text()
text = remove_between(text, '  define({\n    name: "HTMLBundle",', "];\n")
path.write_text(text)

print("removed runtime compiler/Bake classes and BunObject exports")
