#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FFI = ROOT / "src/runtime/ffi/ffi.zig"
JS = ROOT / "src/js/bun/ffi.ts"


def replace_exact(text: str, old: str, new: str, expected: int = 1) -> str:
    found = text.count(old)
    if found != expected:
        raise SystemExit(f"expected {expected} occurrences, found {found}: {old[:80]!r}")
    return text.replace(old, new)


text = FFI.read_text()

text = replace_exact(
    text,
    '''            for (this.symbols.map.values()) |*symbol| {
                if (symbol.needsNapiEnv()) {
                    state.addSymbol("Bun__thisFFIModuleNapiEnv", globalThis.makeNapiEnvForFFI()) catch return error.DeferredErrors;
                    break;
                }
            }

''',
    "",
)

text = replace_exact(
    text,
    "        const napi_env = makeNapiEnvIfNeeded(compile_c.symbols.map.values(), globalThis);\n\n",
    "",
)
text = replace_exact(
    text,
    "        const napi_env = makeNapiEnvIfNeeded(symbols.values(), global);\n\n",
    "",
    expected=2,
)
text = replace_exact(text, "function.compile(napi_env)", "function.compile()", expected=3)

text = replace_exact(
    text,
    '''        pub fn needsHandleScope(val: *const Function) bool {
            for (val.arg_types.items) |arg| {
                if (arg == ABIType.napi_env or arg == ABIType.napi_value) {
                    return true;
                }
            }
            return val.return_type == ABIType.napi_value;
        }

''',
    "",
)
text = replace_exact(text, "        pub fn compile(this: *Function, napiEnv: ?*napi.NapiEnv) !void {", "        pub fn compile(this: *Function) !void {")
text = replace_exact(
    text,
    '''            if (napiEnv) |env| {
                _ = state.addSymbol("Bun__thisFFIModuleNapiEnv", env) catch {
                    this.fail("Failed to add NAPI env symbol");
                    return;
                };
            }

''',
    "",
)
text = replace_exact(
    text,
    '''            if (this.needsNapiEnv()) {
                state.addSymbol("Bun__thisFFIModuleNapiEnv", js_context.makeNapiEnvForFFI()) catch {
                    this.fail("Failed to add NAPI env symbol");
                    return;
                };
            }

''',
    "",
)

text = replace_exact(
    text,
    r'''            if (this.needsHandleScope()) {
                try writer.writeAll(
                    \\  void* handleScope = NapiHandleScope__open(&Bun__thisFFIModuleNapiEnv, false);
                    \\
                );
            }

''',
    "",
)
text = replace_exact(
    text,
    r'''            if (this.needsHandleScope()) {
                try writer.writeAll(
                    \\  NapiHandleScope__close(&Bun__thisFFIModuleNapiEnv, handleScope);
                    \\
                );
            }

''',
    "",
)
text = replace_exact(
    text,
    '''        fn needsNapiEnv(this: *const FFI.Function) bool {
            for (this.arg_types.items) |arg| {
                if (arg == .napi_env or arg == .napi_value) {
                    return true;
                }
            }

            return false;
        }
''',
    "",
)

text = replace_exact(
    text,
    '''            .{ "napi_env", ABIType.napi_env },
            .{ "napi_value", ABIType.napi_value },
''',
    "",
)
text = replace_exact(
    text,
    '''        state.addSymbol("NapiHandleScope__open", &bun.api.napi.NapiHandleScope.NapiHandleScope__open) catch unreachable;
        state.addSymbol("NapiHandleScope__close", &bun.api.napi.NapiHandleScope.NapiHandleScope__close) catch unreachable;

''',
    "",
)
text = replace_exact(
    text,
    '''fn makeNapiEnvIfNeeded(functions: []const FFI.Function, globalThis: *JSGlobalObject) ?*napi.NapiEnv {
    for (functions) |function| {
        if (function.needsNapiEnv()) {
            return globalThis.makeNapiEnvForFFI();
        }
    }

    return null;
}

''',
    "",
)
text = replace_exact(text, 'const napi = @import("../../napi/napi.zig");\n', "")

text = replace_exact(
    text,
    '''        if (return_type == ABIType.napi_env) {
            abi_types.clearAndFree(allocator);
            return ZigString.static("Cannot return napi_env to JavaScript").toErrorInstance(global);
        }
''',
    '''        for (abi_types.items) |abi_type| {
            if (abi_type == .napi_env or abi_type == .napi_value) {
                abi_types.clearAndFree(allocator);
                return ZigString.static("N-API ABI types are not supported in this runtime").toErrorInstance(global);
            }
        }

        if (return_type == .napi_env or return_type == .napi_value) {
            abi_types.clearAndFree(allocator);
            return ZigString.static("N-API ABI types are not supported in this runtime").toErrorInstance(global);
        }
''',
)

FFI.write_text(text)

js = JS.read_text()
js = replace_exact(js, "  napi_env: 18,\n  napi_value: 19,\n", "")
JS.write_text(js)

print("stripped N-API-only ABI support from bun:ffi")
