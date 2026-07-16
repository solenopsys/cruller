# Current Status

## Build

- `zig build --build-file build016.zig check` passes with Zig 0.16.
- `bun --silent run build:debug` builds and links `build/debug/bun-debug`.
- The minimal launcher supports a script path and the runner-compatible form
  `bun-debug run --config=<path> <entrypoint>`.

## Passing Runtime Checks

- CJS and ESM entrypoints load and execute.
- `scripts/runner.node.mjs` can use an explicit `build/debug/bun-debug` path.
- These Node JavaScript tests pass through that runner:
  - `js/node/test/parallel/test-path-basename.js`
  - `js/node/test/parallel/test-path-dirname.js`
  - `js/node/test/parallel/test-path-extname.js`
  - `js/node/test/parallel/test-path-join.js`

## Active Blocker: Built-in Fetch Corrupts Response Bodies

`Bun.serve` writes the correct response body on the wire: an external `curl`
gets `ok`. `new Response("ok").text()` also returns `ok`. The built-in
`fetch()` client instead reads the two-byte body as `0xff 0xff`, which decodes
to `\ufffd\ufffd` rather than `ok`.

Reproduction:

```sh
node scripts/runner.node.mjs --quiet --exec-path ./build/debug/bun-debug \
  js/node/test/parallel/test-bzrt-runtime-smoke.js
```

The regression test is `test/js/node/test/parallel/test-bzrt-runtime-smoke.js`.
The fault is limited to the internal HTTP client response-body path; inspect
`src/http/http.zig` (`handleResponseBody*`) and the conversion of the completed
client body into webcore `Response`. The test process subsequently trips LSAN
because the assertion aborts while the server/client objects are still alive;
do not treat that report as a separate leak conclusion until the body corruption
is fixed and the normal shutdown path runs.

## Scope

`bun:test`, package installation, full CLI parsing, and bundler commands remain
cut. Run applicable JavaScript files through `scripts/runner.node.mjs`; tests
requiring the removed `bun:test` command are not part of the current runtime
gate.
