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

## Status

This is work in progress. The Zig semantic check and debug/release builds pass,
and basic CJS/ESM execution works. The release runtime is `ReleaseFast`, embeds
its generated JavaScript assets, and passes the applicable Node path and HTTP
smoke checks. See [`problem.md`](problem.md) for the current verification scope
and remaining limitations.

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
cd bun-strip
zig build --build-file build016.zig check   # semantic check of the trimmed tree
```

A `bun_core/bzrt_compat.zig` shim provides small replacements for stdlib APIs removed between Zig 0.15 and
0.16 (`GenericWriter`/`GenericReader`, `NetAddress`, list writers, a monotonic timer, etc.) so the kept code
doesn't need to be rewritten wholesale.

## License

Cruller is a derivative of [Bun](https://github.com/oven-sh/bun) (MIT-licensed) and inherits its license —
see `LICENSE`.
