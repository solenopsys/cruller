pub const Kind = enum {
    jsc,
    quickjs,
    v8,
};

/// Compile-time selection keeps an unused engine and its native library out of
/// the final link while both implementations share contract.Engine.
pub fn Implementation(comptime kind: Kind) type {
    return switch (kind) {
        .jsc => @import("./jsc_engine.zig").JscEngine,
        .quickjs => @import("./quickjs_engine.zig").QuickJsEngine,
        .v8 => @import("./v8_engine.zig").V8Engine,
    };
}
