// JSC check: грузим тот же bundle.js и гоняем те же вектора, что ssr_run.zig.
// Формат JSON-выхода — та же форма, что у zig-бинаря (--json):
//   [{"request_id","ok","response":{...}}, ...]
// + сводная BENCH-строка той же формы в stderr.
// Использование: bun jsc_ssr_check.js <bundle.js> [repeat] [--json]
const bundlePath = process.argv[2] ?? "/home/alexstorm/distrib/business/converged/core/native/wrappers/rt/ssr-preact/dist/bundle.js";
const repeat = parseInt(process.argv[3] ?? "1", 10) || 1;
const jsonOut = process.argv.includes("--json");
const src = await Bun.file(bundlePath).text();
eval(src);
const baseVectors = [
  '{"method":"GET","path":"/","headers":[],"body":""}',
  '{"method":"GET","path":"/about","headers":[],"body":""}',
  '{"method":"GET","path":"/nope","headers":[],"body":""}',
  "{oops",
  '{"method":"GET","path":"/calc","headers":[],"body":""}',
];
const vectors = [];
for (let r = 0; r < repeat; r++) vectors.push(...baseVectors);
const checks = [
  (b) => b.includes('"status":200') && b.includes("<title>Home</title>") && b.includes("Rendered on /"),
  (b) => b.includes('"status":200') && b.includes("<title>About</title>") && b.includes("Rendered on /about"),
  (b) => b.includes('"status":200') && b.includes("<title>Home</title>") && b.includes("Rendered on /nope"),
  (b) => b.includes('"status":400') && b.includes("bad request"),
  (b) => b.includes('"status":200') && b.includes('\\"result\\":502474356') && b.includes('\\"iterations\\":100000'),
];
const started = performance.now();
let failed = 0;
let responses = 0;
const used = process.memoryUsage();
const rssBeforeKb = Math.round(used.rss / 1024);
const lines = [];
vectors.forEach((v, i) => {
  const out = globalThis.__crullerHandle(v);
  const ok = checks[i % baseVectors.length](out);
  if (!ok) failed++;
  responses++;
  const body = JSON.parse(out);
  if (jsonOut) {
    lines.push(`  {"request_id":${i + 1},"ok":${ok},"response":${out}}`);
  } else if (responses <= 5 || !ok) {
    console.log(`[jsc/${i + 1}] ok=${ok ? "yes" : "NO"} status=${body.status}`);
  }
});
if (jsonOut) console.log("[\n" + lines.join(",\n") + "\n]");
const elapsedMs = performance.now() - started;
const usedAfter = process.memoryUsage();
const rssKb = Math.round(usedAfter.rss / 1024);
const rps = responses / (elapsedMs / 1000);
if (failed) { console.error(`${failed} failed`); process.exit(1); }
console.error(`jsc: ${responses} responses, ${failed} failed, peak RSS ~${rssKb} kB (before ${rssBeforeKb} kB)`);
console.error(`BENCH engine=jsc responses=${responses} failed=${failed} elapsed_ms=${elapsedMs.toFixed(1)} rps=${rps.toFixed(0)} peak_rss_kb=${rssKb}`);
