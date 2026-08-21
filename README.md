# dhake

**dhake** is a Make-like build tool whose buildfile is written in
[Dhall](https://dhall-lang.org). It evaluates a `Dhakefile.dhall` with an
embedded C Dhall interpreter, maps the normalized value onto a build plan, and
executes it — dependency ordering, incremental (mtime) up-to-date checks, phony
targets, and typed actions.

It compiles with [cosmocc](https://github.com/jart/cosmopolitan) into a single
portable [Actually Portable Executable](https://justine.lol/ape.html) (APE) that
runs on Linux, macOS, Windows, and BSDs from one file.

`dhake` is **self-hosting**: the committed `dhake.com` is the bootstrap binary,
and the `Dhakefile.dhall` at the repo root builds `dhake.com` from source.

## Why

Makefiles are turing-tarpit shell scripts with surprising whitespace semantics.
Dhall is a strongly-typed, total configuration language — so your build
definition gets type checking, imports, and reusable functions, and it *always*
terminates. The build plan is a plain value you can reason about, not a recipe
of shell side effects.

## Build (self-hosting)

No build system required to build dhake — dhake builds itself:

```sh
./dhake.com.dbg          # evaluates Dhakefile.dhall, builds dhake.com
./dhake.com.dbg --list   # list targets
```

The resulting `dhake.com` is itself a dhake executable, so you can drop it on
any system and it rebuilds the next copy from source.

Requirements: `cosmocc` on `$PATH` (the committed `dhake.com` is the bootstrap;
rebuilding from source needs the toolchain).

## Test

```sh
./tests/build.sh ./dhake.com.dbg     # 18 end-to-end cases
```

## Usage

```
dhake [-f FILE] [-j N] [-n] [--list] [target ...]
```

- `-f FILE` — buildfile to evaluate (default: `./Dhakefile.dhall`, else `./build.dhall`)
- `-j N` — run up to N build jobs in parallel (default: 1, sequential). Stops scheduling new targets on first failure but lets already-running targets finish.
- `-n` — dry run: print actions without running them
- `--list` — list targets and exit
- `target` — build named target(s); default is the buildfile's `default`

Exit codes: `0` success; the failing recipe's exit code on a recipe failure
(`2` if the shell couldn't spawn or the command was signaled); `2` for
buildfile parse/structural errors.

## The Dhall DSL

A `Dhakefile.dhall` is a value of this shape:

```dhall
let Action = < Shell : Text
             | Copy : { from : Text, to : Text }
             | Mkdir : < Plain : Text | Parents : { path : Text, parents : Bool } >
             | Rm : < Plain : Text | Recursive : { path : Text, recursive : Bool } >
             | Touch : Text
             | Move : { from : Text, to : Text }
             | Symlink : { from : Text, to : Text }
             | Chmod : { path : Text, mode : Text }
             | Echo : Text
             | Env : { key : Text, value : Text }
             | Run : { argv : List Text }
             >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets = List { mapKey : Text, mapValue : Target }
    , default : Text
    }
```

Each target has:

- **`deps`** — names of other targets (or plain source files). A name that is
  also a declared target is built first; a name that isn't is treated as a
  source file (a leaf dependency, no build step).
- **`phony`** — when `True`, the target is always rebuilt (never "up to date").
  Use for `clean`-style targets.
- **`recipe`** — a list of actions, each a tagged union value the interpreter
  normalizes. `Shell` runs a command via `/bin/sh`; `Copy`/`Mkdir`/`Rm`/`Touch`
  map to direct libc calls; `Move` renames a file; `Symlink` creates a symbolic link;
  `Chmod` changes file permissions (mode is octal Text); `Echo` prints text to stdout;
  `Env` sets an environment variable (affects subsequent actions in the same recipe);
  `Run` executes a program directly via `execvp` (no shell) with the given argv list.

### Recursive Mkdir / Rm

`Mkdir` with a bare `Text` creates a single directory level (legacy behaviour). To
create missing parents (like `mkdir -p`) and to delete whole trees (like `rm -rf`),
give the action a record payload with the relevant boolean flag — either the
type-honest nested-union spelling:

```dhall
[ < Mkdir = < Parents = { path = "a/b/c", parents = True } > >
, < Rm = < Recursive = { path = "dist", recursive = True } > >
]
```

or the equivalent ergonomic plain record:

```dhall
[ < Mkdir = { path = "a/b/c", parents = True } >
, < Rm = { path = "dist", recursive = True } >
]
```

Without the flag the behaviour is unchanged: `Rm` only removes a single file or an
empty directory (it fails on a non-empty directory rather than recursing), and
`Mkdir` only creates one level.

### Example

```dhall
let Action = < Shell : Text
             | Copy : { from : Text, to : Text }
             | Mkdir : < Plain : Text | Parents : { path : Text, parents : Bool } >
             | Rm : < Plain : Text | Recursive : { path : Text, recursive : Bool } >
             | Touch : Text
             | Move : { from : Text, to : Text }
             | Symlink : { from : Text, to : Text }
             | Chmod : { path : Text, mode : Text }
             | Echo : Text
             | Env : { key : Text, value : Text }
             | Run : { argv : List Text }
             >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets =
        [ { mapKey = "hello"
          , mapValue = { deps = [ "hello.c" ], phony = False
                       , recipe = [ < Shell = "cc -o hello hello.c" > ]
                       }
          }
        , { mapKey = "clean"
          , mapValue = { deps = [] : List Text, phony = True
                       , recipe = [ < Rm = "hello" > ]
                       }
          }
        ]
    , default = "hello"
    }
```

Note: records are sorted alphabetically by the interpreter, so the explicit
`default` field is required. The `targets` list preserves source order (used by
`--list`).

## How it works

`dhake` links the dhall-c interpreter core (`vendor/dhall-c` is a git submodule,
pinned to commit `07a069c`) and drives it in-process: parse → normalize → walk
the normalized Term tree onto a build plan. No JSON round-trip; the buildfile is
evaluated directly.

- **Dependency graph** — iterative DFS topo-order with 3-color cycle detection.
  Only the subgraph reachable from the requested target(s) is built.
- **Parallel scheduling (`-j N`)** — a fork/waitpid scheduler launches up to `N`
  independent (ready) targets concurrently; each target builds in its own child
  process. Dependencies gate readiness via a `deps_pending` count, and up-to-date
  decisions are made at launch time once all deps are final. On the first failure
  it stops scheduling new targets but lets already-running ones finish, then
  returns the failing exit code (make-style). `-j 1` is the sequential default.
- **Up-to-date check** — a target is dirty iff it's phony, its file is missing,
  any dependency target is dirty, or any dependency file (target or source) is
  newer than it (nanosecond mtime resolution).
- **Actions** — `Shell` uses `system()` and `Run` uses `fork`+`execvp` (no
  shell); `Copy`/`Mkdir`/`Rm`/`Touch`/`Move`/`Symlink`/`Chmod` are direct libc
  calls (no shell-escaping risk).

One deliberate design note: the interpreter's *typecheck* pass is skipped. The
ergonomic shorthand `< Shell = "..." >` is a *singleton* union literal, whose
inferred type is `< Shell : T >`, so a buildfile with heterogeneous singleton
unions across targets doesn't typecheck even though it normalizes correctly.
dhake does its own structural validation while walking the normalized tree and
reports clear errors.

## Layout

```
Dhakefile.dhall        self-hosting buildfile (builds dhake.com)
src/dhake.c            the tool (single file, links dhall-c core)
tests/build.sh         18 end-to-end cases
vendor/dhall-c         dhall-c interpreter (git submodule @ 07a069c)
docs/                  GitHub Pages site
.github/workflows/     Pages deploy workflow
dhake.com              committed bootstrap APE (self-host)
```

The `docs/` site is plain committed HTML; `.github/workflows/pages.yml`
deploys it to GitHub Pages on every push to `master`. Enable once in the repo:
**Settings → Pages → Source → "GitHub Actions"**.

## License

MIT.
