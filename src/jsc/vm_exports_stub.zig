//! Stub implementations of zig exports that virtual_machine_exports.zig normally
//! provides. This file avoids importing stripped modules (IPC, PluginRunner, Bake,
//! DevServer source providers). The C++ side depends on these symbols at link time.

const std = @import("std");
const bun = @import("bun");
const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const JSValue = jsc.JSValue;
const VirtualMachine = jsc.VirtualMachine;

pub export fn Bun__getVM() *jsc.VirtualMachine {
    return jsc.VirtualMachine.get();
}

pub export fn Bun__queueTask(global: *JSGlobalObject, task: *jsc.CppTask) void {
    jsc.markBinding(@src());
    global.bunVM().eventLoop().enqueueTask(jsc.Task.init(task));
}

pub export fn Bun__reportUnhandledError(globalObject: *JSGlobalObject, value: JSValue) JSValue {
    jsc.markBinding(@src());
    if (!value.isTerminationException()) {
        _ = globalObject.bunVM().uncaughtException(globalObject, value, false);
    }
    return .js_undefined;
}

pub export fn Bun__queueTaskConcurrently(global: *JSGlobalObject, task: *jsc.CppTask) void {
    jsc.markBinding(@src());
    global.bunVMConcurrently().eventLoop().enqueueTaskConcurrent(
        jsc.ConcurrentTask.create(jsc.Task.init(task)),
    );
}

pub export fn Bun__handleRejectedPromise(global: *JSGlobalObject, promise: *jsc.JSPromise) void {
    jsc.markBinding(@src());
    const result = promise.result(global.vm());
    var jsc_vm = global.bunVM();
    if (result == .zero) return;
    jsc_vm.unhandledRejection(global, result, promise.toJS());
    jsc_vm.autoGarbageCollect();
}

pub export fn Bun__handleHandledPromise(global: *JSGlobalObject, promise: *jsc.JSPromise) void {
    const Context = struct {
        globalThis: *jsc.JSGlobalObject,
        promise: jsc.JSValue,
        pub fn callback(context: *@This()) void {
            _ = context.globalThis.bunVM().handledPromise(context.globalThis, context.promise);
            context.promise.unprotect();
            bun.default_allocator.destroy(context);
        }
    };
    jsc.markBinding(@src());
    const promise_js = promise.toJS();
    promise_js.protect();
    const context = bun.handleOom(bun.default_allocator.create(Context));
    context.* = .{ .globalThis = global, .promise = promise_js };
    global.bunVM().eventLoop().enqueueTask(jsc.ManagedTask.New(Context, Context.callback).init(context));
}

export fn Bun__readOriginTimer(vm: *jsc.VirtualMachine) u64 {
    if (vm.overridden_performance_now) |overridden| return overridden;
    return vm.origin_timer.read();
}

export fn Bun__readOriginTimerStart(vm: *jsc.VirtualMachine) f64 {
    return @as(f64, @floatCast((@as(f64, @floatFromInt(vm.origin_timestamp)) + jsc.VirtualMachine.origin_relative_epoch) / 1_000_000.0));
}

pub export fn Bun__setTLSRejectUnauthorizedValue(value: i32) void {
    VirtualMachine.get().default_tls_reject_unauthorized = value != 0;
}

pub export fn Bun__setVerboseFetchValue(value: i32) void {
    VirtualMachine.get().default_verbose_fetch = if (value == 1) .headers else if (value == 2) .curl else .none;
}

// --- Bake / DevServer stubs (features stripped) ---

pub export fn BakeProdResolve(_: *JSGlobalObject, _: *jsc.CallFrame) JSValue {
    return .js_undefined;
}

pub export fn BakeProdLoad(_: *JSGlobalObject, _: *jsc.CallFrame) JSValue {
    return .js_undefined;
}

pub export fn Bun__addBakeSourceProviderSourceMap(_: *VirtualMachine, _: *anyopaque, _: *bun.String) void {}

pub export fn Bun__addDevServerSourceProvider(_: *VirtualMachine, _: *anyopaque, _: *bun.String) void {}

pub export fn Bun__removeDevServerSourceProvider(_: *VirtualMachine, _: *anyopaque, _: *bun.String) void {}

pub export fn Bake__getNewRouteParamsJSFunctionImpl(_: *JSGlobalObject) JSValue {
    return .js_undefined;
}

pub export fn Bun__Secrets__scheduleJob(_: *JSGlobalObject, _: *jsc.CallFrame) JSValue {
    return .js_undefined;
}

pub export fn Bun__Node__ZeroFillBuffers(_: *JSGlobalObject, _: *jsc.CallFrame) JSValue {
    return .js_undefined;
}

pub export fn BunServe__onResolvePlugins(_: *JSGlobalObject, _: *jsc.CallFrame) JSValue {
    return .js_undefined;
}

pub export fn BunServe__onRejectPlugins(_: *JSGlobalObject, _: *jsc.CallFrame) JSValue {
    return .js_undefined;
}

pub export fn Bun__TestScope__Describe2__bunTestThen(_: *JSGlobalObject, _: *jsc.CallFrame) JSValue {
    return .js_undefined;
}

pub export fn Bun__TestScope__Describe2__bunTestCatch(_: *JSGlobalObject, _: *jsc.CallFrame) JSValue {
    return .js_undefined;
}
