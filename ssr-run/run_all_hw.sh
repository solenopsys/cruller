#!/bin/bash
# hw-throughput run: one minimal handler (`return "hw"`), no SSR, no JSON
# envelope, no compute. Measures the pure dispatch + call round-trip ceiling
# on the same binary/bundle for QuickJS, V8 (via ssr-run) and bare system
# JavaScriptCore (via /usr/lib/webkitgtk-6.0/jsc).
# Usage: run_all_hw.sh [repeat]   (default 100000 requests)
set -u
RT=/home/alexstorm/distrib/business/converged/core/native/wrappers/rt
CR=$RT/cruller
REPEAT=${1:-100000}
BIN=$CR/zig-out/bin/ssr-run
HW=$CR/ssr-run/hw.js
JSC=/usr/lib/webkitgtk-6.0/jsc

[ -x "$BIN" ] || { echo "build first: (cd $CR && zig build ssr-install)"; exit 1; }

echo "=== hw workload: __crullerHandle returns literal 'hw' (total=$REPEAT requests) ==="

run_engine() {
  local engine=$1
  "$BIN" --engine "$engine" --workload hw --bundle "$HW" --repeat "$REPEAT" 2>&1 | grep BENCH
}

echo "--- quickjs ---"
run_engine quickjs
echo "--- v8 ---"
run_engine v8
echo "--- jsc bare system (no bun; NOTE: direct JS call, JIT folds the empty handler — number is not comparable to the shared bridge) ---"
python3 - "$REPEAT" "$JSC" "$CR/ssr-run/jsc_system_hw.js" <<'PY'
import subprocess, sys, time, resource
repeat = int(sys.argv[1]); jsc = sys.argv[2]; tpl = sys.argv[3]
src = open(tpl).read().replace("var REPEAT = 100000;", "var REPEAT = %d;" % repeat)
open("/tmp/jsc_system_hw_run.js", "w").write(src)
t0 = time.monotonic()
p = subprocess.run([jsc, "/tmp/jsc_system_hw_run.js"], capture_output=True, text=True)
dt = time.monotonic() - t0
rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
if p.returncode != 0:
    sys.stderr.write(p.stdout[-300:] + p.stderr[-300:] + "\n")
failed = 0 if p.returncode == 0 else 1
print("BENCH engine=jsc responses=%d failed=%d elapsed_ms=%.1f rps=%.0f peak_rss_kb=%d"
      % (repeat, failed, dt * 1000, repeat / dt, rss))
PY
