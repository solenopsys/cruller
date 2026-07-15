#!/usr/bin/env python3
"""Restore the Bun 1.3.14 FFI sources from the adjacent read-only reference."""

from hashlib import sha256
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REFERENCE = ROOT.parent / "bun-reference-1.3.14"

FILES = (
    "src/js/bun/ffi.ts",
    "src/runtime/ffi/FFI.h",
    "src/runtime/ffi/FFIObject.zig",
    "src/runtime/ffi/ffi-stdalign.h",
    "src/runtime/ffi/ffi-stdarg.h",
    "src/runtime/ffi/ffi-stdatomic.h",
    "src/runtime/ffi/ffi-stdbool.h",
    "src/runtime/ffi/ffi-stddef.h",
    "src/runtime/ffi/ffi-stdnoreturn.h",
    "src/runtime/ffi/ffi-tgmath.h",
    "src/runtime/ffi/ffi.classes.ts",
    "src/runtime/ffi/ffi.zig",
    "src/runtime/ffi/libtcc1.c",
    "src/tcc_sys/tcc.zig",
)


def main() -> None:
    if not REFERENCE.is_dir():
        raise SystemExit(f"reference is missing: {REFERENCE}")

    for relative in FILES:
        source = REFERENCE / relative
        target = ROOT / relative
        data = source.read_bytes()
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        if sha256(target.read_bytes()).digest() != sha256(data).digest():
            raise SystemExit(f"verification failed: {relative}")
        print(f"restored {relative} {sha256(data).hexdigest()[:12]}")

    print(f"restored {len(FILES)} verified files")


if __name__ == "__main__":
    main()
