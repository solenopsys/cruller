pub inline fn file(comptime path: []const u8) []const u8 {
    _ = path;
    @compileError("codegen embeds are unavailable without -Dcodegen_embed=true");
}
