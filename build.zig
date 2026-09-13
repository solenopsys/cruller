//! bzrt: vanilla Zig 0.16 build.zig — replaces the Oven-patched original.
//! Interface: `zig build obj` → bun-zig.o (for linking with C++/JSC via Ninja).
//! `zig build check` — full semantic analysis (same as build016.zig).

const std = @import("std");

const ObjectFormat = enum { obj, bc };

const qjs_wrapper_dir = "../qjs";
const v8_wrapper_dir = "../v8";

fn qjsTargetTriple(b: *std.Build, target: std.Build.ResolvedTarget) []const u8 {
    const arch = switch (target.result.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => std.debug.panic("unsupported cpu arch for qjs: {s}", .{@tagName(target.result.cpu.arch)}),
    };
    const libc = switch (target.result.abi) {
        .gnu, .gnueabi, .gnueabihf => "gnu",
        .musl, .musleabi, .musleabihf => "musl",
        else => std.debug.panic("unsupported abi for qjs: {s}", .{@tagName(target.result.abi)}),
    };
    return b.fmt("{s}-linux-{s}", .{ arch, libc });
}

fn linkQjsForTest(b: *std.Build, compile: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) []const u8 {
    const target_dir = b.fmt("{s}-{s}", .{ @tagName(target.result.cpu.arch), @tagName(target.result.abi) });
    const install_dir = b.fmt("../cruller/.zig-cache/qjs/{s}", .{target_dir});
    const lib_dir = b.fmt(".zig-cache/qjs/{s}/lib", .{target_dir});
    const wrapper = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        b.fmt("-Dtarget={s}", .{qjsTargetTriple(b, target)}),
        b.fmt("-Doptimize={s}", .{@tagName(optimize)}),
        "--prefix",
        install_dir,
    });
    wrapper.setCwd(b.path(qjs_wrapper_dir));
    wrapper.setName("build QuickJS wrapper");
    compile.step.dependOn(&wrapper.step);
    compile.root_module.addLibraryPath(.{ .cwd_relative = lib_dir });
    compile.root_module.linkSystemLibrary("qjs", .{});
    compile.root_module.link_libc = true;
    return lib_dir;
}

/// Build the sibling v8 wrapper (real backend) into
/// ../cruller/.zig-cache/v8/<arch>-<abi>/ and link its shim archive plus
/// the prebuilt V8 monolith into `compile`. The monolith objects use CREL
/// relocations and local-exec TLS: GNU ld cannot consume them, and they
/// cannot go into a -shared .so — so this path forces lld and only works
/// for the native-target test binary.
fn linkV8ForTest(b: *std.Build, compile: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const target_dir = b.fmt("{s}-{s}", .{ @tagName(target.result.cpu.arch), @tagName(target.result.abi) });
    const install_dir = b.fmt("../cruller/.zig-cache/v8/{s}", .{target_dir});
    const wrapper = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "-Dv8-backend=real",
        b.fmt("-Dtarget={s}", .{qjsTargetTriple(b, target)}),
        b.fmt("-Doptimize={s}", .{@tagName(optimize)}),
        "--prefix",
        install_dir,
    });
    wrapper.setCwd(b.path(v8_wrapper_dir));
    wrapper.setName("build V8 wrapper (real)");
    compile.step.dependOn(&wrapper.step);

    // The v8 wrapper's third-party bundle (headers + prebuilt monolith +
    // system-compiled shim) lives in its own source tree; cruller only
    // references it, never copies it.
    const shim_src = b.fmt("{s}/third-party/v8-shim.o", .{v8_wrapper_dir});
    const monolith_src = b.fmt("{s}/third-party/v8/libv8_monolith.a", .{v8_wrapper_dir});
    compile.root_module.addObjectFile(b.path(shim_src));
    compile.root_module.addObjectFile(.{ .cwd_relative = b.pathFromRoot(monolith_src) });
    // Shim + monolith were compiled against the system libstdc++ (regpacy
    // recipe: system clang++, not Zig's bundled libc++ which mangles
    // std::__1::*). Zig has no direct "link this exact .so" API, so pass
    // the full path as an extra linker object — lld accepts a shared
    // library as input and resolves the std::* symbols from it.
    compile.root_module.addObjectFile(.{ .cwd_relative = "/usr/lib/gcc/x86_64-pc-linux-gnu/16/libstdc++.so" });
    compile.root_module.linkSystemLibrary("atomic", .{});
    compile.root_module.link_libc = true;
    compile.root_module.link_libcpp = false;
    compile.use_llvm = true;
    compile.use_lld = true;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse .ReleaseFast;

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

    // --- "bun" module ---
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
    const codegen_embed_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ codegen_path_abs, "embed.zig" }) },
    });
    bun_module.addImport("codegen_embed", codegen_embed_module);

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

    // --- root module for the built binary (main.zig) ---
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    root.addImport("bun", bun_module);

    // --- "obj" step: object file for linking with C++ ---
    const obj = b.addObject(.{
        .name = "bun-zig",
        .root_module = root,
    });
    obj.root_module.pic = true;
    obj.root_module.omit_frame_pointer = false;
    obj.root_module.strip = false;
    // LLVM 21's StackProtector pass segfaults in
    // AttributeList::addAttributeAtIndex while instrumenting `sspstrong`
    // functions in this module graph (reproduced standalone via `llc-21` on
    // the `--verbose-llvm-ir` dump: crashes on `debug.waitForOtherThreadToFinishPanicking`,
    // a stock std/debug.zig function, not bzrt-specific code — see problem.md).
    // Disable stack-protector codegen until upstream fixes it.
    obj.root_module.stack_protector = false;
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

    const obj_step = b.step("obj", "Build bun-zig.o for linking with C++/JSC");
    obj_step.dependOn(&obj.step);
    const output = switch (obj_format) {
        .obj => obj.getEmittedBin(),
        .bc => obj.getEmittedLlvmBc(),
    };
    obj_step.dependOn(&b.addInstallFile(output, "bun-zig.o").step);

    // --- "check" step: full semantic analysis ---
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
    const check_step = b.step("check", "Semantic analysis of the trimmed tree");
    check_step.dependOn(&check_obj.step);

    const rt_test_root = b.createModule(.{
        .root_source_file = b.path("src/rt/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const rt_tests = b.addTest(.{
        .name = "rt-boundary-tests",
        .root_module = rt_test_root,
    });
    const run_rt_tests = b.addRunArtifact(rt_tests);

    const qjs_tests = b.addTest(.{
        .name = "rt-quickjs-engine-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/rt/quickjs_engine_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const qjs_lib_dir = linkQjsForTest(b, qjs_tests, target, optimize);
    const run_qjs_tests = b.addRunArtifact(qjs_tests);
    run_qjs_tests.setEnvironmentVariable("LD_LIBRARY_PATH", b.pathFromRoot(qjs_lib_dir));

    const v8_tests = b.addTest(.{
        .name = "rt-v8-engine-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/rt/v8_engine_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    linkV8ForTest(b, v8_tests, target, optimize);
    const run_v8_tests = b.addRunArtifact(v8_tests);

    const rt_test_step = b.step("rt-test", "Test the direct transports of the runtime boundary");
    rt_test_step.dependOn(&run_rt_tests.step);
    rt_test_step.dependOn(&run_qjs_tests.step);
    rt_test_step.dependOn(&run_v8_tests.step);

    // --- "ssr-run" step: ONE binary — the same SSR bundle, engine
    // selected at runtime via the `--engine=quickjs|v8` flag.
    // (Per-engine binaries removed: switch via a flag,
    // not by rebuilding. jsc is run with the same bundle via bun — see
    // ssr-run/jsc_ssr_check.js; the bun monolith is not linked into the zig binary.)
    const ssr_root = b.createModule(.{
        .root_source_file = b.path("src/rt/ssr_run.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // WITHOUT bun and WITHOUT build_options: engine is a runtime flag, bundle is argv.
    // ssr_run.zig imports only contract + both engines (pure std).
    const ssr_exe = b.addExecutable(.{
        .name = "ssr-run",
        .root_module = ssr_root,
    });
    // qjs is linked dynamically (.so alongside), v8 statically (shim + monolith).
    const ssr_qjs_lib_dir = linkQjsForTest(b, ssr_exe, target, optimize);
    linkV8ForTest(b, ssr_exe, target, optimize);
    const run_ssr = b.addRunArtifact(ssr_exe);
    run_ssr.setEnvironmentVariable("LD_LIBRARY_PATH", b.pathFromRoot(ssr_qjs_lib_dir));
    if (b.args) |args| run_ssr.addArgs(args);
    const ssr_step = b.step("ssr-run", "Run the SSR bundle: --engine quickjs|v8 --bundle <bundle.js>");
    ssr_step.dependOn(&run_ssr.step);
    const ssr_install = b.step("ssr-install", "Build the ssr-run binary (both engines inside)");
    ssr_install.dependOn(&b.addInstallArtifact(ssr_exe, .{}).step);
}
