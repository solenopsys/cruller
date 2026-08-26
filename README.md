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

## Status

The existing JSC `ReleaseFast` monolith is in production and can execute and
serve prepared application artifacts. The new engine-neutral boundary is an
active migration inside that monolith. QuickJS proves that the minimal engine
interface can execute source buffers, but it is not yet an SSR/server runtime.
Engine selection is currently a compile-time choice, not a command-line or
runtime parameter.

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
| Incoming HTTP and SSR | Existing Bun/JSC path | Unavailable | Not migrated |
| Module loading | Existing JSC resolver still participates | Unavailable | Not migrated |
| WebSockets, file-backed Blob, and Valkey | Existing direct bindings | Unavailable | Not migrated |
| Transport implementation | Mutex queues and heap data pool | Same | Rings/shared buffers not implemented |
| Physical engine library | Monolithic link | Monolithic test link | Not implemented |

The QuickJS adapter is intentionally limited to pure JavaScript at this stage.
Its wrapper currently configures a 16 MiB JavaScript heap limit and a 512 KiB
stack limit. These are engine limits, not process memory measurements; total RSS
has not been measured, so a 5 MiB SSR process is not a current claim.

### Next tasks

1. Define the smallest engine-neutral invocation contract: identify a loaded
   handler, provide request metadata and body as buffer references, run it, and
   return response status, headers, and body through commands and data buffers.
   No JSC/QuickJS values, callbacks, file descriptors, paths, or pointers may
   cross this contract.
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
