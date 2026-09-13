// JSC check: грузим тот же bundle.js и гоняем те же вектора, что ssr_run.zig.
// ДВА ФАЙЛА (один файл на два шелла невозможен: system-jsc падает на парсе
// слов `Bun`/`await` даже внутри мертвых веток):
//  1. jsc_ssr_check.js (этот): cruller-режим через bun-раннер.
//     Использование: bun jsc_ssr_check.js <bundle> [repeat] [--json]
//     Формат JSON-выхода — та же форма, что у zig-бинаря (--json) + BENCH.
//  2. jsc_system_check.js: bare /usr/lib/webkitgtk-6.0/jsc, чистый движок.
//     Нет argv/readFile-async/Date-timing не нужен: repeat захардкожен,
//     меряем снаружи (/usr/bin/time -v: wall + Maximum resident).
//     Использование: /usr/lib/webkitgtk-6.0/jsc jsc_system_check.js
const BUNDLE_PATH = "/home/alexstorm/distrib/business/converged/core/native/wrappers/rt/ssr-preact/dist/bundle.js";

const baseVectors = [
  '{"method":"GET","path":"/","headers":[],"body":""}',
  '{"method":"GET","path":"/about","headers":[],"body":""}',
  '{"method":"GET","path":"/nope","headers":[],"body":""}',
  "{oops",
  '{"method":"GET","path":"/calc","headers":[],"body":""}',
];
const checks = [
  (b) => b.includes('"status":200') && b.includes("<title>Home</title>") && b.includes("Rendered on /"),
  (b) => b.includes('"status":200') && b.includes("<title>About</title>") && b.includes("Rendered on /about"),
  (b) => b.includes('"status":200') && b.includes("<title>Home</title>") && b.includes("Rendered on /nope"),
  (b) => b.includes('"status":400') && b.includes("bad request"),
  (b) => b.includes('"status":200') && b.includes('\\"result\\":502474356') && b.includes('\\"iterations\\":100000'),
];

function drive(handle, total, collectJson) {
  let failed = 0;
  const lines = [];
  for (let r = 0; r < total; r++) {
    for (let i = 0; i < baseVectors.length; i++) {
      const id = r * baseVectors.length + i + 1;
      const out = handle(baseVectors[i]);
      const ok = checks[i](out);
      if (!ok) failed++;
      if (collectJson) {
        lines.push(`  {"request_id":${id},"ok":${ok},"response":${out}}`);
      } else if (id <= 5 || !ok) {
        print(`[jsc/${id}] ok=${ok ? "yes" : "NO"} status=${JSON.parse(out).status}`);
      }
    }
  }
  return { failed, lines };
}

if (typeof readFile === "function" && typeof print === "function" && typeof Bun === "undefined") {
  // --- safety: запустили bun-файл под bare jsc — сказать прямо ---
  print("use jsc_system_check.js for bare system jsc");
  throw new Error("wrong runner");
} else {
  // --- cruller JSC через bun-раннер ---
  var bundlePath = BUNDLE_PATH;
  var repeat = 1;
  var jsonOut = false;
  if (typeof process === "undefined" || typeof process.argv === "undefined") throw new Error("need bun runner");
  var proc = process;
  if (proc.argv[2]) bundlePath = proc.argv[2];
  repeat = parseInt(proc.argv[3] || "1", 10) || 1;
  jsonOut = proc.argv.includes("--json");
  var src = await Bun.file(bundlePath).text();
  eval(src);
  const started = performance.now();
  let failed = 0;
  let responses = 0;
  const rssBeforeKb = Math.round(process.memoryUsage().rss / 1024);
  const lines = [];
  for (let r = 0; r < repeat; r++) {
    for (let i = 0; i < baseVectors.length; i++) {
      const id = r * baseVectors.length + i + 1;
      const out = globalThis.__crullerHandle(baseVectors[i]);
      const ok = checks[i](out);
      if (!ok) failed++;
      responses++;
      if (jsonOut) {
        lines.push(`  {"request_id":${id},"ok":${ok},"response":${out}}`);
      } else if (id <= 5 || !ok) {
        console.log(`[jsc/${id}] ok=${ok ? "yes" : "NO"} status=${JSON.parse(out).status}`);
      }
    }
  }
  if (jsonOut) console.log("[\n" + lines.join(",\n") + "\n]");
  const elapsedMs = performance.now() - started;
  const rssKb = Math.round(process.memoryUsage().rss / 1024);
  const rps = responses / (elapsedMs / 1000);
  if (failed) { console.error(`${failed} failed`); process.exit(1); }
  console.error(`jsc: ${responses} responses, ${failed} failed, peak RSS ~${rssKb} kB (before ${rssBeforeKb} kB)`);
  console.error(`BENCH engine=jsc responses=${responses} failed=${failed} elapsed_ms=${elapsedMs.toFixed(1)} rps=${rps.toFixed(0)} peak_rss_kb=${rssKb}`);
}
