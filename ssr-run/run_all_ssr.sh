#!/bin/bash
# Прогон ОДНОГО И ТОГО ЖЕ SSR-бандла на 3 движках + сравнение + peak RSS.
# ОДИН бинарь ssr-run, движок — рантайм-флаг --engine (не пересборка!).
# stdout бинаря -> out-<engine>.json (для cmp), диагностика -> stderr.
set -u
RT=/home/alexstorm/distrib/business/converged/core/native/wrappers/rt
CR=$RT/cruller
BUNDLE=${1:-$RT/ssr-preact/dist/bundle.js}
REPEAT=${2:-1}
BIN=$CR/zig-out/bin/ssr-run
JSC_CHECK=$CR/ssr-run/jsc_ssr_check.js

[ -x "$BIN" ] || { echo "собери сначала: (cd $CR && zig build ssr-install)"; exit 1; }

echo "=== bundle: $BUNDLE ($(wc -c < "$BUNDLE") bytes), repeat: $REPEAT ==="

echo "--- quickjs ---"
"$BIN" --engine quickjs --bundle "$BUNDLE" --repeat "$REPEAT" --json > /tmp/out-qjs.json 2>/tmp/qjs.log
tail -n 1 /tmp/qjs.log

echo "--- v8 ---"
"$BIN" --engine v8 --bundle "$BUNDLE" --repeat "$REPEAT" --json > /tmp/out-v8.json 2>/tmp/v8.log
tail -n 1 /tmp/v8.log

echo "--- jsc (bun, тот же бандл) ---"
bun "$JSC_CHECK" "$BUNDLE" 2>&1 | tail -n 2

echo "--- diff quickjs vs v8 (responses) ---"
if cmp -s /tmp/out-qjs.json /tmp/out-v8.json; then
  echo "IDENTICAL responses"
else
  echo "DIFFER:"; diff /tmp/out-qjs.json /tmp/out-v8.json | head -n 10
fi
