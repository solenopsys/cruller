# TODO — make V8/QuickJS real engines behind the RT boundary

Short summary of the current state and the actual front of work. Goal: run
converged `ui`/`ms` on the V8 engine, not only the SSR harness.

Execution strategy: `STRATEGY.md` (wrap JSC in a bare V8-style wrapper, grow
the host one command at a time, gate every step on all three engines).

## Core finding

The `Engine` interface is **not crooked — it is unfinished**. It abstracts VM
lifecycle only, while Bun's whole API surface bypasses it.

- Contract: `src/rt/contract.zig:224-230` — `load/run/poll/interrupt/destroy`.
- Effect channel: `contract.zig:74-105` already declares `resource_*`,
  `dns_resolve`, `timer_arm`, `http_*`, `server_*`. Good design, not finished.
- JSC adapter is **the whole runtime in a wrapper**, not a peer engine:
  `src/rt/jsc_engine.zig:58` -> `bun.bun_js.runSourceWithHook` ->
  `src/bun.js.zig:588` `Run.boot(...)`. It gets `Bun.serve`, `require`, `fetch`,
  `bun:ffi` for free because it *is* Bun.
- V8 adapter is a bare evaluator: `src/rt/v8_engine.zig:62` just calls
  `v8_rt_load`. `v8_rt.cc` installs **no** globals (`Bun`, `require`, `fetch`).
- Production binary is hardcoded to JSC: `src/rt/monolith.zig:76`
  `Runtime = RuntimeFor(.jsc)`. No `-Dengine` switch for the monolith.
- Runtime engine flag exists only in the harness:
  `src/rt/ssr_run.zig:388` (`.quickjs` / `.v8`).

So switching the implementation behind `Engine` swaps "full Bun runtime" for
"JS interpreter with an empty API". That is why `.v8` builds and dies on the
first `Bun.serve`.

## What is NOT the blocker

- Reading JS files / module loading. converged bundles one self-contained
  `server.js` (`core/containers/bundle.ts:195-202`, `target: "bun"`). The host
  reads it and hands the engine one source buffer; the engine never touches the
  filesystem (README:227-251, 305-307).
- The one real module case is `MODULE_PROXY`: the server fetches modules from
  the registry at runtime (`bundle.ts:8-14`). That is a **host** service
  (fetch + hand-off buffer), not engine work.

## What actually blocks V8/QuickJS today

Native APIs the server calls, none of which are behind the boundary:

- `Bun.serve` (incoming HTTP listener) — README:269 "host listener adapter not
  migrated".
- `bun:ffi` (cruller-transport, md4c) — JSC-only, README:222.
- `Bun.file` / `Bun.write` / `Bun.Glob` / `Bun.spawn` / `Bun.RedisClient` /
  `Bun.CryptoHasher` / `Bun.hash` — JSC-only bindings.
- `node:*` — JSC-only.

README already states this is roadmap, not shipped (`README.md:54-55`,
status table `README.md:269-271`; "not yet an SSR/server runtime" `:59-63`).

## Front of work (ordered, per the concept: host owns I/O, engine is I/O-free)

0. Inventory the calls the real `ui`/`ms` bundle makes (`rg` over the built
   `server.js`). Everything below is scoped by that list; `bun:ffi`, `spawn`,
   `node:*`, Valkey stay out until the inventory requires them.
1. Finish host operations: incoming HTTP `server_*` end-to-end; outbound fetch
   completion; file ops (already partial, `direct_host.zig:65-71`); timers;
   DNS. (`bun:ffi`, `spawn`, Valkey, `node:*` compat: later, only on demand —
   see Rough sizing.)
2. Move module resolution/`MODULE_PROXY` fetch behind host-provided buffers.
3. Add a per-engine **C wrapper** (same `new/free/load/call/has_fn` shape as
   V8/QuickJS, zero JS globals) plus **one shared engine-independent JS
   prelude** that installs `Bun.*`, `require`, `fetch`, `Bun.serve` and maps
   them onto the command channel. V8/QuickJS have neither today.
4. Add a bare `jsc_rt` wrapper next to the legacy `Run.boot` path (kept as
   `.jsc_full`), so JSC becomes a peer engine and the contract is actually
   exercised. Remove legacy once the monolith switches over.
5. Settle the target: the real V8 backend is `x86_64-gnu` only
   (`rt/v8/README.md:116`), converged containers are Alpine/musl. Either move
   the runtime image to glibc (`glib.Containerfile`) or build V8 for musl.

## Rough sizing

- Small: source-buffer hand-off, module read, compile-time engine switch.
- Medium: `Bun.serve` listener, file ops, timers, DNS.
- Large: `bun:ffi` (dlopen + symbol call + `JSCallback`), full `webcore`
  (fetch/streams/`Blob`/WebSocket), `node:*` compat, Valkey.

Minimum to boot converged `ui`/`ms` on V8 (per `STRATEGY.md` §3): step 0
inventory first, then binary envelope + in-memory `server_request` /
`server_response_end`, then step 1 listener + step 3 prelude for `Bun.serve`
and `Bun.file`. That is the smallest meaningful slice; `bun:ffi` (dlopen +
symbol call + `JSCallback`) and the rest broaden compatibility toward parity
with JSC only if the inventory requires them.

## Build targets (unchanged, still open)

Cruller must build all four server-side combos (`x64/aarch64` x `gnu/musl`).
Today only `x64-gnu` is the working release (`glib.Containerfile`); `x64-musl`
is built natively in Alpine (`musl.Containerfile`); `aarch64-*` still open.
Host builds still require system `clang` (`scripts/build/compile.ts`). See the
V8 wrapper notes for its `x86_64-gnu` limitation.