// bzrt-cut: markdown renderer (`src/md/`) removed from the runtime (tz.md §1.1).
// Only the JS binding `Bun.markdown` is kept, whose methods throw an exception —
// the object itself is still created so as not to break the binding in BunObject.

pub fn create(globalThis: *jsc.JSGlobalObject) jsc.JSValue {
    const object = JSValue.createEmptyObject(globalThis, 4);
    object.put(
        globalThis,
        ZigString.static("html"),
        jsc.JSFunction.create(globalThis, "html", renderToHTML, 1, .{}),
    );
    object.put(
        globalThis,
        ZigString.static("ansi"),
        jsc.JSFunction.create(globalThis, "ansi", renderToAnsi, 2, .{}),
    );
    object.put(
        globalThis,
        ZigString.static("render"),
        jsc.JSFunction.create(globalThis, "render", render, 3, .{}),
    );
    object.put(
        globalThis,
        ZigString.static("react"),
        jsc.JSFunction.create(globalThis, "react", renderReact, 3, .{}),
    );
    return object;
}

fn unavailable(globalThis: *jsc.JSGlobalObject) bun.JSError!jsc.JSValue {
    return globalThis.throw("Bun.markdown is not available in the bzrt runtime.", .{});
}

pub fn renderToHTML(globalThis: *jsc.JSGlobalObject, _: *jsc.CallFrame) bun.JSError!jsc.JSValue {
    return unavailable(globalThis);
}

pub fn renderToAnsi(globalThis: *jsc.JSGlobalObject, _: *jsc.CallFrame) bun.JSError!jsc.JSValue {
    return unavailable(globalThis);
}

pub fn render(globalThis: *jsc.JSGlobalObject, _: *jsc.CallFrame) bun.JSError!jsc.JSValue {
    return unavailable(globalThis);
}

pub fn renderReact(globalThis: *jsc.JSGlobalObject, _: *jsc.CallFrame) bun.JSError!jsc.JSValue {
    return unavailable(globalThis);
}

const bun = @import("bun");

const jsc = bun.jsc;
const JSValue = jsc.JSValue;
const ZigString = jsc.ZigString;
