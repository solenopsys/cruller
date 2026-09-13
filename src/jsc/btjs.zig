//! bzrt: JSC stack debugging dumper removed (old std.debug/std.io.tty
//! APIs gone in 0.16). C export preserved — returns an empty trace.
pub export fn dumpBtjsTrace() [*:0]const u8 {
    return "";
}
