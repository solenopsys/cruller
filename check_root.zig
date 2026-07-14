//! bzrt: корень type-check — тянет все top-level decl'ы модуля "bun",
//! чтобы компилятор загрузил и проанализировал keep-дерево вширь.
const std = @import("std");

comptime {
    std.testing.refAllDecls(@import("bun"));
}
