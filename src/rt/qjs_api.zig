//! Zig declarations for the persistent C ABI exported by the sibling qjs
//! wrapper. The build links libqjs.so exactly as native/apps/ptah does.

pub const Runtime = opaque {};

pub extern fn qjs_rt_new() ?*Runtime;
pub extern fn qjs_rt_free(runtime: ?*Runtime) void;
pub extern fn qjs_rt_set_timeout_ms(runtime: ?*Runtime, timeout_ms: u32) void;
pub extern fn qjs_rt_has_fn(runtime: ?*Runtime, name: [*]const u8, name_len: usize) c_int;
pub extern fn qjs_rt_load(
    runtime: ?*Runtime,
    source: [*]const u8,
    source_len: usize,
    filename: [*]const u8,
    filename_len: usize,
    output_ptr: *?[*]u8,
    output_len: *usize,
) c_int;
pub extern fn qjs_rt_call(
    runtime: ?*Runtime,
    name: [*]const u8,
    name_len: usize,
    arg: [*]const u8,
    arg_len: usize,
    output_ptr: *?[*]u8,
    output_len: *usize,
) c_int;
pub extern fn qjs_free(ptr: ?[*]u8, len: usize) void;
