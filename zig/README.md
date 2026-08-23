# dhake — Zig port scaffold (U0)

This directory is the Zig reimplementation of `src/dhake.c`. It links the
**Zig dhall core** (`libdhall.so` from `dhall-c/zig`) **in-process via the C-ABI
seam**, rather than calling out to a subprocess. All core access is confined to
two modules:

- `src/dhall_types.zig` — extern-struct mirror of `dhall.h` (copied verbatim
  from `dhall-c/zig/src/dhall.zig`).
- `src/dhall_abi.zig` — extern fn decls for the `arena_*` / `import_loader_*` /
  `parse_source` / `normalize*` / `sha256_hex` surface.

The eventual migration goal: a Zig `dhake` whose `tests/build.sh` output
**exactly matches** `zig/BASELINE.txt` (78 passed / 13 failed, same 13 failing
case names, same failure-message shapes). `src/dhake.c` is never modified — it
stays the spec and the oracle source.

## Layout

- `src/main.zig` — CLI entry point + hidden `--abi-smoke` flag (U0 gate).
- `src/dhall_types.zig`, `src/dhall_abi.zig` — the ABI seam.
- `src/sysio.zig`, `src/opts.zig` — stubs, filled in by later units.
- `build.sh` — builds `zig-out/dhake`.
- `oracle.sh` + `oracle-shim/` — rebuilds the **C oracle** `zig-out/dhake.oracle`.
- `dhake_diff.sh` — differential harness (skeleton; corpus filled in U1).
- `BASELINE.txt` — recorded `tests/build.sh zig-out/dhake.oracle` output.

## Build

```sh
bash zig/build.sh          # -> zig-out/dhake
bash zig/oracle.sh         # -> zig-out/dhake.oracle (fresh C oracle)
```

## ABI smoke

```sh
zig-out/dhake --abi-smoke
# SMOKE OK default=hello mapKey=hello phony=false shell=echo building hello sha256(abc)=ba7816bf...
```

## Run the baseline

```sh
bash tests/build.sh zig-out/dhake.oracle   # from repo root
```

Must equal **78 passed / 13 failed**. That is the parity gate the Zig port must
reproduce (U6 final gate).

## Differential harness

`zig/dhake_diff.sh` is the layered differential gate (see plan DIFFERENTIAL
HARNESS observation):

- **Layer 1** — deterministic no-side-effect modes (`--list`, `-n`, `--verify`,
  `--explain`, `--graph`, `--graph=mermaid`): run ORACLE and ZIG with identical
  args on the corpus in `zig/tests/corpus/*.dhall` + `Dhakefile.dhall` and diff
  stdout/stderr/rc byte-identical.
- **Layer 2** — `tests/build.sh` parity: identical PASS/FAIL set vs
  `zig/BASELINE.txt`.
