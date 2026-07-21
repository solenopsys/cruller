# TODO

## Build 4 targets

Cruller needs to build for all 4 supported Linux target combos (see
`scripts/build/config.ts`: `Arch = "x64" | "aarch64"`, `Abi = "gnu" | "musl" | "android"`
— `android` excluded here, this is server-side only):

- `x64-gnu` — currently the only one built (`build/release/bun`), glibc-linked,
  requires `GLIBC_2.38+`. Packaged in `glib.Containerfile` (`debian:trixie-slim`).
- `x64-musl`
- `aarch64-gnu`
- `aarch64-musl`

musl variants would let the runtime image be Alpine-based instead of
`debian:trixie-slim` (smaller, matches `centimanus`/upstream `bun-alpine` style).

## Blockers / notes

- No system `clang` on this host — `scripts/build/compile.ts` shells out to
  `clang`/`clang++` directly. Either install clang/LLVM, or look into pointing
  the harness at `zig cc` (zig 0.16 is already installed and cross-targets
  `x86_64-linux-musl` / `aarch64-linux-musl` out of the box, no sysroot setup
  needed).
- `detectAbi()` in `scripts/build/config.ts` auto-picks `musl` only when
  `/etc/alpine-release` exists — i.e. the tested path is building natively
  *inside* an Alpine container, not cross-compiling from a glibc host. Cross
  via `--abi=musl --arch=<x64|aarch64>` is untested in this fork.
- lolhtml is built via `cargo` and needs the nightly toolchain
  (`RUSTUP_TOOLCHAIN=nightly`, unstable `-Zbuild-std`) — check nightly rustc
  is available for whichever host ends up doing the musl/aarch64 builds.
- Once `x64-musl` exists, add `musl.Containerfile` (Alpine-based, mirrors
  `glib.Containerfile`) and wire both into the image build alongside
  `aarch64` variants (`--platform` / buildx matrix) once those are built too.
