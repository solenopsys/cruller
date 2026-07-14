//! bzrt: сборочный харнес урезанного Bun на ванильном zig 0.16 (Linux-only).
//!
//! Воспроизводит модульный граф из родного build.zig (addInternalImports):
//! "bun" (циклический self-import) + build_options + translated-c-headers +
//! zlib-internal/async + кодогенные модули из build/codegen (см. scripts/codegen.py).
//!
//! `zig build --build-file build016.zig check` — только семантический анализ
//! (addObject, без линковки JSC/C++).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- build_options: поля 1:1 из BunBuildOptions.buildOptionsModule ---
    const opts = b.addOptions();
    opts.addOption([]const u8, "base_path", b.pathFromRoot("."));
    opts.addOption([]const u8, "codegen_path", b.pathFromRoot("build/codegen"));
    opts.addOption(bool, "codegen_embed", false);
    opts.addOption(u32, "canary_revision", 0);
    opts.addOption(bool, "is_canary", false);
    opts.addOption(std.SemanticVersion, "version", .{ .major = 1, .minor = 3, .patch = 14 });
    opts.addOption([:0]const u8, "sha", "0000000000000000000000000000000000000000");
    opts.addOption(bool, "baseline", false);
    opts.addOption(bool, "enable_logs", false);
    opts.addOption(bool, "enable_asan", false);
    opts.addOption(bool, "enable_fuzzilli", false);
    opts.addOption(bool, "enable_valgrind", false);
    opts.addOption(bool, "enable_tinycc", false);
    opts.addOption(bool, "use_mimalloc", true);
    opts.addOption([]const u8, "reported_nodejs_version", "24.3.0");
    opts.addOption(bool, "zig_self_hosted_backend", false);
    opts.addOption(bool, "override_no_export_cpp_apis", false);

    // --- translated-c-headers ---
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c-headers-for-zig.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate_c.defineCMacroRaw("WINDOWS=0");
    translate_c.defineCMacroRaw("POSIX=1");
    translate_c.defineCMacroRaw("LINUX=1");
    translate_c.defineCMacroRaw("DARWIN=0");
    translate_c.defineCMacroRaw("FREEBSD=0");
    translate_c.addIncludePath(b.path("vendor/zstd/lib"));

    // --- модуль "bun" ---
    const bun = b.createModule(.{
        .root_source_file = b.path("src/bun.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bun.addImport("bun", bun); // разрешённый циклический импорт
    bun.addImport("build_options", opts.createModule());
    bun.addImport("translated-c-headers", b.createModule(.{
        .root_source_file = translate_c.getOutput(),
    }));
    inline for (.{
        .{ "zlib-internal", "src/zlib_sys/posix.zig" },
        .{ "async", "src/aio/posix_event_loop.zig" },
        .{ "ZigGeneratedClasses", "build/codegen/ZigGeneratedClasses.zig" },
        .{ "bindgen_generated", "build/codegen/bindgen_generated.zig" },
        .{ "ResolvedSourceTag", "build/codegen/ResolvedSourceTag.zig" },
        .{ "ErrorCode", "build/codegen/ErrorCode.zig" },
        .{ "cpp", "build/codegen/cpp.zig" },
        .{ "ci_info", "build/codegen/ci_info.zig" },
    }) |entry| {
        const mod = b.createModule(.{ .root_source_file = b.path(entry[1]) });
        mod.addImport("bun", bun);
        mod.addImport(entry[0], mod);
        bun.addImport(entry[0], mod);
    }

    // --- корень type-check ---
    const check_root = b.createModule(.{
        .root_source_file = b.path("check_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    check_root.addImport("bun", bun);

    const obj = b.addObject(.{ .name = "bzrt-check", .root_module = check_root });
    const check = b.step("check", "Семантический анализ урезанного дерева");
    check.dependOn(&obj.step);
}
