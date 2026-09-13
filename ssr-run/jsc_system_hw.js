// Bare system JSC hw-throughput check (/usr/lib/webkitgtk-6.0/jsc): loads the
// minimal `hw` bundle and calls __crullerHandle REPEAT times, expecting the
// literal bytes `hw`. Wall time and memory are measured OUTSIDE (python
// resource.getrusage / /proc polling; see run_all_hw.sh).
var BUNDLE = "/home/alexstorm/distrib/business/converged/core/native/wrappers/rt/cruller/ssr-run/hw.js";
var REPEAT = 100000;

var src = readFile(BUNDLE);
eval(src);
var failed = 0;
var total = 0;
for (var r = 0; r < REPEAT; r++) {
  total++;
  if (globalThis.__crullerHandle("{}") !== "hw") {
    failed++;
    if (failed <= 3) print("MISMATCH at " + total);
  }
}
if (failed) { throw new Error(failed + " mismatches"); }
print("jsc-system-hw: " + total + " responses, 0 failed");
