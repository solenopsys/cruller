// bzrt-cut: markdown-рендерер (`src/md/`) вырезан из рантайма (tz.md §1.1).
// Оставлен только JS-биндинг `Bun.markdown`, чьи методы бросают исключение —
// сам объект по-прежнему создаётся, чтобы не ломать привязку в BunObject.

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
