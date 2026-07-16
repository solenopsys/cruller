//! bzrt: vanilla Zig 0.16 build.zig — заменяет Oven-patched оригинал.
//! Интерфейс: `zig build obj` → bun-zig.o (для линковки с C++/JSC через Ninja).
//! `zig build check` — полный семантический анализ (как build016.zig).

const std = @import("std");

const ObjectFormat = enum { obj, bc };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Keep this option surface compatible with scripts/build/zig.ts. The
    // native build invokes `zig build obj` with these values for every profile.
    const codegen_path = b.option([]const u8, "codegen_path", "Generated Zig sources directory") orelse "build/codegen";
    const codegen_embed = b.option(bool, "codegen_embed", "Embed generated code") orelse false;
    const canary_revision = b.option(u32, "canary", "Canary revision") orelse 0;
    const version_text = b.option([]const u8, "version", "Bun version") orelse "1.3.14";
    const sha = b.option([]const u8, "sha", "Git revision") orelse "0000000000000000000000000000000000000000";
    const baseline = b.option(bool, "baseline", "Target the x64 baseline CPU") orelse false;
    const enable_logs = b.option(bool, "enable_logs", "Enable logs") orelse false;
    const enable_asan = b.option(bool, "enable_asan", "Enable AddressSanitizer") orelse false;
    const enable_fuzzilli = b.option(bool, "enable_fuzzilli", "Enable Fuzzilli instrumentation") orelse false;
    const enable_valgrind = b.option(bool, "enable_valgrind", "Enable Valgrind support") orelse false;
    const enable_tinycc = b.option(bool, "enable_tinycc", "Enable TinyCC") orelse true;
    const use_mimalloc = b.option(bool, "use_mimalloc", "Use mimalloc") orelse true;
    const reported_nodejs_version = b.option([]const u8, "reported_nodejs_version", "Reported Node.js version") orelse "24.3.0";
    const no_llvm = b.option(bool, "no_llvm", "Use Zig self-hosted backend") orelse false;
    const lto = b.option(bool, "lto", "Enable LTO") orelse false;
    const llvm_codegen_threads = b.option(u32, "llvm_codegen_threads", "LLVM codegen threads") orelse 0;
    const obj_format = b.option(ObjectFormat, "obj_format", "Object output format") orelse .obj;
    const override_no_export_cpp_apis = b.option(bool, "override-no-export-cpp-apis", "Override C++ API exports") orelse false;
    const codegen_path_abs = if (std.fs.path.isAbsolute(codegen_path)) codegen_path else b.pathFromRoot(codegen_path);

    // --- build_options ---
    const opts = b.addOptions();
    opts.addOption([]const u8, "base_path", b.pathFromRoot("."));
    opts.addOption([]const u8, "codegen_path", codegen_path_abs);
    opts.addOption(bool, "codegen_embed", codegen_embed);
    opts.addOption(u32, "canary_revision", canary_revision);
    opts.addOption(bool, "is_canary", canary_revision != 0);
    opts.addOption(std.SemanticVersion, "version", std.SemanticVersion.parse(version_text) catch @panic("invalid -Dversion"));
    opts.addOption([:0]const u8, "sha", b.allocator.dupeZ(u8, sha) catch @panic("OOM"));
    opts.addOption(bool, "baseline", baseline);
    opts.addOption(bool, "enable_logs", enable_logs);
    opts.addOption(bool, "enable_asan", enable_asan);
    opts.addOption(bool, "enable_fuzzilli", enable_fuzzilli);
    opts.addOption(bool, "enable_valgrind", enable_valgrind);
    opts.addOption(bool, "enable_tinycc", enable_tinycc);
    opts.addOption(bool, "use_mimalloc", use_mimalloc);
    opts.addOption([]const u8, "reported_nodejs_version", reported_nodejs_version);
    opts.addOption(bool, "zig_self_hosted_backend", no_llvm);
    opts.addOption(bool, "override_no_export_cpp_apis", override_no_export_cpp_apis);

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
    const bun_module = b.createModule(.{
        .root_source_file = b.path("src/bun.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bun_module.addImport("bun", bun_module);
    bun_module.addImport("build_options", opts.createModule());
    bun_module.addImport("translated-c-headers", b.createModule(.{
        .root_source_file = translate_c.getOutput(),
    }));

    inline for (.{
        .{ "zlib-internal", "src/zlib_sys/posix.zig" },
        .{ "async", "src/aio/posix_event_loop.zig" },
    }) |entry| {
        const mod = b.createModule(.{ .root_source_file = b.path(entry[1]) });
        mod.addImport("bun", bun_module);
        mod.addImport(entry[0], mod);
        bun_module.addImport(entry[0], mod);
    }

    inline for (.{
        .{ "ZigGeneratedClasses", "ZigGeneratedClasses.zig" },
        .{ "bindgen_generated", "bindgen_generated.zig" },
        .{ "ResolvedSourceTag", "ResolvedSourceTag.zig" },
        .{ "ErrorCode", "ErrorCode.zig" },
        .{ "cpp", "cpp.zig" },
        .{ "ci_info", "ci_info.zig" },
    }) |entry| {
        const mod = b.createModule(.{ .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ codegen_path_abs, entry[1] }) } });
        mod.addImport("bun", bun_module);
        mod.addImport(entry[0], mod);
        bun_module.addImport(entry[0], mod);
    }

    // --- корневой модуль для собранного бинарника (main.zig) ---
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    root.addImport("bun", bun_module);

    // --- шаг "obj": объектник для линковки с C++ ---
    const obj = b.addObject(.{
        .name = "bun-zig",
        .root_module = root,
    });
    obj.root_module.pic = true;
    obj.root_module.omit_frame_pointer = false;
    obj.root_module.strip = false;
    obj.use_llvm = !no_llvm;
    obj.use_lld = !no_llvm;
    if (lto) obj.lto = .full;
    if (@hasField(std.meta.Child(@TypeOf(obj)), "llvm_codegen_threads")) {
        obj.llvm_codegen_threads = llvm_codegen_threads;
    }
    // vanilla Zig 0.16 removed Build.Module.sanitize_address. C/C++ still
    // receive -fsanitize=address from scripts/build/flags.ts; keep the build
    // option accepted until the Zig-side sanitizer API is wired up.
    if (enable_asan and @hasField(std.Build.Module, "sanitize_address")) {
        obj.root_module.sanitize_address = true;
    }
    if (enable_fuzzilli) obj.sanitize_coverage_trace_pc_guard = true;
    obj.bundle_compiler_rt = true;
    obj.bundle_ubsan_rt = false;

    const obj_step = b.step("obj", "Собрать bun-zig.o для линковки с C++/JSC");
    obj_step.dependOn(&obj.step);
    const output = switch (obj_format) {
        .obj => obj.getEmittedBin(),
        .bc => obj.getEmittedLlvmBc(),
    };
    obj_step.dependOn(&b.addInstallFile(output, "bun-zig.o").step);

    // --- шаг "check": полный семантический анализ ---
    const check_root = b.createModule(.{
        .root_source_file = b.path("check_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    check_root.addImport("bun", bun_module);

    const check_obj = b.addObject(.{
        .name = "bzrt-check",
        .root_module = check_root,
    });
    const check_step = b.step("check", "Семантический анализ урезанного дерева");
    check_step.dependOn(&check_obj.step);
}
