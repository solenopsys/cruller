# STRATEGY — wrap JSC, grow the host, gate on three engines

## 0. Principle: the engine is not modified

The engine does exactly three things:

1. executes code (load a source buffer → run),
2. receives data (commands + `BufferRef` bytes),
3. issues command calls (submit with a `request_id` → wait for completion).

The engine knows **nothing** about files, networks, sockets, TLS, processes,
or Valkey. No `Bun.*`, no webcore facades, no JSDOM classes inside the engine.
Promises never cross the boundary — only the command and its completion cross;
a promise resolves locally inside the engine's own microtask queue.

Cost model: overhead = (number of I/O operations per request) × (a few µs per
submit/completion). Pure compute costs zero hops.

The JS shim (`fetch`, `Bun.serve`, … mapped onto submit/completion) is **not
part of the engine**. It is ordinary engine-independent JS (a prelude to the
bundle or part of the bundle): written once in JS, it runs on all three
engines with no per-engine C++.

## 1. JSC wrapper shaped like V8/QuickJS

V8 and QuickJS are already isolated: a sibling shim with a tiny C ABI
(`new/free/load/call/has_fn/set_timeout`), a Zig adapter built only on
`contract + *_api + vm_bridge + server_dispatch` with no `@import("bun")`,
and a shim that installs zero JS globals. JSC gets the same wrapper: a bare
`VM + GlobalObject + eval + call + drainMicrotasks`, without `Run.boot`, the
module resolver, or native bindings. `jsc_engine.zig` is rewritten 1-to-1
after `v8_engine.zig`.

The old `Run.boot` path stays as legacy (`.jsc_full` in the engine selector)
until the monolith switches over; the new path is a peer engine (`.jsc_rt`).
CI boundary rule: no `@import("bun")` in `src/rt/*_engine.zig`.

## 2. The host grows, the engine does not

All meaning lives on the host: commands (`server_listen`, `http_request_*`,
`resource_*`, `timer_arm`, `dns_resolve`, …), envelopes (`http_wire.zig`),
listeners, sockets, files. Each command is one closed diff: an operation in
`contract.zig`, an implementation in `direct_host.zig`/`host_http.zig`
(importing from `bun` only the minimum that command needs), plus a test.
Step 0 is an inventory of the calls the real `ui`/`ms` bundle makes (`rg` over
the built `server.js`); anything the bundle does not call (`ffi`, `spawn`,
Valkey, most of `node:*`) stays out of scope until proven necessary.

## 3. Three-engine gate, inherited from the SSR harness

A new command is accepted only when one workload runs byte-for-byte
identically on the JSC wrapper, V8, and QuickJS — same vectors, `cmp`-clean
responses, wall/RSS table, as `ssr-run/run_all_ssr.sh` already does. Order:

- v0: `load/call` on all three engines;
- v1: binary envelope + in-memory `server_request`/`server_response_end`
  (no sockets);
- v2: host listener `server_listen` end-to-end;
- v3: files, timers, DNS;
- then the rest per the bundle inventory (`bun:ffi` with `JSCallback`,
  `spawn`, `node:*`, Valkey — later, only on demand).

## 4. Rings, threads, uring — later, by ROI

1. SPSC rings + waker instead of mutex queues + poll sleep (cuts p99 and idle
   CPU, adds backpressure). The contract does not change: `Command` stays a
   64-byte POD, `BufferRef` stays generation-checked.
2. Parallelism for free: engines are share-nothing (one thread, VM, heap, and
   allocator each; the bridge is already `threadlocal`), so scaling out means
   adding ring pairs plus a routing entry. The controller balances only new
   requests (sticky, no migration); heterogeneous engines (e.g. V8 for SSR,
   QuickJS for hooks) are possible without touching engine code.
3. io_uring data path last, driven by file-heavy measurements.

Acceptance: a hung engine must not hang the host, `request_id` cancellation
must work, overload must produce backpressure — not RSS growth.

## 5. Performance frame

Target: parity with Bun ±10% on typical SSR (render + a fetch + static),
because dispatch is noise next to JS execution (see `README.md`
Measurements). The win is in tails and liveness: an independent host loop
(the monolith shares one loop between JS and I/O), per-operation
cancellation instead of VM termination, and uncorrelated per-instance GC
pauses.
