#!/bin/sh
# Test harness for dhake (dhake.c).
# usage: tests/build.sh [dhake-binary]   (default: ./dhake.com.dbg)
#
# Runs end-to-end verification cases in a scratch directory.
set -u

BIN="${1:-./dhake.com.dbg}"
case "$BIN" in
    /*) : ;;
    *) BIN="$(pwd)/$BIN" ;;
esac

# All test work happens in a scratch directory
SCRATCH="$(mktemp -d /tmp/dhake-test.XXXXXX)"
trap "rm -rf '$SCRATCH'" EXIT

cd "$SCRATCH"

pass=0
fail=0

check() {
    name="$1"
    ok="$2"
    if [ "$ok" -eq 1 ]; then
        pass=$((pass + 1))
        echo "PASS $name"
    else
        fail=$((fail + 1))
        echo "FAIL $name"
    fi
}

# Helper: write a file
write_file() {
    path="$1"
    content="$2"
    printf '%s\n' "$content" > "$path"
}

# ---- Case 1: End-to-end build of hello.c via build.dhall ----
# Create hello.c
write_file hello.c '#include <stdio.h>
int main(void) { return puts("Hello, World!"); }'

# Create build.dhall (same as the reference)
cat > build.dhall <<'BUILDEOF'
let Action =
  < Shell : Text
  | Copy  : { from : Text, to : Text }
  | Mkdir : Text
  | Rm    : Text
  | Touch : Text
  >

let Target = { deps : List Text, phony : Bool, recipe : List Action }

in  { targets =
        [ { mapKey = "hello"
          , mapValue =
              { deps = [ "hello.c" ], phony = False
              , recipe = [ < Shell = "cc -o hello hello.c" > ]
              }
          }
        , { mapKey = "clean"
          , mapValue =
              { deps = [] : List Text, phony = True
              , recipe = [ < Rm = "hello" > ]
              }
          }
        ]
    , default = "hello"
    }
BUILDEOF

# Run dhake (should build hello)
"$BIN" > /tmp/dhake-out.txt 2> /tmp/dhake-err.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
# Check that cc was invoked (output should contain the cc command)
grep -q 'cc -o hello hello.c' /tmp/dhake-out.txt || { echo "  cc command not found in output"; ok=0; }
# Check that hello exists and runs
[ -x ./hello ] || { echo "  hello binary not created"; ok=0; }
./hello > /tmp/hello-out.txt 2>&1
[ "$rc" -eq 0 ] || { echo "  hello exited nonzero"; ok=0; }
grep -q 'Hello, World!' /tmp/hello-out.txt || { echo "  hello output incorrect"; ok=0; }
check "end-to-end-build" "$ok"

# ---- Case 2: Incremental skip (second run up-to-date) ----
# Run again immediately - should be up to date
"$BIN" > /tmp/dhake-out2.txt 2> /tmp/dhake-err2.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
grep -q "'hello' is up to date" /tmp/dhake-out2.txt || { echo "  up-to-date message not found"; ok=0; }
# cc should NOT be invoked again
grep -q 'cc -o hello hello.c' /tmp/dhake-out2.txt && { echo "  cc should not have been invoked (incremental)"; ok=0; }
check "incremental-skip" "$ok"

# ---- Case 3: Staleness rebuild after editing source ----
# Modify hello.c - use echo to ensure different content and mtime
sleep 1
echo '#include <stdio.h>' > hello.c
echo 'int main(void) { return puts("Hello, World! Modified!"); }' >> hello.c

# Run again - should recompile
"$BIN" > /tmp/dhake-out3.txt 2> /tmp/dhake-err3.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
grep -q 'cc -o hello hello.c' /tmp/dhake-out3.txt || { echo "  cc command not found (should rebuild)"; ok=0; }
# Verify new output
./hello > /tmp/hello-out3.txt 2>&1
grep -q 'Hello, World! Modified!' /tmp/hello-out3.txt || { echo "  hello output not updated"; ok=0; }
check "staleness-rebuild" "$ok"

# ---- Case 4: Phony clean always runs ----
# hello exists and is fresh, but clean is phony so it should still run
"$BIN" clean > /tmp/dhake-out4.txt 2> /tmp/dhake-err4.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
grep -q 'rm hello' /tmp/dhake-out4.txt || { echo "  rm hello not found in output"; ok=0; }
[ ! -x ./hello ] || { echo "  hello should have been removed"; ok=0; }
check "phony-clean" "$ok"

# Run clean again - phony should still run
"$BIN" clean > /tmp/dhake-out4b.txt 2> /tmp/dhake-err4b.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
grep -q 'rm hello' /tmp/dhake-out4b.txt || { echo "  rm hello not found (phony should always run)"; ok=0; }
check "phony-always-runs" "$ok"

# ---- Case 5: Failing recipe exit code propagation ----
# Create a buildfile with a failing recipe
cat > build_fail.dhall <<'BUILDEOF'
let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { targets = [ { mapKey = "fail", mapValue = { deps = [] : List Text, phony = False, recipe = [ < Shell = "exit 7" > ] } } ], default = "fail" }
BUILDEOF

"$BIN" -f build_fail.dhall > /tmp/dhake-out5.txt 2> /tmp/dhake-err5.txt
rc=$?
ok=1
[ "$rc" -eq 7 ] || { echo "  expected exit 7, got $rc"; ok=0; }
check "failing-recipe-exit7" "$ok"

# ---- Case 6: Dependency cycle detection ----
cat > build_cycle.dhall <<'BUILDEOF'
let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { targets = [ { mapKey = "a", mapValue = { deps = ["b"], phony = False, recipe = [ < Shell = "touch a" > ] } }, { mapKey = "b", mapValue = { deps = ["a"], phony = False, recipe = [ < Shell = "touch b" > ] } } ], default = "a" }
BUILDEOF

"$BIN" -f build_cycle.dhall > /tmp/dhake-out6.txt 2> /tmp/dhake-err6.txt
rc=$?
ok=1
[ "$rc" -eq 2 ] || { echo "  expected exit 2, got $rc"; ok=0; }
grep -q 'dependency cycle detected' /tmp/dhake-err6.txt || { echo "  cycle detection message not found"; ok=0; }
check "cycle-detection" "$ok"

# ---- Case 7: Dry-run -n leaves files ----
# Recreate hello.c and hello
write_file hello.c '#include <stdio.h>
int main(void) { return 0; }'
# Build hello first so it exists
cc -o hello hello.c 2>/dev/null || true

"$BIN" -n clean > /tmp/dhake-out7.txt 2> /tmp/dhake-err7.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
grep -q 'rm hello' /tmp/dhake-out7.txt || { echo "  rm hello not found in dry-run output"; ok=0; }
[ -f ./hello ] || { echo "  hello should still exist after dry-run"; ok=0; }
check "dry-run-leaves-files" "$ok"

# ---- Case 8: --list ----
"$BIN" -f build.dhall --list > /tmp/dhake-out8.txt 2> /tmp/dhake-err8.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
grep -q 'hello' /tmp/dhake-out8.txt || { echo "  hello target not in list"; ok=0; }
grep -q 'clean' /tmp/dhake-out8.txt || { echo "  clean target not in list"; ok=0; }
grep -q '(default)' /tmp/dhake-out8.txt || { echo "  default marker not found"; ok=0; }
check "list-targets" "$ok"

# ---- Case 9: Missing source file -> 'no rule to make target' ----
# Remove hello.c but keep the buildfile that depends on it
rm -f hello.c

"$BIN" > /tmp/dhake-out9.txt 2> /tmp/dhake-err9.txt
rc=$?
ok=1
[ "$rc" -eq 2 ] || { echo "  expected exit 2, got $rc"; ok=0; }
grep -q "no rule to make target 'hello.c'" /tmp/dhake-err9.txt || { echo "  missing source error message not found"; ok=0; }
check "missing-source-file" "$ok"

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
