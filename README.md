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

The next design directions follow from that boundary:

- strengthen the retained HTTP/2 and HTTP/3 implementation for production use;
- provide native ZMQ plugins for applications that need message-oriented
  transport without rebuilding the runtime around it;
- add a separate QuickJS-based control plane for dynamic memory policies and
  configuration, keeping complex resource-management decisions out of the
  application JavaScript VM; and
- expose the engine as a small dynamic library with a clean Zig interface, so
  other Zig applications can embed the runtime without inheriting Bun's CLI or
  development stack.

These are roadmap items, not claims of currently shipped functionality.

## Status

This is work in progress. The Zig semantic check and debug/release builds pass,
and basic CJS/ESM execution works. The release runtime is `ReleaseFast`, embeds
its generated JavaScript assets, and passes the applicable Node path and HTTP
smoke checks. See [`problem.md`](problem.md) for the current verification scope
and remaining limitations.

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

## License

Cruller is a derivative of [Bun](https://github.com/oven-sh/bun) (MIT-licensed) and inherits its license —
see `LICENSE`.
