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

With `--watch`, dhake becomes a dev-loop tool: it watches your source-file
dependencies and automatically rebuilds on any change, turning edit-save-refresh
into a seamless workflow.

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
./tests/build.sh ./dhake.com.dbg     # 22 end-to-end cases
```

## Usage

```
dhake [-f FILE] [-j N] [-n] [-D KEY=VALUE|--define KEY=VALUE] [--arch=NAME] [--cache[=DIR]] [--list] [--warn-hash-mismatch] [--lock[=FILE]] [--verify|--check] [--hash-uptodate] [--watch|-w] [--explain|--why] [--graph[=dot|mermaid]] [--quiet|-s] [target ...]
```

- `-f FILE` — buildfile to evaluate (default: `./Dhakefile.dhall`, else `./build.dhall`)
- `-j N` — run up to N build jobs in parallel (default: 1, sequential). Stops scheduling new targets on first failure but lets already-running targets finish.
- `-n` — dry run: print actions without running them
- `--list` — list targets and exit
- `--warn-hash-mismatch` — report verified-build hash mismatches as warnings (printing the actual hash) instead of failing; see [Verified builds](#verified-builds)
- `--lock[=FILE]` — write a lockfile (default: `dhake.lock`, or `FILE` if `=FILE` given) with actual hashes and transitive dependencies after a successful build; see [Lockfile / SBOM](#lockfile--sbom)
- `--verify` / `--check` — verify all pinned hashes and up-to-dateness without running recipes (CI pre-flight); see [Verified builds](#verified-builds)
- `--hash-uptodate` / `--content-addressed` — decide up-to-dateness by content hash instead of mtime (content-addressed builds); see [Verified builds](#verified-builds)
- `--watch` / `-w` — rebuild and watch the requested targets' source-file dependencies; on any change, rebuild (dev-loop). Uses Linux inotify; fails with an error message on other platforms.
- `--explain` / `--why` — pure diagnostic: print why each target in the requested subgraph needs rebuilding (or that it is up to date) without running any recipes. Exit code is nonzero if any target is dirty. Useful to see *why* something is out of date before building.
- `--graph[=dot|mermaid]` — pure diagnostic: dump the full dependency graph and exit. Default format is `dot` (Graphviz); `mermaid` is also supported. Shows target→dep edges, phony targets with different styling, and expected output hashes on node labels.
- `--quiet` / `-s` — suppress per-recipe command echo (summary lines like "building..." and errors are still shown)
- `-D KEY=VALUE` / `--define KEY=VALUE` — inject `KEY=VALUE` into the buildfile evaluation environment, making it available to `env:KEY` imports (CMake-style). Use the same Dhakefile for debug/release builds by passing different `--define` values.
- `--arch=NAME` — set the architecture to `NAME` for this build. This sets the `DHAKE_ARCH` environment variable (available in recipes via `$DHAKE_ARCH` and in buildfiles via `${env:DHAKE_ARCH}`). Targets with an `arch` field that doesn't match are skipped. Default: auto-detected via `uname()`.
- `--cache[=DIR]` — enable ccache-style build caching: skip recipe execution when a target's inputs and recipe are identical to a previous build. With `--cache`, uses default dir (`$XDG_CACHE_HOME/dhake` or `$HOME/.cache/dhake` or `.dhake-cache`). With `--cache=DIR`, uses `DIR`. Caching is **OPT-IN** and disabled by default. **Only enable for deterministic recipes** (same inputs → same output). The cache key includes the target name, architecture, recipe text, and content hashes of all input dependencies. Pinned output hashes are still verified on cache restore as a safety net.
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
let Target = { deps : List Text, phony : Bool, recipe : List Action
             , unveil : Optional (List Text)   -- per-target sandbox whitelist
             , hash : Optional Text        -- expected hash of output (verified builds)
             , depsHash : Optional (List { path : Text, hash : Text })
             , cwd : Text                 -- working directory for recipe execution
             , arch : Optional Text       -- target architecture (e.g. "x86_64", "aarch64"); only built when --arch matches
             }
in  { targets = List { mapKey : Text, mapValue : Target }
    , default : Text
    , sandbox : Optional { enable : Bool, readExec : Bool, denyNetwork : Bool, unveil : List Text }
    }
```

`deps`, `phony` and `recipe` are required. `unveil` on a target and the
 top-level `sandbox` block are optional (see [Sandboxing](#sandboxing-landlock)).
 The `hash`, `depsHash`, `cwd`, and `arch` fields are also optional (see [Verified builds](#verified-builds)).

**Build caching** (via `--cache[=DIR]`) is a global opt-in flag and does not require
 any new fields in the Target schema; it works with existing targets automatically.

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
- **`cwd`** — optional working directory for recipe execution. When set, the recipe
  runs in that subdirectory (relative to the build root). Useful for building in
  subdirectories without shell `cd` boilerplate.
- **`arch`** — optional architecture filter. When set to a value like `"x86_64"` or `"aarch64"`,
  the target will only be built when `--arch` matches this value (or when `--arch` is not
  specified and the auto-detected architecture matches). Targets without an `arch` field
  are built on all architectures. The current architecture is available in recipes via
  `$DHAKE_ARCH` and in buildfiles via `${env:DHAKE_ARCH}`.

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

### Sandboxing (Landlock)

dhake can run each recipe in a [Linux Landlock](https://www.kernel.org/doc/html/latest/userspace-api/landlock.html) sandbox — unprivileged, opt-in, like [landlock-make](https://justine.lol/make/). Enable it with a top-level `sandbox` block:

```dhall
in  { targets = ...
    , default = "dhake.com"
    , sandbox = { enable = True
                , readExec = True
                , denyNetwork = True
                , unveil = [ "rwc:~/.npm", "rwc:~/.cache", "rwc:~/.elm" ]
                }
    }
```

**Model.** By default (write containment), the ruleset handles **only the WRITE-class rights** (write/create/remove/rename). READ and EXECUTE are deliberately left unrestricted, so recipes can still exec any tool (the shell, `cc`, `node`, …) and read any file — but a rogue or buggy recipe **cannot write outside the unveiled directories**. Landlock has no `chmod`/`chown` right, so those still work.

When `sandbox.readExec = True`, READ_FILE, READ_DIR, and EXECUTE are also handled. In this mode, recipes **cannot read or execute outside the unveiled directories** — but the standard toolchain directories (`/usr/bin`, `/usr/lib`, `/usr/include`, etc.) are **auto-unveiled** with appropriate permissions so builds can still compile and run programs. A rogue recipe cannot read `/etc/passwd` or scan home directories.

When `sandbox.denyNetwork = True`, a seccomp BPF filter is installed that **denies socket creation for network address families** (AF_INET, AF_INET6, AF_PACKET, AF_NETLINK) with EPERM, while still allowing AF_UNIX/AF_LOCAL sockets. This prevents network egress (a rogue recipe cannot phone home or pull dependencies). The filter is applied per-recipe-child and fails closed if seccomp cannot be established. *Caveats:* it blocks *creation* of network sockets only — an already-open network fd inherited across fork would still be usable, but dhake itself opens no network sockets, so none are inherited by recipe children. Exotic non-IP families (AF_BLUETOOTH, AF_CAN, AF_VSOCK, AF_XDP) are not denied, but none enable standard internet egress.

**What is unveiled automatically.** The build directory (cwd), `/tmp`, `$TMPDIR`, and `/dev/{null,zero,full,tty}` — all read-write-execute (cwd and /tmp get EXECUTE so outputs can be run). When `readExec = True`, the standard toolchain directories are also auto-unveiled: bin dirs (`/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`, `/usr/local/bin`) with READ+EXECUTE; lib dirs (`/usr/lib`, `/lib`, `/usr/lib64`, `/lib64`, `/usr/local/lib`) with READ+EXECUTE; include dirs (`/usr/include`, `/usr/local/include`) with READ only.

**The `unveil` whitelist.** Entries are `"perms:path"`; the default perms are `rwc`. `w` and `c` are enforced (write/create/remove); `r` maps to READ_FILE|READ_DIR; `x` maps to EXECUTE. A leading `~` expands to `$HOME`. You can also give a **per-target** `unveil` list to whitelist extra paths for just that target (e.g. a test that needs a system file). Global and per-target unveils aggregate.

**Limitations.** Landlock rules are on *inodes*, so a path must exist when the rule is added — unveiling a not-yet-created leaf file is a no-op. Unveil a directory (or the parent of a to-be-created file) instead. And because rules are per-inode, deleting an unveiled path re-veils it. The write-containment model sidesteps the missing-output-file problem entirely: outputs under the build tree are covered by the cwd rule.

**Fallback.** If landlock is unavailable (kernel < 5.13 or non-Linux), dhake's behavior depends on the mode:
- **write-containment (`readExec = False`, default):** prints a single warning (`landlock sandbox unavailable`) and runs the build **unsandboxed**, so the same buildfile works everywhere (e.g. in a CI sandbox that blocks the landlock syscall).
- **`readExec = True`:** **fails closed** — dhake aborts the build with a clear error rather than running recipes unsandboxed. Because `readExec` explicitly requests read/execute containment, silently skipping it would defeat the security guarantee. Disable `readExec` (or run on a landlock-capable host) to proceed.
- **`denyNetwork = True`:** **fails closed** — if seccomp cannot be established (unsupported architecture or kernel), dhake aborts the recipe child with exit code 3 rather than running with network access. Because `denyNetwork` explicitly requests network containment, silently skipping it would defeat the security guarantee.

### Shell recipes

Each `Shell` action is executed with the platform's real POSIX shell:

```c
fork + exec("/bin/sh", "-c", <recipe text>)
```

dhake deliberately does **not** use libc `system()`. Cosmopolitan's embedded command
interpreter (`_cocmd`, which `system()` dispatches to) applies a `>` redirection by
permanently reassigning the shell's fd 1, and `;`-chained commands run in that same
process — so a recipe like `echo start; echo x > f; echo after; echo end` used to send
**all four** lines to `f` (only `start` reached stdout). Delegating to the real
`/bin/sh` scopes each redirection to a single command, so redirects, `$?`, pipelines
and `&&`/`||` behave correctly.

> **Note (parked).** The proper fix is upstream: patch cosmopolitan's `cocmd.c` to
> scope redirects to a single command and rebuild the libc/toolchain (tracked as a
> `fixpoint-linux/cosmopolitan` fork). Until that ships, this exec-shell is the
> workaround. Because the Landlock sandbox only restricts WRITE-class rights (not
> EXECUTE), `/bin/sh` and the tools a recipe spawns still run inside the sandbox.

### Verified builds

dhake supports **opt-in hash verification** of build outputs and source dependencies,
providing reproducible-build guarantees for targets that need them. The hash format
is algorithm-prefixed (e.g., `sha256:<64-hex-digits>`), making it future-proof for
adding new algorithms like `sha512` later.

- **`hash : Text`** (optional, on `Target`) — the expected hash of the target's output
  file in the format `<algorithm>:<hexdigest>` (e.g., `sha256:abc123...`). When present,
  dhake verifies the output after a successful build and also checks it on subsequent
  runs when the target is "up to date" by mtime (catches tampered outputs). Only
  meaningful for non-`phony` targets (a `phony` target has no output file to verify).
- **`depsHash : List { path : Text, hash : Text }`** (optional, on `Target`) — a
  list of expected hash specs for source-file dependencies. dhake verifies these
  **before** launching the target's recipe, ensuring input integrity regardless of
  whether the target is up to date.

Both fields use the **algorithm-prefixed** format. The algorithm prefix (currently
only `sha256` is supported) makes the DSL future-proof: additional algorithms can be
added by extending the dispatch without breaking existing buildfiles.

**Example:**

```dhall
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action
             , hash : Text
             , depsHash : List { path : Text, hash : Text }
             }
in  { targets =
      [ { mapKey = "app"
        , mapValue =
            { deps = ["main.c"], phony = False
            , recipe = [ < Shell = "cc -o app main.c" > ]
            , hash = "sha256:abc123..."      -- expected hash of 'app'
            , depsHash = [ { path = "main.c", hash = "sha256:def456..." } ]
            }
        }
      ]
    , default = "app"
    }
```

On a successful build, dhake prints:

```
dhake: 'app' verified (sha256 abc123...)
```

On any mismatch (output or dep), dhake exits with code 2 and prints a clear error
identifying the target, the file, and the expected vs actual hashes.

**Updating pinned hashes.** When a pinned hash becomes stale (e.g. after editing a
source file or the toolchain output changes), a normal build fails. Pass
`--warn-hash-mismatch` to instead downgrade every mismatch to a **warning** that
prints the actual hash — in copy-pasteable `<algorithm>:<hexdigest>` form — and let
the build succeed:

```
$ dhake --warn-hash-mismatch app
dhake: warning: target 'app': output hash mismatch: expected sha256:old..., got sha256:new...
dhake: 'app' verified (hash sha256:new...)
```

Copy the `sha256:new...` value into the buildfile's `hash` / `depsHash` fields and
commit. `--warn-hash-mismatch` only relaxes *hash* verification — other errors
(missing files, recipe failures) still abort the build.

- **`--verify` / `--check`** — verify all pinned hashes and up-to-dateness without
  running recipes (CI pre-flight). This complements `-n` (dry-run): where dry-run
  shows what *would* run, verify checks whether anything *needs* to run. Exits
  nonzero if any non-phony reachable target is dirty (needs rebuild) or any hash
  (dep or output) mismatches. Phony targets are reported as "always runs" and never
  trigger a nonzero exit by themselves. No lockfile is written in verify mode, and
  no recipes are executed.

- **`--hash-uptodate` / `--content-addressed`** — decide up-to-dateness by content
  instead of mtime (content-addressed builds). For a non-phony target that pins at
  least one dep hash (`depsHash`), a pinned source input is considered "changed"
  only if its current hash differs from its pinned hash — so `touch`-ing a file
  with unchanged content no longer triggers a spurious rebuild. Targets without a
  `depsHash` (unverified) and phony targets fall back to the normal mtime check, so
  this is fully backward compatible. Useful for CI caching where checkout touches
  files without changing them. Note: because this gating is on *input* hashes, a
  genuine content change still needs the pinned dep hash updated first (or
  `--warn-hash-mismatch`) before dhake will rebuild — mirroring normal verified-build
  behavior.

### Lockfile / SBOM

dhake can export a **lockfile** (machine-readable manifest / SBOM) after a successful
build using `--lock[=FILE]`. The lockfile captures the actual SHA-256 hashes of every
output and dependency, plus the full transitive dependency closure, enabling:

- **Reproducibility verification** — confirm that a build's outputs match the pinned hashes
- **CI provenance** — feed the lockfile to CI or provenance tools to verify build artifacts
- **Dependency auditing** — inspect the complete dependency graph of each target

**Schema:**

```json
{
  "format": "dhake.lock",
  "version": 1,
  "default": "target-name" | null,
  "targets": [
    {
      "name": "string",
      "phony": true | false,
      "deps": ["string", ...],
      "transitiveDeps": ["string", ...],
      "outputHash": {"algorithm": "sha256", "value": "sha256:<hex>"} | null,
      "depHashes": [{"path": "string", "algorithm": "sha256", "value": "sha256:<hex>"}, ...]
    },
    ...
  ]
}
```

- `format` — always `"dhake.lock"`
- `version` — currently `1`
- `default` — the buildfile's default target name, or `null`
- `targets` — array of all targets in buildfile order
- `name` — target name
- `phony` — whether the target is phony
- `deps` — declared dependency names (buildfile order)
- `transitiveDeps` — all target names reachable via dependencies, excluding self (deterministic order)
- `outputHash` — actual SHA-256 hash of the target's output file, or `null` if phony or file missing
- `depHashes` — actual SHA-256 hashes of declared `depsHash` paths that exist; missing files are omitted

**Example:**

```bash
$ dhake --lock
# builds targets, then writes dhake.lock
dhake: wrote lockfile dhake.lock

$ dhake --lock=release.lock
# writes to release.lock instead

$ cat dhake.lock
{
  "format": "dhake.lock",
  "version": 1,
  "default": "app",
  "targets": [
    {
      "name": "main.c",
      "phony": false,
      "deps": [],
      "transitiveDeps": [],
      "outputHash": {"algorithm": "sha256", "value": "sha256:abc123..."},
      "depHashes": []
    },
    {
      "name": "app",
      "phony": false,
      "deps": ["main.c"],
      "transitiveDeps": ["main.c"],
      "outputHash": {"algorithm": "sha256", "value": "sha256:def456..."},
      "depHashes": []
    }
  ]
}
```

The lockfile is **only written on successful builds** (exit code 0), and **never**
written during `--list`, `-n` (dry-run), or when a build fails.

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
