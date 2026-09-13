<p align="center">
  <img src="./cruller.png" alt="Cruller logo" height="170">
</p>
<h1 align="center">Cruller</h1>

<p align="center">
A fork of <a href="https://github.com/oven-sh/bun">Bun</a> from its last Zig release (1.3.14), ported to Zig 0.16 and cut down to a runtime only.
</p>

## What is Cruller?

Bun stopped shipping a Zig-based runtime after 1.3.14 — the project moved on to a Rust rewrite. Cruller forks
that last Zig-era Bun and ports it forward to Zig 0.16 instead of following Bun into its rewrite.

It is **not** a general-purpose JavaScript toolkit, and it is **not** trying to be Bun. The goal is narrow:
keep the engine — the part that actually runs a server — and throw out everything that isn't needed in
production. No package manager, no CLI, no shell, no bundler/transpiler, no test runner. What's left is the
part of Bun that runs an already-built server: the HTTP(S) stack (HTTP/1, HTTP/2, HTTP/3), static file
serving, SSR (`react-dom/server` over `Bun.serve`), WebSockets, and the `webcore` primitives
(`fetch`, streams, `Blob`, `Request`/`Response`) needed to implement them.

JavaScriptCore (`bun-webkit`) is kept as-is — it's a vendored, pre-built dependency consumed through its C
API, untouched by the Zig version bump.

## Production Model

Cruller is designed to complement Bun, not compete with it. Development stays
on the complete Bun toolchain: installing dependencies, transpiling TypeScript,
bundling, testing, and iterating on an application. That toolchain produces a
JavaScript entrypoint and assets. Production then runs those prepared artifacts
on Cruller, whose responsibility is deliberately limited to executing and
serving them.

This split keeps the maintenance target realistic. Rather than trying to own a
large general-purpose developer platform, Cruller concentrates its compatibility
and engineering effort on the production path: predictable server behavior,
networking, resource control, and embeddability.

## Roadmap

1. Complete one incoming HTTP/SSR vertical slice through the engine-neutral
   command/data boundary for both JSC and QuickJS.
2. Move the remaining native services behind host commands, starting with
   module loading and then WebSockets, file-backed Blob operations, and Valkey.
3. Replace the direct in-process transports with bounded command rings and
   shared or io_uring-registered data buffers.
4. Build the I/O-free engine side as a dynamic RT library only after direct I/O
   dependencies have been removed and guarded in CI.
5. Add V8 only if the completed interface can be implemented without copying
   host functionality into the engine adapter.
6. Measure per-runtime RSS, throughput, tail latency, and leaks on identical
   workloads.

These are roadmap items, not claims of currently shipped functionality.

Execution strategy (wrap JSC in a bare wrapper, grow the host one command at
a time, gate every step on all three engines): `STRATEGY.md`. Remaining
engine work: `TODO.md`.

## Status

The existing JSC `ReleaseFast` monolith is in production and can execute and
serve prepared application artifacts. The new engine-neutral boundary is an
active migration inside that monolith. QuickJS proves that the minimal engine
interface can execute source buffers, but it is not yet an SSR/server runtime.
Engine selection is currently a compile-time choice, not a command-line or
runtime parameter. Boundary capability detail: `TODO.md`; planned next
milestone: `STRATEGY.md` §3.

## Measurements

Compared with the official Bun 1.3.14 Linux x64 release, the stripped
`ReleaseFast` Cruller runtime is 76,570,712 bytes (73.0 MiB), down 17.4%
(about 18%) from Bun's 92,752,752-byte (88.5 MiB) binary. The reduction comes
from removing the production-unneeded subsystems listed below while retaining
JavaScriptCore, HTTP, webcore, and their required native dependencies.

The V8 Benchmark Suite Crypto workload (pure JavaScript RSA) was run five times
against each runtime on the same host. Cruller's median score was 72,759 versus
71,319 for Bun, about 2% higher. The run-to-run variation was larger than that
difference, so this establishes JS-engine performance parity rather than a
reliable 2% speedup. JavaScriptCore itself is retained, so this result is
expected; HTTP throughput and tail latency require separate benchmarks.

### Three-engine SSR + compute benchmark

One Preact SSR bundle (`../ssr-preact/dist/bundle.js`, 18,373 bytes: SSR pages
`/` `/about` + deterministic CPU endpoint `/calc`) runs unmodified on all
three engines through the same `__crullerHandle` convention:

- `zig build ssr-install` → one `zig-out/bin/ssr-run` binary;
  engine is a runtime flag, not a rebuild:
  `ssr-run --engine quickjs|v8 --bundle <bundle.js>`;
- JSC runs the same bundle two ways:
  - via the cruller JSC engine through a bun-hosted runner
    (`bun ssr-run/jsc_ssr_check.js` — bun here is only an external host
    process providing a JSC engine for the check script, not a cruller
    dependency or artifact);
  - via bare system JavaScriptCore (`/usr/lib/webkitgtk-6.0/jsc
    ssr-run/jsc_system_check.js`, no bun/bun-libs involved at all) —
    this is the honest JSC number;
- `ssr-run/run_all_ssr.sh [bundle] [repeat]` drives all three, compares
  responses byte-for-byte, and prints a `BENCH engine=...` summary per engine;
- `ssr-run/run_all_hw.sh [repeat]` runs the minimal `hw` workload
  (`--workload hw --bundle ssr-run/hw.js`) on QuickJS/V8 + bare system JSC.

Workload (SSR): 5 vectors per round (`/`, `/about`, `/nope` → SSR HTML;
bad-JSON → 400; `/calc` → 100k-iteration integer hash chain with an exact
expected checksum `result=502474356`, so engine divergence is a mismatch,
not noise). One process = one engine; metric is wall time for `engine.run()`
over all N requests + process peak RSS (`getrusage RU_MAXRSS`). The harness
itself is O(1) in memory regardless of N: a virtual `to_engine` producer
synthesizes each request on demand (no pre-queued backlog) and a `to_host`
sink validates and releases each response inline (no accumulated responses),
so peak RSS reflects the engine, not the harness buffers.

Measured on the dev host (x86_64 Linux, 100,000 requests = 20,000 rounds × 5
vectors, zero mismatches on all engines, stable across reruns):

| Engine | 100k req wall time | Throughput | Peak RSS | How measured |
| --- | --- | --- | --- | --- |
| QuickJS | ~148 s | ~677 req/s | ~7.5 MB | `ssr-run --engine quickjs` + `libqjs.so`, `getrusage RU_MAXRSS` |
| V8 15.0 (prebuilt monolith) | ~2.94 s | ~34,000 req/s | ~36.6 MB | `ssr-run --engine v8` static (~48 MB on disk, monolith inside), `getrusage RU_MAXRSS` |
| JavaScriptCore (bare system `jsc`) | ~3.79 s | ~26,400 req/s | ~164 MB | `/usr/lib/webkitgtk-6.0/jsc ssr-run/jsc_system_check.js` (REPEAT=20000), external `/proc` VmRSS poll; no bun anywhere in this path |

At 10,000 requests the ordering is identical (QuickJS ~15.0 s / ~666 req/s /
~7.6 MB; V8 ~0.30 s / ~33,500 req/s / ~34.6 MB; bare JSC ~0.40 s /
~24,400 req/s / ~92 MB); at 1,000 requests all three are JIT-warmup-dominated,
more so V8 and JSC (QuickJS ~1.5 s / ~7.5 MB; V8 ~42 ms / ~32.2 MB). QuickJS
RSS is flat from 1k to 100k (~7.5 MB), V8 from ~32 to ~37 MB — the earlier
N-linear growth was the old queueing harness, not the engines.

Reading guide: QuickJS is ~51× slower than V8 and ~40× slower than JSC on
this mixed SSR+integer-hash workload — expected for an interpreter vs JITs.
On memory, QuickJS stays flat at ~7.5 MB across 1k–100k requests; V8 pays
~4.9× that (~36.6 MB: isolate + prebuilt monolith) and bare system JSC ~22×
(its process carries ICU + full WebKit runtime, ~164 MB VmHWM at 100k — that
is the engine's own cost, measured without any bun). The responses from all
three engines are byte-for-byte identical (`cmp` clean on every run),
including the `/calc` checksum.

## hw workload: pure dispatch ceiling

`ssr-run --workload hw --bundle ssr-run/hw.js` sends 100,000 requests whose
handler is literally `globalThis.__crullerHandle = () => "hw"` — no SSR, no
JSON envelope, no compute. It isolates the per-request cost of the shared
C-ABI path (on-demand request → pool buffer → engine call → inline response
release), so it is the complement to the compute-heavy SSR table:

| Engine | 100k req wall time | Throughput | Peak RSS |
| --- | --- | --- | --- |
| QuickJS | ~35 ms (34–41) | ~2.89 M req/s | ~7.1 MB |
| V8 15.0 | ~47 ms (42–47) | ~2.11 M req/s | ~27.1 MB |

QuickJS wins the empty-call path by ~20%: V8's per-call machinery
(isolate/HandleScope/TryCatch/context scope plus the persistent-handle
cache) costs more than QuickJS's interpreter call. That is the opposite of
the compute-heavy SSR result, which is exactly why both numbers are here.
Both engines go through the same `ssr-run` binary and pool, so this
comparison is apples-to-apples.

Bare system JSC is **not** comparable on `hw`: the JSC runners call
`__crullerHandle` directly from a JS loop (there is no cruller C-ABI bridge
for JSC yet), and JSC constant-folds the empty handler, so its ~9.6 M req/s
is loop/dead-code elimination, not dispatch. Its SSR rows above are still
valid because the `/calc` result cannot be folded away.

Harness note: `ssr_run.zig`'s `Pool` used to rescan all live slots on every
`allocate`; at 100k requests that O(n²) dominated the hw workload (a ~10×
per-request inflation). It now keeps a free-list, so 100k requests run in
tens of milliseconds.

`/calc` and the V8/JSC inliner trade-off: the vector is a 100k-iteration
integer hash chain, and the two JITs prefer *opposite* code shapes for it.
When the loop lives in a separate helper reached through the SSR dispatch
chain, V8 refuses to inline it, leaves it as an OSR function, and repeatedly
deopts on the post-loop `>>> 0` (`Insufficient type feedback for binary
operation`, 92/94 bailouts at that bytecode); this costs V8 ~4.5× and
reproduces **identically in plain Node 26.8.1 with no cruller code in the
process** — it is V8's inliner/tiering behavior, not our embedder and not a
`v8_rt_call` feedback reset (an earlier note here blamed the shim; that was
wrong). JSC is the mirror image: it prefers the separate helper
(~140 µs/call) over an inlined loop (~172 µs/call). The bundle therefore
keeps the loop **inlined into the handler** (`ssr-preact/src/app.jsx`,
commented): V8 ~130 µs/call, JSC ~172 µs/call, same checksum on every
engine. That shape decides the ordering of the V8 and JSC rows above; the
route not taken (separate helper) would put JSC ahead at 10k requests
(~29,200 vs ~8,700 req/s). Both are honest numbers, but only one can be the
headline, and the inline shape is the one where V8 is not penalized by an
inlining quirk.

The persistent-handle cache added to `v8_rt.cc` (`v8::Persistent<v8::Function>`
keyed by name, reset on `load`/`free`) removes the per-call `lookupGlobal`
and name-string allocation; it is verifiably correct (real-backend tests plus
a reload-redefinition test) but does not move throughput — the lookup was
never the bottleneck on this workload.

Caveats: single-threaded in-process dispatch (no HTTP server, no network);
`--repeat` reuses one isolate/context (steady-state, not cold start);
QuickJS runs with its 16 MiB heap / 512 KiB stack / 100 ms budget, V8/JSC
with defaults; the JSC column is bare system JavaScriptCore
(`/usr/lib/webkitgtk-6.0/jsc`, present on any WebKitGTK host) — no bun
binary, no bun libraries, no cruller dependency. The `bun
ssr-run/jsc_ssr_check.js` path exists only as a convenience runner reusing
the same file layout; its numbers are not quoted here.
Tail latency, cold start, and leak behavior are not measured yet (roadmap
items 6 and 10).

## What was cut

- Package manager (`bun install`, lockfile, npm registry client, lifecycle scripts)
- CLI and subcommand dispatch (`bunx`, `bun test`, `bun build`, `bun run <script>`, argv parsing)
- `$ Shell` (the bash-like builtin shell interpreter)
- Bundler / transpiler (`js_parser`, `js_printer`, `bundle_v2`, CSS parser, standalone executables /
  `StandaloneModuleGraph`)
- Test runner (`bun test` itself — this does not affect Zig's own `zig build test`)
- SQL clients (Postgres/MySQL), `napi`, patch-package, archive (tar) support, Markdown/YAML/JSON5/Archive
  runtime objects, full Node `fs` compatibility surface

## What's kept

- HTTP/1, HTTP/2, HTTP/3 server (`http/`, `http_jsc/`, `uws_sys/`)
- Static file serving and React SSR primitives (without Bake/dev-server/HMR)
- `webcore` (`fetch`, streams, `Blob`, `Request`/`Response`, WebSockets)
- Module resolver (for loading pre-built JS — no on-the-fly transpilation)
- Valkey/Redis client (`valkey_jsc/`)
- `bun:ffi` for project-owned Zig/C ABI libraries, including `JSCallback`
- JavaScriptCore bindings (`jsc/`)
- Foundation: `sys`, `collections`, `bun_core`, `string`, `unicode`, `io`, `bun_alloc`, `ptr`, `threading`,
  `crash_handler`, `errno`, `logger`, `router`, `watcher`, `boringssl_sys` (TLS)

## Runtime Boundary: Phase One

The production executable is still a monolith, but its entrypoint now crosses
a transport-neutral runtime boundary under `src/rt`:

- `CommandTransport` carries fixed-size lifecycle and control messages.
- `DataTransport` owns bulk bytes and exposes only generation-checked
  `BufferRef` descriptors to commands and engines.
- `Engine` exposes only load, run, poll, interrupt, and destroy operations. Load
  receives source and diagnostic-name buffers, never a path; JSC, QuickJS, or
  any future engine cannot open the entrypoint itself. JSC types do not cross
  this interface.
- The current direct adapters use in-process queues and heap buffers. Replacing
  them with command rings and shared or io_uring-registered buffers does not
  change the engine contract.
- Outbound `fetch` requests, including streamed request and response bodies,
  cross the same command/data boundary. `AsyncHTTP`, sockets, TLS, and the HTTP
  thread are owned by the host adapter.
- The host adapter also implements opaque file-resource open/read/write/close
  commands; descriptors never cross into the VM.
- `QuickJsEngine` is a second implementation of the same `Engine` vtable. It
  uses the sibling quickjs-ng wrapper and is exercised against multiple source
  buffers by `zig build rt-test`. `engine_selector.Implementation(.jsc)` and
  `.quickjs` are the compile-time switch; QuickJS currently exposes only pure
  JavaScript.

This is an interface boundary inside the production monolith, not yet a
physical `libcruller.so` boundary. Module loading, file-backed Blob operations,
`Bun.serve`, WebSockets, Valkey, and other retained native bindings have not yet
been connected to the host commands. The direct transport is not a ring and the
file executor is not io_uring-backed yet. Those migrations are required before
the VM side can be built as an I/O-free dynamic library.

### Current boundary state

| Capability | JSC | QuickJS | Boundary state |
| --- | --- | --- | --- |
| Load and execute a source buffer | Implemented | Implemented | Complete |
| Engine lifecycle (`load/run/poll/interrupt/destroy`) | Implemented | Implemented | Complete |
| Outbound `fetch` | Routed through host commands | No JS binding | Partial; compatibility work remains |
| Host-owned file operations | Command adapter exists | No JS binding | Partial; executor is not io_uring |
| Bundled synchronous SSR handler | Command/data dispatcher | Command/data dispatcher | Initial vertical slice implemented |
| Incoming network HTTP server | Existing Bun/JSC path | Unavailable | Host listener adapter not migrated |
| Module loading | Existing JSC resolver still participates | Unavailable | Not migrated |
| WebSockets, file-backed Blob, and Valkey | Existing direct bindings | Unavailable | Not migrated |
| Transport implementation | Mutex queues and heap data pool | Same | Rings/shared buffers not implemented |
| Physical engine library | Monolithic link | Monolithic test link | Not implemented |

QuickJS can now run a synchronous bundled SSR handler exposed as
`globalThis.__crullerHandle`. Requests and responses are UTF-8 JSON envelopes
carried as `BufferRef` payloads on `server_request` and `server_response_end`
commands. The same dispatcher and JavaScript convention are wired to JSC. This
first slice is suitable for synchronous rendering such as `renderToString`; it
does not yet support Promise results, streaming responses, host HTTP listeners,
or QuickJS webcore compatibility globals.

The QuickJS wrapper currently configures a 16 MiB JavaScript heap limit and a
512 KiB stack limit. These are engine limits, not process memory measurements.
With the harness held to O(1) memory, the measured process peak RSS for the
100k-request SSR run is ~7.5 MB (flat from 1k to 100k), so QuickJS now sits
near a small-process budget rather than the ~42 MB the old queueing harness
reported.

### Next tasks

1. Replace the initial JSON body representation with a binary-safe request and
   response envelope while retaining the existing command and `BufferRef`
   ownership rules. Add Promise completion and streamed response commands.
2. Implement the incoming HTTP host adapter. The host owns listeners,
   connections, protocol parsing, request bodies, response writes, TLS, and
   cancellation. The VM receives only an invocation and referenced bytes.
3. Add the asynchronous host-command bridge to QuickJS using the same command
   and completion protocol as JSC. Do not introduce a separate synchronous
   QuickJS host API that would bypass the boundary.
4. Run a self-contained bundled SSR handler as one source buffer. Module
   filesystem access is deliberately excluded from this first slice. Execute
   identical request vectors first on JSC and then on QuickJS and compare
   status, headers, body, errors, and cancellation behavior.
5. Move module resolution behind host-provided buffers. Start with a complete
   pre-built bundle; add module-graph requests only when a production workload
   requires them.
6. Finish outbound fetch compatibility, including proxy headers, TLS and
   certificate-validation options, sendfile behavior, and stable error mapping.
7. Move WebSockets, file-backed Blob operations, Valkey, and every remaining I/O
   call site to host commands.
8. Replace the direct adapters with bounded SPSC command rings and shared or
   io_uring-registered buffers. The existing `Engine`, command, and `BufferRef`
   contracts must remain unchanged.
9. Add a build/CI check that rejects direct filesystem, socket, DNS, TLS, and
   process I/O dependencies from the engine target, then produce the dynamic
   library.
10. Benchmark memory and performance only after the same SSR workload runs on
    both engines. Report total RSS, engine heap, startup time, request latency,
    throughput, and leak behavior separately.

The next milestone is accepted only when one bundled SSR script handles the
same in-memory HTTP requests under JSC and QuickJS using the common invocation
and command/data interfaces, with no direct file or network access from either
engine adapter.


## Proposed Cruller Runtime Architecture

`libcruller.so` is a stable dynamic library containing JavaScriptCore. The host, protocols, and external interfaces can be changed and rebuilt without rebuilding WebKit/JSC.

Each runtime instance runs in its own thread and has its own VM, heap, scheduler, and allocator.

```text
┌─────────────────────────────────────────────────────────────────────┐
│                         CRULLER HOST PROCESS                        │
│                                                                     │
│   HTTP/1.1   HTTP/2   HTTP/3   WebSocket   ZMQ   Files   DB   IPC  │
│      │          │        │         │        │      │      │     │   │
│      └──────────┴────────┴─────────┴────────┴──────┴──────┴─────┘   │
│                                 │                                   │
│                    ┌────────────▼────────────┐                      │
│                    │   I/O CONTROLLER THREAD │                      │
│                    │                         │                      │
│                    │ protocol adapters       │                      │
│                    │ routing                 │                      │
│                    │ load balancing          │                      │
│                    │ runtime lifecycle       │                      │
│                    │ drain / restart         │                      │
│                    └───────┬─────────┬───────┘                      │
│                            │         │                              │
│                    commands│         │SQE / CQE                     │
│                  completions│        │buffer references             │
│                            │         │                              │
│          ┌─────────────────┘         └───────────────┐              │
│          │                                           │              │
│   ┌──────▼───────────┐                       ┌───────▼───────────┐  │
│   │ COMMAND RINGS    │                       │     io_uring      │  │
│   │                  │                       │                   │  │
│   │ invoke           │                       │ network I/O       │  │
│   │ async call       │                       │ file I/O          │  │
│   │ completion       │                       │ registered buffers│  │
│   │ drain / stop     │                       │ fixed files       │  │
│   └──────┬───────────┘                       └───────┬───────────┘  │
│          │                                           │              │
│          │ control                                   │ data path    │
│          │                                           │              │
│   ┌──────▼──────────────┐     buffer references     │              │
│   │ RT THREAD #1        │◄───────────────────────────┤              │
│   │ libcruller.so       │                            │              │
│   │ JSC / GC / JS       │────────────────────────────┤              │
│   │ scheduler           │      async operations      │              │
│   │ allocator #1        │                            │              │
│   └─────────────────────┘                            │              │
│                                                     │              │
│   ┌─────────────────────┐     buffer references     │              │
│   │ RT THREAD #2        │◄───────────────────────────┤              │
│   │ libcruller.so       │                            │              │
│   │ JSC / GC / JS       │────────────────────────────┘              │
│   │ scheduler           │      async operations                     │
│   │ allocator #2        │                                           │
│   └─────────────────────┘                                           │
└─────────────────────────────────────────────────────────────────────┘
```

The external interfaces—HTTP/1.1, HTTP/2, HTTP/3, WebSocket, ZeroMQ, files, databases, and IPC—are implemented outside the runtime as replaceable host modules.

The controller converts interface events into messages for a selected runtime and maps runtime asynchronous calls back to the required external interface.

Command rings carry only small control messages:

```text
INVOKE
ASYNC_CALL
COMPLETE
CANCEL
DRAIN
STOP
```

`io_uring` provides the shared Linux-native data path for both network and file operations. Runtime instances exchange buffer references with the controller instead of copying payloads through the command rings.

Runtime lifecycle:

```text
ACTIVE → DRAINING → DESTROY → CREATE
```

The controller stops routing new work to a runtime, lets active operations finish, destroys the runtime together with its allocator, and creates a fresh instance from the same `libcruller.so`.


## Building

Compiled with vanilla Zig 0.16 via a dedicated build harness (`build016.zig`), separate from Bun's own build
scripts:

```sh
cd cruller
zig build --build-file build016.zig check
```

The check target first runs the existing code-generation graph to materialize
the modules under `build/codegen`; it does not build the C++ runtime. This
bootstrap still requires an installed Bun, because the retained generators are
TypeScript programs. Replacing that dependency with a Zig-native code-generation
path remains a separate milestone.

A `bun_core/bzrt_compat.zig` shim provides small replacements for stdlib APIs removed between Zig 0.15 and
0.16 (`GenericWriter`/`GenericReader`, `NetAddress`, list writers, a monotonic timer, etc.) so the kept code
doesn't need to be rewritten wholesale.

### Container image

`glib.Containerfile` packages the already-built `build/release/bun` (glibc):

```sh
cd cruller
podman build -f glib.Containerfile -t cruller .
```

The x64 musl variant is built natively in Alpine and packaged into a separate
runtime image. The final binary uses `/lib/ld-musl-x86_64.so.1`:

```sh
podman build -f musl.Containerfile -t cruller-musl .
```

## License

Cruller is a derivative of [Bun](https://github.com/oven-sh/bun) (MIT-licensed) and inherits its license —
see `LICENSE`.
