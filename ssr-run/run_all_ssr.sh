#!/bin/bash
# Run the SAME SSR bundle on 3 engines + compare + summary table.
# ONE ssr-run binary, engine is a runtime flag --engine (no rebuild!).
# 5 vectors: /, /about, /nope, bad-json, /calc (deterministic CPU).
# Binary stdout -> out-<engine>.json (for cmp), diagnostics -> stderr.
# Usage: run_all_ssr.sh [bundle.js] [repeat]
set -u
RT=/home/alexstorm/distrib/business/converged/core/native/wrappers/rt
CR=$RT/cruller
BUNDLE=${1:-$RT/ssr-preact/dist/bundle.js}
REPEAT=${2:-1}
BIN=$CR/zig-out/bin/ssr-run
JSC_CHECK=$CR/ssr-run/jsc_ssr_check.js

[ -x "$BIN" ] || { echo "build first: (cd $CR && zig build ssr-install)"; exit 1; }

echo "=== bundle: $BUNDLE ($(wc -c < "$BUNDLE") bytes), repeat: $REPEAT (vectors: 5, total: $((5 * REPEAT))) ==="

run_engine() {
  local engine=$1 out=$2 log=$3
  "$BIN" --engine "$engine" --bundle "$BUNDLE" --repeat "$REPEAT" --json > "$out" 2>"$log"
  grep -h "BENCH" "$log"
}

echo "--- quickjs ---"
run_engine quickjs /tmp/out-qjs.json /tmp/qjs.log
echo "--- v8 ---"
run_engine v8 /tmp/out-v8.json /tmp/v8.log
echo "--- jsc via cruller runner (bun host) ---"
bun "$JSC_CHECK" "$BUNDLE" "$REPEAT" --json > /tmp/out-jsc.json 2>/tmp/jsc.log
grep -h "BENCH" /tmp/jsc.log

echo "--- jsc bare system (/usr/lib/webkitgtk-6.0/jsc, no bun) ---"
echo "(timing/RSS via external poll; see README benchmark section)"

echo "--- diff quickjs vs v8 (responses) ---"
if cmp -s /tmp/out-qjs.json /tmp/out-v8.json; then
  echo "IDENTICAL responses (quickjs==v8)"
else
  echo "DIFFER:"; diff /tmp/out-qjs.json /tmp/out-v8.json | head -n 10
fi
echo "--- diff quickjs vs jsc (responses only) ---"
# Normalization: jsc_json has the same shape [{request_id,ok,response}], but
# key order inside response is not guaranteed — compare via python by fields.
python3 - <<'EOF'
import json
ok = True
for name in ("qjs", "v8", "jsc"):
    try:
        d = json.load(open(f"/tmp/out-{name}.json"))
    except Exception as e:
        print(f"{name}: UNPARSEABLE ({e})"); ok = False; continue
    bad = [r for r in d if not r.get("ok")]
    print(f"{name}: {len(d)} responses, failed={len(bad)}")
    if bad: ok = False
if not ok: raise SystemExit(1)
q = json.load(open("/tmp/out-qjs.json"))
v = json.load(open("/tmp/out-v8.json"))
j = json.load(open("/tmp/out-jsc.json"))
def norm(rows):
    return [json.dumps(r["response"], sort_keys=True) for r in rows]
print("qjs==v8:", norm(q) == norm(v))
print("qjs==jsc:", norm(q) == norm(j))
EOF
