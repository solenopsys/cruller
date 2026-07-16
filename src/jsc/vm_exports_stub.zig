//! Stub implementations of zig exports for CUT subsystems (Bake/DevServer routing,
//! Secrets, BunServe plugin resolution, Jest describe scopes) that the C++ side
//! still references at link time even though the corresponding JS API surface is
//! not reachable in this runtime. `virtual_machine_exports.zig` provides the real
//! (non-stub) exports for everything still in the KEEP contract.

const jsc = @import("bun").jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const JSValue = jsc.JSValue;

// --- CLI-derived globals (src/cli/Arguments.zig is fully removed; these
// keep their upstream defaults since there is no flag parsing to set them). ---

export var Bun__Node__ProcessNoDeprecation: bool = false;
export var Bun__Node__ProcessThrowDeprecation: bool = false;
export var Bun__Node__UseSystemCA: bool = false;

/// `process.release.sourceUrl`. Real value in reference is generated from
/// the upgrade command's version/target templating (src/cli/upgrade_command.zig),
/// which is CUT here; a literal release-download base URL still satisfies
/// the Node `process.release` shape without pulling in the upgrade command.
pub export const Bun__githubURL: [*:0]const u8 = "https://github.com/oven-sh/bun/releases";

pub export fn BakeProdResolve(_: *JSGlobalObject, _: *jsc.CallFrame) JSValue {
    return .js_undefined;
}

pub export fn BakeProdLoad(_: *JSGlobalObject, _: *jsc.CallFrame) JSValue {
    return .js_undefined;
}

pub export fn Bake__getNewRouteParamsJSFunctionImpl(_: *JSGlobalObject) JSValue {
    return .js_undefined;
}

// NOTE: Bun__Secrets__scheduleJob is NOT stubbed here — src/jsc/JSSecrets.zig
// is a real, live implementation (kept alive via fixDeadCodeElimination(),
// called from bun.js.zig's Run exit path), not a CUT feature.

pub export fn Bun__Node__ZeroFillBuffers(_: *JSGlobalObject, _: *jsc.CallFrame) JSValue {
    return .js_undefined;
}

pub export fn BunServe__onResolvePlugins(_: *JSGlobalObject, _: *jsc.CallFrame) JSValue {
    return .js_undefined;
}

pub export fn BunServe__onRejectPlugins(_: *JSGlobalObject, _: *jsc.CallFrame) JSValue {
    return .js_undefined;
}

pub export fn Bun__TestScope__Describe2__bunTestThen(_: *JSGlobalObject, _: *jsc.CallFrame) JSValue {
    return .js_undefined;
}

pub export fn Bun__TestScope__Describe2__bunTestCatch(_: *JSGlobalObject, _: *jsc.CallFrame) JSValue {
    return .js_undefined;
}
