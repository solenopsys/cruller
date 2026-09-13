//! Zig declarations for the persistent C ABI exported by the sibling v8
//! wrapper. Same shape as qjs_api.zig: the build links the v8 shim
//! statically (libv8.a) plus the prebuilt V8 monolith from
//! ../v8/third-party/v8/.

pub const Runtime = opaque {};

pub extern fn v8_rt_new() ?*Runtime;
pub extern fn v8_rt_free(runtime: ?*Runtime) void;
pub extern fn v8_rt_set_timeout_ms(runtime: ?*Runtime, timeout_ms: u32) void;
pub extern fn v8_rt_has_fn(runtime: ?*Runtime, name: [*]const u8, name_len: usize) c_int;
pub extern fn v8_rt_load(
    runtime: ?*Runtime,
    source: [*]const u8,
    source_len: usize,
    filename: [*]const u8,
    filename_len: usize,
    output_ptr: *?[*]u8,
    output_len: *usize,
) c_int;
pub extern fn v8_rt_call(
    runtime: ?*Runtime,
    name: [*]const u8,
    name_len: usize,
    arg: [*]const u8,
    arg_len: usize,
    output_ptr: *?[*]u8,
    output_len: *usize,
) c_int;
pub extern fn v8_free(ptr: ?[*]u8, len: usize) void;
