// Bare system JSC check (/usr/lib/webkitgtk-6.0/jsc): чистый движок,
// только ES5-синтаксис (шелл старый, `const`/стрелки ок, но никаких
// Bun/process/await — файл парсится целиком до выполнения).
// repeat захардкожен; wall time и память меряем СНАРУЖИ:
//   /usr/bin/time -v /usr/lib/webkitgtk-6.0/jsc jsc_system_check.js
// Ответы сверяются строго (включая /calc checksum) — mismatch = throw.
var BUNDLE = "/home/alexstorm/distrib/business/converged/core/native/wrappers/rt/ssr-preact/dist/bundle.js";
var REPEAT = 2000; // 10000 запросов

var VECTORS = [
  '{"method":"GET","path":"/","headers":[],"body":""}',
  '{"method":"GET","path":"/about","headers":[],"body":""}',
  '{"method":"GET","path":"/nope","headers":[],"body":""}',
  "{oops",
  '{"method":"GET","path":"/calc","headers":[],"body":""}'
];

function check(i, b) {
  var has = function (n) { return b.indexOf(n) !== -1; };
  if (i === 0) return has('"status":200') && has("<title>Home</title>") && has("Rendered on /");
  if (i === 1) return has('"status":200') && has("<title>About</title>") && has("Rendered on /about");
  if (i === 2) return has('"status":200') && has("<title>Home</title>") && has("Rendered on /nope");
  if (i === 3) return has('"status":400') && has("bad request");
  return has('"status":200') && has('\\"result\\":502474356') && has('\\"iterations\\":100000');
}

var src = readFile(BUNDLE);
eval(src);
var failed = 0;
var total = 0;
for (var r = 0; r < REPEAT; r++) {
  for (var i = 0; i < VECTORS.length; i++) {
    var out = globalThis.__crullerHandle(VECTORS[i]);
    total++;
    if (!check(i, out)) {
      failed++;
      print("MISMATCH vec=" + i + " out=" + out.slice(0, 200));
    } else if (total <= 5) {
      print("[jsc-system/" + total + "] ok=yes status=" + JSON.parse(out).status);
    }
  }
}
if (failed) { throw new Error(failed + " mismatches"); }
print("jsc-system: " + total + " responses, 0 failed");
