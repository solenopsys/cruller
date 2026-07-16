//! Link-time stubs for C++ bindings that belong to CUT subsystems (Bake
//! routing/SSR response construction, `bun:test`/Jest, bundler `onBeforeParse`
//! native plugins, code coverage). The corresponding `src/jsc/bindings/*.cpp`
//! files are still compiled (they're pulled in wholesale by directory glob —
//! see `scripts/glob-sources.ts`), and a few of them reference these Zig
//! exports unconditionally even though the JS entry points that would reach
//! them (`Bun.build`, `bun:test`, Bake dev/prod routing) are not wired up in
//! this runtime. Signatures are copied verbatim from the `extern "C"`
//! declarations in the referencing `.cpp` files so that IF one of these is
//! ever reached despite being logically unreachable, it fails as a clean JS
//! exception (where a JSGlobalObject is available) or an inert default
//! (where it's plain data plumbing) instead of corrupting the ABI.

const bun = @import("bun");
const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const JSValue = jsc.JSValue;

fn throwCutImpl(globalObject: *JSGlobalObject, comptime what: [:0]const u8) bun.JSError!JSValue {
    return globalObject.throw(what ++ " is not available in the bzrt runtime.", .{});
}

fn throwCut(globalObject: *JSGlobalObject, comptime what: [:0]const u8) JSValue {
    return jsc.toJSHostFnResult(globalObject, throwCutImpl(globalObject, what));
}

// --- Bake route bundling (dev/prod routing; CUT) ---
// NOTE: `BakeResponseClass__construct{ForSSR,Redirect,Render}` are NOT
// stubbed here despite living next to this: `src/runtime/webcore/BakeResponse.zig`
// is a real, live implementation of SSR Response construction (kept alive on
// purpose via `fixDeadCodeElimination()`, called from `bun.js.zig`'s Run
// exit path) — unrelated to Bake dev-server routing, which is genuinely cut.

pub export fn Bake__bundleNewRouteJSFunctionImpl(globalObject: *JSGlobalObject, _: ?*anyopaque, _: bun.String) callconv(.c) JSValue {
    return throwCut(globalObject, "Bake routing");
}

// --- Jest / bun:test (CUT) ---

pub export fn Bun__Jest__createTestModuleObject(globalObject: *JSGlobalObject) callconv(.c) JSValue {
    return throwCut(globalObject, "bun:test");
}

pub export fn ExpectMatcherUtils_createSigleton(globalObject: *JSGlobalObject) callconv(.c) JSValue {
    return throwCut(globalObject, "bun:test expect.* matcher utils");
}

pub export fn Expect_readFlagsAndProcessPromise(
    _: JSValue,
    _: *JSGlobalObject,
    _: ?*anyopaque,
    _: ?*JSValue,
    _: ?*anyopaque,
) callconv(.c) bool {
    return false;
}

// --- Code coverage ---
// `ByteRangeMapping__find/getSourceID/generate/findExecutedLines` are NOT
// stubbed here: `src/sourcemap_jsc/CodeCoverage.zig` turned out to be a real,
// live (not dead) implementation reachable through `bun.SourceMap.coverage`
// once the loader actually runs `VirtualMachine.init` — it provides these
// via its own `@export` block (see that file). Only the "should we
// instrument this source" gate is stubbed off, since `bun:test --coverage`
// itself is CUT: this keeps `ByteRangeMapping__generate` unreachable in
// practice without needing a competing stub for the ByteRangeMapping data
// structure functions themselves.
pub export fn BunTest__shouldGenerateCodeCoverage(_: bun.String) callconv(.c) bool {
    return false;
}

// --- Bundler native `onBeforeParse`/`onResolve`/`onLoad` plugin hooks (Bun.build; CUT) ---

pub export fn JSBundlerPlugin__addError(_: ?*anyopaque, _: ?*anyopaque, _: JSValue, _: JSValue) callconv(.c) void {}

pub export fn JSBundlerPlugin__onDefer(_: ?*anyopaque, globalObject: *JSGlobalObject) callconv(.c) JSValue {
    return throwCut(globalObject, "Bun.build plugin defer()");
}

pub export fn JSBundlerPlugin__onLoadAsync(_: ?*anyopaque, _: ?*anyopaque, _: JSValue, _: JSValue) callconv(.c) void {}

pub export fn JSBundlerPlugin__onResolveAsync(_: ?*anyopaque, _: ?*anyopaque, _: JSValue, _: JSValue, _: JSValue) callconv(.c) void {}

/// Only reached inside a native-plugin iteration loop that is itself gated
/// on a non-empty native-callback list; that list is always empty with the
/// JS-side plugin registration cut. `1` (done) is the conservative default
/// if it's ever reached anyway: stop iterating immediately.
pub export fn OnBeforeParsePlugin__isDone(_: ?*anyopaque) callconv(.c) c_int {
    return 1;
}

pub export fn OnBeforeParseResult__reset(_: ?*anyopaque) callconv(.c) void {}
