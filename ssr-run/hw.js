// Minimal engine-neutral handler: answer literally `hw` to every request.
// Used to measure the pure dispatch + call round-trip ceiling (no SSR, no
// JSON envelope, no compute) for each engine. Must stay ES5-parseable so the
// same file loads in bare system JavaScriptCore.
globalThis.__crullerHandle = function () {
  return "hw";
};
