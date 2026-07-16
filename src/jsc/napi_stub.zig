//! N-API is CUT (see tz.md §7): `src/napi/napi.zig` is fully removed, no
//! native `.node` addon loading is supported. `src/jsc/bindings/napi*.cpp`
//! still compile (module-loading plumbing in ZigGlobalObject.cpp references
//! `napi_env__` unconditionally) and call into a handful of Zig-side helpers
//! at link time. These are minimal ABI-compatible stand-ins, not a NAPI
//! reimplementation: reachable only if a native addon is actually loaded,
//! which the production loader contract doesn't support.

/// Opaque; never dereferenced here. Must stay pointer-sized to match
/// `napi_env__*` on the C++ side.
const napi_env = ?*anyopaque;
/// Matches `napi_value` ABI (boxed `JSC::EncodedJSValue`, an `i64`).
const napi_value = i64;
/// Matches `NapiStatus` (`enum(c_uint)`); 9 == generic_failure.
const napi_status = c_uint;
const napi_generic_failure: napi_status = 9;
const napi_finalize = ?*const fn (napi_env, ?*anyopaque, ?*anyopaque) callconv(.c) void;

pub export fn napi_internal_register_cleanup_zig(_: napi_env) callconv(.c) void {}

pub export fn napi_internal_suppress_crash_on_abort_if_desired() callconv(.c) void {}

/// Reference implementation defers to the microtask queue; since this path
/// is unreachable without a loaded native addon, run the finalizer inline
/// instead of pulling in the task-queue machinery.
pub export fn napi_internal_enqueue_finalizer(env: napi_env, fun: napi_finalize, data: ?*anyopaque, hint: ?*anyopaque) callconv(.c) void {
    if (fun) |f| f(env, data, hint);
}

pub export fn napi_create_string_latin1(_: napi_env, _: ?[*]const u8, _: usize, _: ?*napi_value) callconv(.c) napi_status {
    return napi_generic_failure;
}

pub export fn napi_create_string_utf16(_: napi_env, _: ?[*]const u16, _: usize, _: ?*napi_value) callconv(.c) napi_status {
    return napi_generic_failure;
}

pub export fn napi_create_string_utf8(_: napi_env, _: ?[*]const u8, _: usize, _: ?*napi_value) callconv(.c) napi_status {
    return napi_generic_failure;
}
