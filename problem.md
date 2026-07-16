# Current Status

## Build

- `zig build --build-file build016.zig check` passes with Zig 0.16.
- `bun --silent run build:debug` builds and links `build/debug/bun-debug`.
- `RUSTUP_TOOLCHAIN=nightly bun --silent run build:release` builds the portable
  `build/release/bun` runtime. The nightly toolchain is needed by the retained
  `lolhtml` dependency, which uses Cargo's unstable `-Zbuild-std` support.
- The release invocation uses `-Doptimize=ReleaseFast`,
  `-Denable_asan=false`, `-Denable_logs=false`, and `-Dcodegen_embed=true`.
  Its final post-link binary is stripped and is 76,570,712 bytes (74 MiB).
- The minimal launcher supports a script path and the runner-compatible form
  `bun run --config=<path> <entrypoint>`.

## Passing Runtime Checks

- CJS and ESM entrypoints load and execute.
- `scripts/runner.node.mjs` can use an explicit runtime path.
- These Node JavaScript tests pass through the runner using
  `build/release/bun`:
  - `js/node/test/parallel/test-path-basename.js`
  - `js/node/test/parallel/test-path-dirname.js`
  - `js/node/test/parallel/test-path-extname.js`
  - `js/node/test/parallel/test-path-join.js`
  - `js/node/test/parallel/test-bzrt-runtime-smoke.js`

## Resolved: Built-in Fetch Response Body Corruption

`InternalState.reset()` reset and poisoned the completed response buffer before
the callback handed it to webcore. It now leaves callback-owned body storage
intact; the next request clears that buffer when it reuses the HTTP client.

The regression test starts `Bun.serve`, validates a `curl` response, then calls
built-in `fetch()` and verifies status, headers, and `"ok"` body text:

```sh
node scripts/runner.node.mjs --quiet --exec-path ./build/release/bun \
  js/node/test/parallel/test-bzrt-runtime-smoke.js
```

The regression test is `test/js/node/test/parallel/test-bzrt-runtime-smoke.js`.

## Scope

`bun:test`, package installation, full CLI parsing, and bundler commands remain
cut. Run applicable JavaScript files through `scripts/runner.node.mjs`; tests
requiring the removed `bun:test` command are not part of the current runtime
gate. Running the unfiltered `test:release` target would incorrectly include
the full upstream Bun suite, including tests for deliberately removed features.
