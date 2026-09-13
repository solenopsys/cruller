//! bzrt: type-check root — pulls all top-level decls of the "bun" module,
//! so the compiler loads and semantically analyzes the keep-tree breadth-wise.
const std = @import("std");

comptime {
    std.testing.refAllDecls(@import("bun"));
}
