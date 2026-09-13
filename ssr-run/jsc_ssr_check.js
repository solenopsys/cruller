// JSC check: грузим тот же bundle.js и гоняем те же 4 вектора.
const src = await Bun.file(process.argv[2] ?? "/home/alexstorm/distrib/business/converged/core/native/wrappers/rt/ssr-preact/dist/bundle.js").text();
eval(src);
const vectors = [
  '{"method":"GET","path":"/","headers":[],"body":""}',
  '{"method":"GET","path":"/about","headers":[],"body":""}',
  '{"method":"GET","path":"/nope","headers":[],"body":""}',
  "{oops",
];
let failed = 0;
const checks = [
  (b) => b.includes('"status":200') && b.includes("<title>Home</title>") && b.includes("Rendered on /"),
  (b) => b.includes('"status":200') && b.includes("<title>About</title>") && b.includes("Rendered on /about"),
  (b) => b.includes('"status":200') && b.includes("<title>Home</title>") && b.includes("Rendered on /nope"),
  (b) => b.includes('"status":400') && b.includes("bad request"),
];
vectors.forEach((v, i) => {
  const out = globalThis.__crullerHandle(v);
  const ok = checks[i](out);
  if (!ok) failed++;
  console.log(`[jsc/${i + 1}] ok=${ok ? "yes" : "NO"} ${out.slice(0, 120)}...`);
});
if (failed) { console.error(`${failed} failed`); process.exit(1); }
console.log("jsc: 4 responses, 0 failed");
