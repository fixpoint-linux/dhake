#!/bin/sh
# dhake_diff.sh — differential harness: Zig dhake vs the C oracle.
#
# Layered gate (plan DIFFERENTIAL HARNESS observation):
#   LAYER 1 — --list over the corpus (zig/tests/corpus/*.dhall + the crafted
#             err_*.dhall files + the repo Dhakefile.dhall + a missing-file
#             case): run ORACLE and ZIG with identical args and compare
#             stdout/stderr/rc BYTE-IDENTICAL.
#   LAYER 2 — tests/build.sh parity: identical PASS/FAIL set vs BASELINE.txt
#             (printed here; run with: bash tests/build.sh zig-out/dhake).
set -u
cd "$(dirname "$0")/.."

C_ORACLE="${C_ORACLE:-zig-out/dhake.oracle}"
ZIG="${ZIG:-zig-out/dhake}"
DIFFDIR="${DIFFDIR:-zig-out/diff}"
mkdir -p "$DIFFDIR"

[ -x "$C_ORACLE" ] || { echo "oracle missing: run bash zig/oracle.sh" >&2; exit 1; }
[ -x "$ZIG" ] || { echo "zig binary missing: run bash zig/build.sh" >&2; exit 1; }

fail=0
total=0

# ---- LAYER 1: byte-identical diff on --list over the corpus ----
# Every corpus file plus Dhakefile.dhall plus a missing-file case.
corpus=""
for f in zig/tests/corpus/*.dhall; do
    [ -f "$f" ] && corpus="$corpus $f"
done
corpus="$corpus Dhakefile.dhall"

for f in $corpus; do
    total=$((total + 1))
    "$C_ORACLE" -f "$f" --list > "$DIFFDIR/o.out" 2> "$DIFFDIR/o.err"
    orc=$?
    "$ZIG" -f "$f" --list > "$DIFFDIR/z.out" 2> "$DIFFDIR/z.err"
    zrc=$?
    ok=1
    if [ "$orc" -ne "$zrc" ]; then echo "RC MISMATCH $f: oracle=$orc zig=$zrc"; ok=0; fi
    cmp -s "$DIFFDIR/o.out" "$DIFFDIR/z.out" || { echo "STDOUT MISMATCH $f"; ok=0; }
    cmp -s "$DIFFDIR/o.err" "$DIFFDIR/z.err" || { echo "STDERR MISMATCH $f"; ok=0; }
    if [ "$ok" -eq 1 ]; then
        echo "PASS $f"
    else
        fail=$((fail + 1))
        echo "FAIL $f"
    fi
done

# Missing-file error case.
total=$((total + 1))
missing="zig/tests/corpus/does_not_exist.dhall"
"$C_ORACLE" -f "$missing" --list > "$DIFFDIR/o.out" 2> "$DIFFDIR/o.err"
orc=$?
"$ZIG" -f "$missing" --list > "$DIFFDIR/z.out" 2> "$DIFFDIR/z.err"
zrc=$?
ok=1
if [ "$orc" -ne "$zrc" ]; then echo "RC MISMATCH missing-file: oracle=$orc zig=$zrc"; ok=0; fi
cmp -s "$DIFFDIR/o.out" "$DIFFDIR/z.out" || { echo "STDOUT MISMATCH missing-file"; ok=0; }
cmp -s "$DIFFDIR/o.err" "$DIFFDIR/z.err" || { echo "STDERR MISMATCH missing-file"; ok=0; }
if [ "$ok" -eq 1 ]; then
    echo "PASS $missing"
else
    fail=$((fail + 1))
    echo "FAIL $missing"
fi

# ---- -D/--define cases (env-import buildfiles) ----
# Exercise the --define path: with defines applied (env resolves) and without
# (env import must fail identically on both binaries).
for dc in c055_build_define_d1.dhall c056_build_define_d2.dhall c057_build_define_d3.dhall; do
    f="zig/tests/corpus/$dc"
    total=$((total + 1))
    "$C_ORACLE" -D CC=clang -D DEBUG=1 -f "$f" --list > "$DIFFDIR/o.out" 2> "$DIFFDIR/o.err"
    orc=$?
    "$ZIG" -D CC=clang -D DEBUG=1 -f "$f" --list > "$DIFFDIR/z.out" 2> "$DIFFDIR/z.err"
    zrc=$?
    ok=1
    if [ "$orc" -ne "$zrc" ]; then echo "RC MISMATCH define $f: oracle=$orc zig=$zrc"; ok=0; fi
    cmp -s "$DIFFDIR/o.out" "$DIFFDIR/z.out" || { echo "STDOUT MISMATCH define $f"; ok=0; }
    cmp -s "$DIFFDIR/o.err" "$DIFFDIR/z.err" || { echo "STDERR MISMATCH define $f"; ok=0; }
    if [ "$ok" -eq 1 ]; then
        echo "PASS define $f"
    else
        fail=$((fail + 1))
        echo "FAIL define $f"
    fi

    total=$((total + 1))
    "$C_ORACLE" -f "$f" --list > "$DIFFDIR/o.out" 2> "$DIFFDIR/o.err"
    orc=$?
    "$ZIG" -f "$f" --list > "$DIFFDIR/z.out" 2> "$DIFFDIR/z.err"
    zrc=$?
    ok=1
    if [ "$orc" -ne "$zrc" ]; then echo "RC MISMATCH nodefine $f: oracle=$orc zig=$zrc"; ok=0; fi
    cmp -s "$DIFFDIR/o.out" "$DIFFDIR/z.out" || { echo "STDOUT MISMATCH nodefine $f"; ok=0; }
    cmp -s "$DIFFDIR/o.err" "$DIFFDIR/z.err" || { echo "STDERR MISMATCH nodefine $f"; ok=0; }
    if [ "$ok" -eq 1 ]; then
        echo "PASS nodefine $f"
    else
        fail=$((fail + 1))
        echo "FAIL nodefine $f"
    fi
done

echo "LAYER 1 --list corpus: $total ran, $((total - fail)) passed, $fail failed"

# ---- LAYER 1b: byte-identical diff on dry-run (-n) over crafted buildfiles ----
# Run in a scratch dir with dep files present so dry-run prints deterministic
# planned actions without executing them. Both binaries share the same dir;
# -n must not modify filesystem state.
dryfail=0
drytotal=0

dry_run_case() {
    name="$1"      # case name
    buildfile="$2" # dhall file copied into scratch as build.dhall
    target="$3"    # target arg (may be empty => default)
    drytotal=$((drytotal + 1))
    dscratch="$(mktemp -d /tmp/dhake-dry.XXXXXX)"
    cp "$buildfile" "$dscratch/build.dhall"
    # seed dep files that recipes reference (bare names resolved via cwd)
    printf '%s\n' 'int main(void){return 0;}' > "$dscratch/hello.c"
    (
        cd "$dscratch"
        if [ -n "$target" ]; then
            "$ORACLE_ABS" -f build.dhall -n "$target" > o.out 2> o.err; orc=$?
            "$ZIG_ABS" -f build.dhall -n "$target" > z.out 2> z.err; zrc=$?
        else
            "$ORACLE_ABS" -f build.dhall -n > o.out 2> o.err; orc=$?
            "$ZIG_ABS" -f build.dhall -n > z.out 2> z.err; zrc=$?
        fi
        echo "$orc" > orc.txt
        echo "$zrc" > zrc.txt
    )
    ok=1
    orc=$(cat "$dscratch/orc.txt")
    zrc=$(cat "$dscratch/zrc.txt")
    if [ "$orc" -ne "$zrc" ]; then echo "RC MISMATCH dry-$name: oracle=$orc zig=$zrc"; ok=0; fi
    cmp -s "$dscratch/o.out" "$dscratch/z.out" || { echo "STDOUT MISMATCH dry-$name"; ok=0; }
    cmp -s "$dscratch/o.err" "$dscratch/z.err" || { echo "STDERR MISMATCH dry-$name"; ok=0; }
    # dry-run must leave no artifacts behind in the scratch dir
    if [ -f "$dscratch/hello" ]; then echo "DRY-SIDE-EFFECT dry-$name: created hello"; ok=0; fi
    if [ "$ok" -eq 1 ]; then
        echo "PASS dry-$name"
    else
        dryfail=$((dryfail + 1))
        echo "FAIL dry-$name"
    fi
    rm -rf "$dscratch"
}

ORACLE_ABS="$(cd "$(dirname "$C_ORACLE")" && pwd)/$(basename "$C_ORACLE")"
ZIG_ABS="$(cd "$(dirname "$ZIG")" && pwd)/$(basename "$ZIG")"

# c001: default target hello (needs rebuild) + phony clean
dry_run_case c001 "zig/tests/corpus/c001_build.dhall" ""
# dry-run phony clean target
dry_run_case c001-clean "zig/tests/corpus/c001_build.dhall" "clean"
# action-move buildfile dry-run (c006)
dry_run_case c006 "zig/tests/corpus/c006_build_move.dhall" ""
# action-symlink buildfile dry-run (c007)
dry_run_case c007 "zig/tests/corpus/c007_build_symlink.dhall" ""
# mkdir-recursive buildfile dry-run (c012)
dry_run_case c012 "zig/tests/corpus/c012_build_mkdir_rec.dhall" ""

echo "LAYER 1b dry-run (-n): $drytotal ran, $((drytotal - dryfail)) passed, $dryfail failed"
fail=$((fail + dryfail))

# ---- LAYER 1g: byte-identical diff on --graph / --graph=mermaid over the corpus ----
# Graph dump is a pure function of the buildfile (topology dump, no fs side
# effects), so the same byte-identical comparison as --list applies. Covers
# multi-target buildfiles with phony styling, out_hash labels, and leaf dedupe.
gfail=0
gtotal=0

graph_case() {
    name="$1"; buildfile="$2"; fmt="$3"
    gtotal=$((gtotal + 1))
    "$C_ORACLE" -f "$buildfile" "$fmt" > "$DIFFDIR/o.out" 2> "$DIFFDIR/o.err"
    orc=$?
    "$ZIG" -f "$buildfile" "$fmt" > "$DIFFDIR/z.out" 2> "$DIFFDIR/z.err"
    zrc=$?
    ok=1
    if [ "$orc" -ne "$zrc" ]; then echo "RC MISMATCH graph-$name: oracle=$orc zig=$zrc"; ok=0; fi
    cmp -s "$DIFFDIR/o.out" "$DIFFDIR/z.out" || { echo "STDOUT MISMATCH graph-$name"; ok=0; }
    cmp -s "$DIFFDIR/o.err" "$DIFFDIR/z.err" || { echo "STDERR MISMATCH graph-$name"; ok=0; }
    if [ "$ok" -eq 1 ]; then
        echo "PASS graph-$name"
    else
        gfail=$((gfail + 1))
        echo "FAIL graph-$name"
    fi
}

# Multi-target buildfile (compile/link/all: target deps + source leaves + phony).
graph_case c001-dot "zig/tests/corpus/c001_build.dhall" "--graph"
graph_case c001-mermaid "zig/tests/corpus/c001_build.dhall" "--graph=mermaid"
# Cycle buildfile (multi-target with a cycle — graph still dumps).
graph_case c003-dot "zig/tests/corpus/c003_build_cycle.dhall" "--graph"
graph_case c003-mermaid "zig/tests/corpus/c003_build_cycle.dhall" "--graph=mermaid"
# Parallel buildfile (independent leaves + phony all).
graph_case c004-dot "zig/tests/corpus/c004_build_parallel.dhall" "--graph"
graph_case c004-mermaid "zig/tests/corpus/c004_build_parallel.dhall" "--graph=mermaid"
# The repo's own Dhakefile.dhall (large multi-target topology).
graph_case dhakefile-dot "Dhakefile.dhall" "--graph"
graph_case dhakefile-mermaid "Dhakefile.dhall" "--graph=mermaid"
# Invalid graph format must die identically on both.
gtotal=$((gtotal + 1))
"$C_ORACLE" --graph=bogus -f zig/tests/corpus/c001_build.dhall > "$DIFFDIR/o.out" 2> "$DIFFDIR/o.err"
orc=$?
"$ZIG" --graph=bogus -f zig/tests/corpus/c001_build.dhall > "$DIFFDIR/z.out" 2> "$DIFFDIR/z.err"
zrc=$?
ok=1
if [ "$orc" -ne "$zrc" ]; then echo "RC MISMATCH graph-badformat: oracle=$orc zig=$zrc"; ok=0; fi
cmp -s "$DIFFDIR/o.out" "$DIFFDIR/z.out" || { echo "STDOUT MISMATCH graph-badformat"; ok=0; }
cmp -s "$DIFFDIR/o.err" "$DIFFDIR/z.err" || { echo "STDERR MISMATCH graph-badformat"; ok=0; }
if [ "$ok" -eq 1 ]; then echo "PASS graph-badformat"; else gfail=$((gfail + 1)); echo "FAIL graph-badformat"; fi

echo "LAYER 1g graph dump: $gtotal ran, $((gtotal - gfail)) passed, $gfail failed"
fail=$((fail + gfail))

# ---- LAYER 1c: byte-identical diff on --verify / --explain over crafted buildfiles ----
# These modes are stateful (their output depends on the on-disk target/dep files), so
# each binary runs in its OWN scratch dir with an IDENTICAL pre-seeded filesystem
# (build the target and/or tamper a file exactly the same way), then the --verify /
# --explain stdout/stderr/rc are compared byte-for-byte.
vxfail=0
vxtotal=0

# run_bin: run one binary in one scratch dir for a --verify/--explain invocation.
#   $1 bin, $2 dir, $3 mode ("--verify" or "--explain"), $4 seed (shell snippet run
#   before the mode invocation, may reference $bin; empty => no seed).
run_bin() {
    bin="$1"; dir="$2"; mode="$3"; seed="$4"
    (
        cd "$dir"
        if [ -n "$seed" ]; then eval "$seed"; fi
        "$bin" -f build.dhall $mode > out.txt 2> err.txt
        echo $? > rc.txt
    )
}

# ve_case: differential --verify/--explain case.
#   $1 name, $2 corpus buildfile, $3 mode, $4 substitution "KEY=VAL" (or empty), $5 seed snippet
ve_case() {
    name="$1"; src="$2"; mode="$3"; sub="$4"; seed="$5"
    vxtotal=$((vxtotal + 1))
    odir="$(mktemp -d /tmp/dhake-ve-o.XXXXXX)"
    zdir="$(mktemp -d /tmp/dhake-ve-z.XXXXXX)"
    # materialize build.dhall in each scratch dir, applying $VAR substitution if any
    if [ -n "$sub" ]; then
        key="${sub%%=*}"; val="${sub#*=}"
        sed "s/\\\$$key/$val/g" "$src" > "$odir/build.dhall"
        sed "s/\\\$$key/$val/g" "$src" > "$zdir/build.dhall"
    else
        cp "$src" "$odir/build.dhall"
        cp "$src" "$zdir/build.dhall"
    fi
    run_bin "$ORACLE_ABS" "$odir" "$mode" "$seed"
    run_bin "$ZIG_ABS" "$zdir" "$mode" "$seed"
    ok=1
    orc=$(cat "$odir/rc.txt"); zrc=$(cat "$zdir/rc.txt")
    if [ "$orc" -ne "$zrc" ]; then echo "RC MISMATCH ve-$name: oracle=$orc zig=$zrc"; ok=0; fi
    cmp -s "$odir/out.txt" "$zdir/out.txt" || { echo "STDOUT MISMATCH ve-$name"; ok=0; }
    cmp -s "$odir/err.txt" "$zdir/err.txt" || { echo "STDERR MISMATCH ve-$name"; ok=0; }
    if [ "$ok" -eq 1 ]; then
        echo "PASS ve-$name"
    else
        vxfail=$((vxfail + 1))
        echo "FAIL ve-$name"
    fi
    rm -rf "$odir" "$zdir"
}

# hash pins used by the verified-target corpus files (content exactly as the recipes
# write them), so both binaries see the same declared hashes.
HASH_V1=$(printf 'verify-v1-content' | sha256sum | cut -d' ' -f1)
HASH_V4=$(printf 'original-output\n' | sha256sum | cut -d' ' -f1)

# --verify: missing output => needs rebuild (rc nonzero)
ve_case verify-needs-rebuild "zig/tests/corpus/c041_build_verify_v2.dhall" "--verify" "" ""
# --verify: recipe must NOT have run (no output produced)
ve_case verify-no-recipe-run "zig/tests/corpus/c044_build_verify_v5.dhall" "--verify" "" ""
# --verify: build then verify clean up-to-date (rc 0)
ve_case verify-clean "zig/tests/corpus/c040_build_verify_v1.dhall" "--verify" "HASH_V1=$HASH_V1" '$bin -f build.dhall >/dev/null 2>&1'
# --verify: build then tamper output => output hash mismatch (rc nonzero)
ve_case verify-output-tampered "zig/tests/corpus/c043_build_verify_v4.dhall" "--verify" "HASH_V4=$HASH_V4" '$bin -f build.dhall >/dev/null 2>&1; printf "tampered-output\n" > verify_v4.txt; touch -d "2020-01-01" verify_v4.txt'
# --explain: missing output => needs rebuild (rc nonzero)
ve_case explain-missing-output "zig/tests/corpus/c048_build_explain_e1.dhall" "--explain" "" ""
# --explain: build then explain clean up-to-date (rc 0)
ve_case explain-clean "zig/tests/corpus/c049_build_explain_e2.dhall" "--explain" "" '$bin -f build.dhall >/dev/null 2>&1'
# --explain: phony target always needs rebuild (rc nonzero)
ve_case explain-phony "zig/tests/corpus/c051_build_explain_e4.dhall" "--explain" "" ""

echo "LAYER 1c verify/explain: $vxtotal ran, $((vxtotal - vxfail)) passed, $vxfail failed"
fail=$((fail + vxfail))

# ---- LAYER 2: tests/build.sh parity vs BASELINE ----
echo "LAYER 2: run: bash tests/build.sh $ZIG"
echo "  must equal: $(grep -c '^PASS' zig/BASELINE.txt) passed / $(grep -c '^FAIL' zig/BASELINE.txt) failed"

if [ "$fail" -eq 0 ]; then
    echo "ALL PASS"
else
    exit 1
fi
