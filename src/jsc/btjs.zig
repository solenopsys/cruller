//! bzrt: отладочный дампер JSC-стеков вырезан (старые std.debug/std.io.tty
//! API ушли в 0.16). C-экспорт сохранён — возвращает пустой трейс.
pub export fn dumpBtjsTrace() [*:0]const u8 {
    return "";
}
