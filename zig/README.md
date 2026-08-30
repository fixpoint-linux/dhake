# dhake — Zig implementation

This directory is the Zig implementation of dhake (the C bootstrap
`src/dhake.c` has been removed; this is the only source build). It links the
**Zig dhall core** (`libdhall.so` from `dhall-c/zig`) **in-process via the
C-ABI seam**, rather than calling out to a subprocess. All core access is
confined to two modules:

- `src/dhall_types.zig` — extern-struct mirror of `dhall.h` (copied verbatim
  from `dhall-c/zig/src/dhall.zig`).
- `src/dhall_abi.zig` — extern fn decls for the `arena_*` / `import_loader_*` /
  `parse_source` / `normalize*` / `sha256_hex` surface.

The functional gate: `bash tests/build.sh zig-out/dhake` (from the repo root)
must show **no new failures vs `zig/BASELINE.txt`**. BASELINE.txt records the
original C-oracle run (78 passed / 13 failed); the current Zig build passes
strictly more (90/1 — only the known `watch-rebuild-on-change` case still
fails, as it did in the baseline).

## Layout

- `src/main.zig` — CLI entry point + hidden `--abi-smoke` flag.
- `src/dhall_types.zig`, `src/dhall_abi.zig` — the ABI seam.
- `src/sysio.zig`, `src/opts.zig` — system wrappers, CLI parsing.
- `src/` — eval, exec, graph, hash, plan, report, sandbox, watch modules.
- `build.sh` — builds `zig-out/dhake`.
- `tests/corpus/` — crafted `.dhall` buildfiles (extracted from
  `tests/build.sh` by `extract_corpus.sh`).
- `BASELINE.txt` — recorded `tests/build.sh` output (the parity baseline).

## Build

```sh
bash zig/build.sh          # -> zig-out/dhake
```

## ABI smoke

```sh
zig-out/dhake --abi-smoke
# SMOKE OK default=hello mapKey=hello phony=false shell=echo building hello sha256(abc)=ba7816bf...
```

## Run the functional gate

```sh
bash tests/build.sh zig-out/dhake   # from repo root
```

Must stay at **zero new failures vs `zig/BASELINE.txt`** (currently
90 passed / 1 failed; `watch-rebuild-on-change` fails in the baseline too).
