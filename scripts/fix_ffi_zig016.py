#!/usr/bin/env python3
from pathlib import Path


PATH = Path(__file__).resolve().parents[1] / "src/runtime/ffi/ffi.zig"


def replace_exact(text: str, old: str, new: str, expected: int = 1) -> str:
    found = text.count(old)
    if found != expected:
        raise SystemExit(f"expected {expected} occurrences, found {found}: {old[:100]!r}")
    return text.replace(old, new)


text = PATH.read_text()
text = replace_exact(text, "std.ArrayListUnmanaged([2][:0]const u8) = .{}", "std.ArrayListUnmanaged([2][:0]const u8) = .empty")
text = replace_exact(text, "std.ArrayListUnmanaged([]const u8) = .{}", "std.ArrayListUnmanaged([]const u8) = .empty")
text = replace_exact(text, "std.ArrayListUnmanaged(ABIType) = .{}", "std.ArrayListUnmanaged(ABIType) = .empty")
text = replace_exact(text, "std.ArrayListUnmanaged(ABIType){}", "std.ArrayListUnmanaged(ABIType).empty")

for name, allocator, writer in (
    ("combined", "bun.default_allocator", "writer"),
    ("arraylist", "allocator", "writer"),
):
    old = f"var {name} = std.array_list.Managed(u8).init({allocator});\n"
    new = f"var {name} = std.Io.Writer.Allocating.init({allocator});\n"
    text = replace_exact(text, old, new, expected=1 if name == "combined" else 2)
    text = replace_exact(text, f"var {writer} = {name}.writer();", f"const {writer} = &{name}.writer;", expected=1 if name == "combined" else 2)

text = replace_exact(text, "function.printCallbackSourceCode(null, null, &writer)", "function.printCallbackSourceCode(null, null, writer)")
text = replace_exact(text, "function.printSourceCode(&writer)", "function.printSourceCode(writer)")
text = replace_exact(text, "combined.items", "combined.written()")
text = replace_exact(text, "arraylist.items", "arraylist.written()", expected=2)
text = replace_exact(
    text,
    "            var arraylist = std.Io.Writer.Allocating.init(allocator);\n            const writer = &arraylist.writer;",
    "            var arraylist = std.Io.Writer.Allocating.init(allocator);\n            defer arraylist.deinit();\n            const writer = &arraylist.writer;",
)

text = replace_exact(
    text,
    "var source_code = std.array_list.Managed(u8).init(this.allocator);\n            var source_code_writer = source_code.writer();",
    "var source_code = std.Io.Writer.Allocating.init(this.allocator);\n            const source_code_writer = &source_code.writer;",
    expected=2,
)
text = replace_exact(text, "&source_code_writer", "source_code_writer", expected=2)
text = replace_exact(text, "try source_code.append(0);", "try source_code.writer.writeByte(0);", expected=2)
text = replace_exact(text, "source_code.items.len", "source_code.written().len")
text = replace_exact(text, "source_code.items", "source_code.written()", expected=3)

PATH.write_text(text)
print("updated bun:ffi collections and writers for Zig 0.16")
