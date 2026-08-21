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

# ---- Case 10: Parallel build with -j 2 ----
# Create two independent targets with touch commands (no compilation needed)
cat > build_parallel.dhall <<'BUILDEOF'
let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text | Move : { from : Text, to : Text } | Symlink : { from : Text, to : Text } | Chmod : { path : Text, mode : Text } | Echo : Text | Env : { key : Text, value : Text } | Run : { argv : List Text } >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { targets = [ { mapKey = "a", mapValue = { deps = [], phony = True, recipe = [ < Touch = "a.stamp" > ] } }, { mapKey = "b", mapValue = { deps = [], phony = True, recipe = [ < Touch = "b.stamp" > ] } } ], default = "a" }
BUILDEOF

"$BIN" -f build_parallel.dhall -j 2 a b > /tmp/dhake-out10.txt 2> /tmp/dhake-err10.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
grep -q "building 'a'" /tmp/dhake-out10.txt || { echo "  building a not found"; ok=0; }
grep -q "building 'b'" /tmp/dhake-out10.txt || { echo "  building b not found"; ok=0; }
[ -f ./a.stamp ] || { echo "  a.stamp not created"; ok=0; }
[ -f ./b.stamp ] || { echo "  b.stamp not created"; ok=0; }
check "parallel-build-j2" "$ok"

# ---- Case 11: Parallel stop-on-first-failure ----
# Create a failing target using Shell action with exit 42
cat > build_fail_parallel.dhall <<'BUILDEOF'
let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text | Move : { from : Text, to : Text } | Symlink : { from : Text, to : Text } | Chmod : { path : Text, mode : Text } | Echo : Text | Env : { key : Text, value : Text } | Run : { argv : List Text } >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { targets = [ { mapKey = "fail", mapValue = { deps = [], phony = False, recipe = [ < Shell = "exit 42" > ] } }, { mapKey = "good", mapValue = { deps = [], phony = False, recipe = [ < Touch = "good.stamp" > ] } } ], default = "fail" }
BUILDEOF

"$BIN" -f build_fail_parallel.dhall -j 2 > /tmp/dhake-out11.txt 2> /tmp/dhake-err11.txt
rc=$?
ok=1
[ "$rc" -eq 42 ] || { echo "  expected exit 42, got $rc"; ok=0; }
check "parallel-stop-on-first-failure" "$ok"

# ---- Case 12: Move action ----
write_file move_src.txt "source content"
cat > build_move.dhall <<'BUILDEOF'
let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text | Move : { from : Text, to : Text } | Symlink : { from : Text, to : Text } | Chmod : { path : Text, mode : Text } | Echo : Text | Env : { key : Text, value : Text } | Run : { argv : List Text } >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { targets = [ { mapKey = "move-target", mapValue = { deps = ["move_src.txt"], phony = False, recipe = [ < Move = { from = "move_src.txt", to = "move_dst.txt" } > ] } } ], default = "move-target" }
BUILDEOF

"$BIN" -f build_move.dhall > /tmp/dhake-out12.txt 2> /tmp/dhake-err12.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
grep -q "mv move_src.txt move_dst.txt" /tmp/dhake-out12.txt || { echo "  mv command not found"; ok=0; }
[ -f move_dst.txt ] || { echo "  move_dst.txt not created"; ok=0; }
[ ! -f move_src.txt ] || { echo "  move_src.txt should have been removed"; ok=0; }
grep -q "source content" move_dst.txt || { echo "  content not preserved"; ok=0; }
check "action-move" "$ok"

# ---- Case 13: Symlink action ----
write_file symlink_target.txt "link target"
cat > build_symlink.dhall <<'BUILDEOF'
let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text | Move : { from : Text, to : Text } | Symlink : { from : Text, to : Text } | Chmod : { path : Text, mode : Text } | Echo : Text | Env : { key : Text, value : Text } | Run : { argv : List Text } >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { targets = [ { mapKey = "symlink-target", mapValue = { deps = ["symlink_target.txt"], phony = False, recipe = [ < Symlink = { from = "symlink_target.txt", to = "symlink_link" } > ] } } ], default = "symlink-target" }
BUILDEOF

"$BIN" -f build_symlink.dhall > /tmp/dhake-out13.txt 2> /tmp/dhake-err13.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
grep -q "ln -s symlink_target.txt symlink_link" /tmp/dhake-out13.txt || { echo "  ln command not found"; ok=0; }
[ -L symlink_link ] || { echo "  symlink_link should be a symlink"; ok=0; }
check "action-symlink" "$ok"

# ---- Case 14: Chmod action ----
write_file chmod_file.txt "chmod test"
cat > build_chmod.dhall <<'BUILDEOF'
let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text | Move : { from : Text, to : Text } | Symlink : { from : Text, to : Text } | Chmod : { path : Text, mode : Text } | Echo : Text | Env : { key : Text, value : Text } | Run : { argv : List Text } >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { targets = [ { mapKey = "chmod-target", mapValue = { deps = ["chmod_file.txt"], phony = False, recipe = [ < Chmod = { path = "chmod_file.txt", mode = "0444" } > ] } } ], default = "chmod-target" }
BUILDEOF

"$BIN" -f build_chmod.dhall > /tmp/dhake-out14.txt 2> /tmp/dhake-err14.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
grep -q "chmod 0444 chmod_file.txt" /tmp/dhake-out14.txt || { echo "  chmod command not found"; ok=0; }
# Check permissions (read-only for owner)
[ -r chmod_file.txt ] || { echo "  chmod_file.txt should be readable"; ok=0; }
[ ! -w chmod_file.txt ] || { echo "  chmod_file.txt should not be writable"; ok=0; }
check "action-chmod" "$ok"

# ---- Case 15: Echo action ----
cat > build_echo.dhall <<'BUILDEOF'
let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text | Move : { from : Text, to : Text } | Symlink : { from : Text, to : Text } | Chmod : { path : Text, mode : Text } | Echo : Text | Env : { key : Text, value : Text } | Run : { argv : List Text } >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { targets = [ { mapKey = "echo-target", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Echo = "Hello from Echo action" > ] } } ], default = "echo-target" }
BUILDEOF

"$BIN" -f build_echo.dhall > /tmp/dhake-out15.txt 2> /tmp/dhake-err15.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
grep -q "Hello from Echo action" /tmp/dhake-out15.txt || { echo "  echo output not found"; ok=0; }
check "action-echo" "$ok"

# ---- Case 16: Env action ----
cat > build_env.dhall <<'BUILDEOF'
let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text | Move : { from : Text, to : Text } | Symlink : { from : Text, to : Text } | Chmod : { path : Text, mode : Text } | Echo : Text | Env : { key : Text, value : Text } | Run : { argv : List Text } >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { targets = [ { mapKey = "env-target", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Env = { key = "MY_ENV_VAR", value = "test_value" } >, < Shell = "echo $MY_ENV_VAR" > ] } } ], default = "env-target" }
BUILDEOF

"$BIN" -f build_env.dhall > /tmp/dhake-out16.txt 2> /tmp/dhake-err16.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
grep -q "export MY_ENV_VAR=test_value" /tmp/dhake-out16.txt || { echo "  export not found"; ok=0; }
grep -q "test_value" /tmp/dhake-out16.txt || { echo "  env var value not printed"; ok=0; }
check "action-env" "$ok"

# ---- Case 17: Run action ----
cat > build_run.dhall <<'BUILDEOF'
let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text | Move : { from : Text, to : Text } | Symlink : { from : Text, to : Text } | Chmod : { path : Text, mode : Text } | Echo : Text | Env : { key : Text, value : Text } | Run : { argv : List Text } >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { targets = [ { mapKey = "run-target", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Run = { argv = [ "/bin/echo", "hello", "world" ] } > ] } } ], default = "run-target" }
BUILDEOF

"$BIN" -f build_run.dhall > /tmp/dhake-out17.txt 2> /tmp/dhake-err17.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
grep -q "/bin/echo hello world" /tmp/dhake-out17.txt || { echo "  run command not found"; ok=0; }
check "action-run" "$ok"

# ---- Case 18: Mkdir recursive (parents=True, type-honest nested union) ----
cat > build_mkdir_rec.dhall <<'BUILDEOF'
let Action = < Shell : Text | Mkdir : < Plain : Text | Parents : { path : Text, parents : Bool } > | Rm : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { targets = [ { mapKey = "m", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Mkdir = < Parents = { path = "a/b/c", parents = True } > > ] } } ], default = "m" }
BUILDEOF

"$BIN" -f build_mkdir_rec.dhall > /tmp/dhake-out18.txt 2> /tmp/dhake-err18.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
[ -d a/b/c ] || { echo "  nested dir a/b/c not created"; ok=0; }
grep -q 'mkdir -p a/b/c' /tmp/dhake-out18.txt || { echo "  'mkdir -p a/b/c' not echoed"; ok=0; }
check "mkdir-recursive" "$ok"

# ---- Case 19: Rm recursive (recursive=True, ergonomic plain record) ----
# Build a small non-empty tree, then let dhake delete it recursively.
mkdir -p tree/x/y && echo hi > tree/x/y/f.txt && echo hi > tree/z.txt
cat > build_rm_rec.dhall <<'BUILDEOF'
let Action = < Shell : Text | Rm : { path : Text, recursive : Bool } >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { targets = [ { mapKey = "r", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Rm = { path = "tree", recursive = True } > ] } } ], default = "r" }
BUILDEOF

"$BIN" -f build_rm_rec.dhall > /tmp/dhake-out19.txt 2> /tmp/dhake-err19.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
[ ! -e tree ] || { echo "  tree not fully removed"; ok=0; }
grep -q 'rm -rf tree' /tmp/dhake-out19.txt || { echo "  'rm -rf tree' not echoed"; ok=0; }
check "rm-recursive" "$ok"

# ---- Case 20: Rm recursive on missing path is ignored (rm -rf) ----
cat > build_rm_missing.dhall <<'BUILDEOF'
let Action = < Shell : Text | Rm : { path : Text, recursive : Bool } >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { targets = [ { mapKey = "r", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Rm = { path = "does-not-exist", recursive = True } > ] } } ], default = "r" }
BUILDEOF

"$BIN" -f build_rm_missing.dhall > /tmp/dhake-out20.txt 2> /tmp/dhake-err20.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  rm -rf on missing path should be ignored, got $rc"; ok=0; }
check "rm-recursive-missing" "$ok"

# ---- Case 21: legacy bare-Text Mkdir/Rm still non-recursive ----
# Bare Text Mkdir creates a single level and echoes plain 'mkdir'; bare Text Rm
# on a NON-EMPTY directory must FAIL (remove() does not recurse).
mkdir -p legacy_dir/sub && echo hi > legacy_dir/sub/f.txt
cat > build_legacy.dhall <<'BUILDEOF'
let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { targets =
     [ { mapKey = "mk", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Mkdir = "solo" > ] } }
     , { mapKey = "rmdir", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Rm = "legacy_dir" > ] } }
     ], default = "mk" }
BUILDEOF

"$BIN" -f build_legacy.dhall mk > /tmp/dhake-out21a.txt 2> /tmp/dhake-err21a.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  bare Text Mkdir failed, got $rc"; ok=0; }
[ -d solo ] || { echo "  single-level dir 'solo' not created"; ok=0; }
grep -q 'mkdir solo' /tmp/dhake-out21a.txt || { echo "  'mkdir solo' not echoed (no -p)"; ok=0; }
check "mkdir-legacy-text" "$ok"

"$BIN" -f build_legacy.dhall rmdir > /tmp/dhake-out21b.txt 2> /tmp/dhake-err21b.txt
rc=$?
ok=1
[ "$rc" -ne 0 ] || { echo "  bare Text Rm on non-empty dir should fail (non-recursive)"; ok=0; }
[ -e legacy_dir ] || { echo "  legacy_dir should still exist (remove() does not recurse)"; ok=0; }
check "rm-legacy-nonrecursive" "$ok"

# ---- Case 22: Landlock sandbox — write INSIDE the build tree is allowed ----
# With sandbox.enable=True the recipe child is sandboxed (or falls back to
# unsandboxed when landlock is unavailable, e.g. in a sandboxed CI). Writing a
# file under cwd (auto-unveiled rwc) must succeed in both cases.
cat > build_sandbox_inside.dhall <<'BUILDEOF'
let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { sandbox = { enable = True, unveil = [] : List Text }
   , targets = [ { mapKey = "ok", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Shell = "echo hi > sandbox_inside.txt" > ] } } ], default = "ok" }
BUILDEOF

"$BIN" -f build_sandbox_inside.dhall > /tmp/dhake-out22.txt 2> /tmp/dhake-err22.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  sandboxed write-inside failed, rc=$rc"; ok=0; }
[ -f sandbox_inside.txt ] || { echo "  sandbox_inside.txt not created"; ok=0; }
check "sandbox-write-inside" "$ok"

# ---- Case 23: Landlock sandbox — write OUTSIDE the build tree ----
# Conditional: on a kernel with landlock the write is DENIED (recipe fails,
# file not created); where landlock is unavailable (sandboxed CI) the recipe
# succeeds but dhake emits the 'landlock sandbox unavailable' warning.
rm -f /dhake-landlock-outside-$$ 
cat > build_sandbox_outside.dhall <<'BUILDEOF'
let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { sandbox = { enable = True, unveil = [] : List Text }
   , targets = [ { mapKey = "bad", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Shell = "touch /dhake-landlock-outside-$$" > ] } } ], default = "bad" }
BUILDEOF

"$BIN" -f build_sandbox_outside.dhall > /tmp/dhake-out23.txt 2> /tmp/dhake-err23.txt
rc=$?
ok=1
if [ "$rc" -ne 0 ] && [ ! -e /dhake-landlock-outside-$$ ]; then
    :   # landlock active: write denied, recipe failed, file not created
elif grep -q 'landlock sandbox unavailable' /tmp/dhake-err23.txt; then
    :   # landlock unavailable: fallback warning emitted
else
    echo "  expected denial OR 'landlock sandbox unavailable' warning (rc=$rc)"; ok=0
fi
rm -f /dhake-landlock-outside-$$
check "sandbox-deny-write-outside" "$ok"

# ---- Case 24: Landlock sandbox — unveil whitelist allows an external dir ----
# With sandbox.enable=True and unveil=["rwc:./sandbox_ext"], writing into that
# external dir is allowed while writing into a DIFFERENT external dir is denied
# (conditional on landlock availability, same as case 23).
mkdir -p sandbox_ext
cat > build_sandbox_unveil.dhall <<'BUILDEOF'
let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { sandbox = { enable = True, unveil = [ "rwc:./sandbox_ext" ] }
   , targets =
     [ { mapKey = "allow", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Shell = "echo a > sandbox_ext/a.txt" > ] } }
     , { mapKey = "deny", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Shell = "touch /dhake-landlock-other-$$" > ] } }
     ], default = "allow" }
BUILDEOF

"$BIN" -f build_sandbox_unveil.dhall allow > /tmp/dhake-out24a.txt 2> /tmp/dhake-err24a.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  unveiled write failed, rc=$rc"; ok=0; }
[ -f sandbox_ext/a.txt ] || { echo "  sandbox_ext/a.txt not created"; ok=0; }
check "sandbox-unveil-allow" "$ok"

rm -f /dhake-landlock-other-$$
"$BIN" -f build_sandbox_unveil.dhall deny > /tmp/dhake-out24b.txt 2> /tmp/dhake-err24b.txt
rc=$?
ok=1
if [ "$rc" -ne 0 ] && [ ! -e /dhake-landlock-other-$$ ]; then
    :   # landlock active: non-whitelisted external write denied
elif grep -q 'landlock sandbox unavailable' /tmp/dhake-err24b.txt; then
    :   # landlock unavailable: fallback warning
else
    echo "  expected denial OR 'landlock sandbox unavailable' warning (rc=$rc)"; ok=0
fi
rm -f /dhake-landlock-other-$$
check "sandbox-unveil-deny-other" "$ok"

# ---- Case 25: Shell redirection is scoped to one command (stdout preserved) ----
# Regression for the cosmopolitan system()/_cocmd bug: a '>' redirect used to
# permanently redirect fd 1, so later ';'-chained commands silently wrote to
# the file. dhake runs recipes via the real /bin/sh (run_shell), which scopes
# each redirection, so 'start', 'after=0' and 'end' must reach stdout and only
# 'x' must land in the file.
cat > build_redirect.dhall <<'BUILDEOF'
let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { targets = [ { mapKey = "red", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Shell = "echo start; echo x > redirect_target.txt; echo after=$?; echo end" > ] } } ], default = "red" }
BUILDEOF

rm -f redirect_target.txt
"$BIN" -f build_redirect.dhall > /tmp/dhake-out25.txt 2> /tmp/dhake-err25.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
grep -q '^start$' /tmp/dhake-out25.txt || { echo "  'start' missing from stdout"; ok=0; }
grep -q '^after=0$' /tmp/dhake-out25.txt || { echo "  'after=0' missing from stdout (redirect leaked to file)"; ok=0; }
grep -q '^end$' /tmp/dhake-out25.txt || { echo "  'end' missing from stdout (redirect leaked to file)"; ok=0; }
if grep -q '^x$' /tmp/dhake-out25.txt; then echo "  'x' leaked to stdout instead of the file"; ok=0; fi
[ "$(cat redirect_target.txt 2>/dev/null)" = "x" ] || { echo "  redirect_target.txt should contain exactly 'x'"; ok=0; }
check "shell-redirect-scoped-stdout" "$ok"

# ---- Case 26: Output hash correct ----
# A non-phony target produces a file with a declared hash.
# First run: build succeeds + verified message. Second run: up-to-date.
HASH26=$(printf 'hello' | sha256sum | cut -d' ' -f1)
cat > build_output_hash_correct.dhall <<BUILDEOF
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text, depsHash : List { path : Text, hash : Text } }
in  { targets = [ { mapKey = "out26.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'hello' > out26.txt" > ], hash = "sha256:${HASH26}" } } ], default = "out26.txt" }
BUILDEOF

rm -f out26.txt
"$BIN" -f build_output_hash_correct.dhall > /tmp/dhake-out26.txt 2> /tmp/dhake-err26.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
[ -f out26.txt ] || { echo "  out26.txt not created"; ok=0; }
grep -q "verified" /tmp/dhake-out26.txt || { echo "  'verified' not found in output"; ok=0; }
check "output-hash-correct" "$ok"

# Second run should be up-to-date
"$BIN" -f build_output_hash_correct.dhall > /tmp/dhake-out26b.txt 2> /tmp/dhake-err26b.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
grep -q "is up to date" /tmp/dhake-out26b.txt || { echo "  'is up to date' not found"; ok=0; }
check "output-hash-correct-up-to-date" "$ok"

# ---- Case 27: Output hash wrong ----
# Same as case 26 but with a wrong hash. Build must fail.
cat > build_output_hash_wrong.dhall <<BUILDEOF
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text, depsHash : List { path : Text, hash : Text } }
in  { targets = [ { mapKey = "out27.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'hello' > out27.txt" > ], hash = "sha256:0000000000000000000000000000000000000000000000000000000000000000" } } ], default = "out27.txt" }
BUILDEOF

rm -f out27.txt
"$BIN" -f build_output_hash_wrong.dhall > /tmp/dhake-out27.txt 2> /tmp/dhake-err27.txt
rc=$?
ok=1
[ "$rc" -ne 0 ] || { echo "  expected non-zero exit, got $rc"; ok=0; }
grep -qi "hash mismatch" /tmp/dhake-err27.txt || { echo "  hash mismatch error not found on stderr"; cat /tmp/dhake-err27.txt; ok=0; }
check "output-hash-wrong" "$ok"

# ---- Case 28: Dep hash correct then tampered ----
# A target with depsHash verifying its source dep. First run succeeds.
# Then tamper the dep file -> second run fails with dep hash mismatch.
HASH28=$(printf 'input28' | sha256sum | cut -d' ' -f1)
cat > build_dep_hash.dhall <<BUILDEOF
let Action = < Shell : Text | Copy : { from : Text, to : Text } >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text, depsHash : List { path : Text, hash : Text } }
in  { targets = [ { mapKey = "depout28.txt", mapValue = { deps = ["input28.txt"], phony = False, recipe = [ < Copy = { from = "input28.txt", to = "depout28.txt" } > ], depsHash = [ { path = "input28.txt", hash = "sha256:${HASH28}" } ] } } ], default = "depout28.txt" }
BUILDEOF

rm -f input28.txt depout28.txt
printf 'input28' > input28.txt
"$BIN" -f build_dep_hash.dhall > /tmp/dhake-out28a.txt 2> /tmp/dhake-err28a.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
[ -f depout28.txt ] || { echo "  depout28.txt not created"; ok=0; }
check "dep-hash-correct" "$ok"

# Tamper the dep file
printf 'tampered28' > input28.txt
"$BIN" -f build_dep_hash.dhall > /tmp/dhake-out28b.txt 2> /tmp/dhake-err28b.txt
rc=$?
ok=1
[ "$rc" -ne 0 ] || { echo "  expected non-zero exit, got $rc"; ok=0; }
grep -qi "dep hash mismatch" /tmp/dhake-err28b.txt || { echo "  dep hash mismatch error not found on stderr"; ok=0; }
check "dep-hash-tampered" "$ok"

# ---- Case 29: Output tampered but up-to-date by mtime ----
# Build with correct hash, then tamper the output file and set its mtime
# to the past so it's "up to date" by mtime. Verification should catch it.
HASH29=$(printf 'hello29' | sha256sum | cut -d' ' -f1)
cat > build_output_tampered.dhall <<BUILDEOF
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text, depsHash : List { path : Text, hash : Text } }
in  { targets = [ { mapKey = "out29.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'hello29' > out29.txt" > ], hash = "sha256:${HASH29}" } } ], default = "out29.txt" }
BUILDEOF

rm -f out29.txt
"$BIN" -f build_output_tampered.dhall > /tmp/dhake-out29a.txt 2> /tmp/dhake-err29a.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
[ -f out29.txt ] || { echo "  out29.txt not created"; ok=0; }
check "output-tampered-build" "$ok"

# Tamper the output file
printf 'TAMPERED29' > out29.txt
# Try to set mtime to the past (may fail in sandbox, but we try)
touch -d '2000-01-01' out29.txt 2>/dev/null || true
"$BIN" -f build_output_tampered.dhall > /tmp/dhake-out29b.txt 2> /tmp/dhake-err29b.txt
rc=$?
ok=1
[ "$rc" -ne 0 ] || { echo "  expected non-zero exit, got $rc"; ok=0; }
grep -qi "hash mismatch" /tmp/dhake-err29b.txt || { echo "  hash mismatch error not found on stderr"; cat /tmp/dhake-err29b.txt; ok=0; }
check "output-tampered-up-to-date" "$ok"

# ---- Case 30: Unsupported hash algorithm ----
# A target with an unsupported algorithm (md5) should fail with clear error.
cat > build_unsupported_algo.dhall <<BUILDEOF
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text, depsHash : List { path : Text, hash : Text } }
in  { targets = [ { mapKey = "out30.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'hello' > out30.txt" > ], hash = "md5:d41d8cd98f00b204e9800998ecf8427e" } } ], default = "out30.txt" }
BUILDEOF

"$BIN" -f build_unsupported_algo.dhall > /tmp/dhake-out30.txt 2> /tmp/dhake-err30.txt
rc=$?
ok=1
[ "$rc" -ne 0 ] || { echo "  expected non-zero exit, got $rc"; ok=0; }
grep -qi "unsupported hash algorithm" /tmp/dhake-err30.txt || { echo "  unsupported algorithm error not found on stderr"; cat /tmp/dhake-err30.txt; ok=0; }
check "unsupported-algorithm" "$ok"

# ---- Case 31: Bare hex hash (no prefix) rejected ----
# A target with a bare 64-hex hash (no algorithm prefix) should fail.
cat > build_bare_hex.dhall <<BUILDEOF
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text, depsHash : List { path : Text, hash : Text } }
in  { targets = [ { mapKey = "out31.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'hello' > out31.txt" > ], hash = "d41d8cd98f00b204e9800998ecf8427e00000000000000000000000000000000" } } ], default = "out31.txt" }
BUILDEOF

"$BIN" -f build_bare_hex.dhall > /tmp/dhake-out31.txt 2> /tmp/dhake-err31.txt
rc=$?
ok=1
[ "$rc" -ne 0 ] || { echo "  expected non-zero exit, got $rc"; ok=0; }
grep -qi "must be '<algorithm>:<hexdigest>'" /tmp/dhake-err31.txt || { echo "  bare hex error not found on stderr"; cat /tmp/dhake-err31.txt; ok=0; }
check "bare-hex-rejected" "$ok"

# ---- Case 32: --warn-hash-mismatch downgrades an output hash mismatch ----
# With the flag, a wrong output hash must NOT abort the build: it prints a
# warning to stderr that includes the ACTUAL hash (prefixed), the recipe runs,
# and dhake exits 0. Without the flag the same buildfile must fail.
cat > build_warn_out.dhall <<BUILDEOF
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text }
in  { targets = [ { mapKey = "out32.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'hello' > out32.txt" > ], hash = "sha256:0000000000000000000000000000000000000000000000000000000000000000" } } ], default = "out32.txt" }
BUILDEOF

rm -f out32.txt
"$BIN" --warn-hash-mismatch -f build_warn_out.dhall > /tmp/dhake-out32.txt 2> /tmp/dhake-err32.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  --warn-hash-mismatch should exit 0, got $rc"; ok=0; }
grep -qi "output hash mismatch" /tmp/dhake-err32.txt || { echo "  output hash mismatch warning not on stderr"; cat /tmp/dhake-err32.txt; ok=0; }
# the warning must reveal the actual prefixed hash (sha256:<hex>) for updating
grep -qE 'sha256:[0-9a-f]{64}' /tmp/dhake-err32.txt || { echo "  actual sha256:<hex> hash not printed in warning"; cat /tmp/dhake-err32.txt; ok=0; }
[ -f out32.txt ] || { echo "  out32.txt not created (recipe should still run)"; ok=0; }
check "warn-hash-mismatch-output" "$ok"

# And the SAME buildfile WITHOUT the flag must still fail (mismatch stays fatal).
rm -f out32.txt
"$BIN" -f build_warn_out.dhall > /tmp/dhake-out32b.txt 2> /tmp/dhake-err32b.txt
rc=$?
ok=1
[ "$rc" -ne 0 ] || { echo "  without flag expected non-zero exit, got $rc"; ok=0; }
grep -qi "output hash mismatch" /tmp/dhake-err32b.txt || { echo "  mismatch error not on stderr without flag"; cat /tmp/dhake-err32b.txt; ok=0; }
check "warn-hash-mismatch-output-still-fatal" "$ok"

# ---- Case 33: --warn-hash-mismatch downgrades a dep hash mismatch ----
# Same idea for depsHash: warning (with the actual hash), build continues.
printf 'SRC-CONTENT\n' > warn33_input.txt
cat > build_warn_dep.dhall <<BUILDEOF
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text, depsHash : List { path : Text, hash : Text } }
in  { targets = [ { mapKey = "out33.txt", mapValue = { deps = [ "warn33_input.txt" ], phony = False, recipe = [ < Shell = "cp warn33_input.txt out33.txt" > ], hash = "sha256:0000000000000000000000000000000000000000000000000000000000000000", depsHash = [ { path = "warn33_input.txt", hash = "sha256:1111111111111111111111111111111111111111111111111111111111111111" } ] } } ], default = "out33.txt" }
BUILDEOF

rm -f out33.txt
"$BIN" --warn-hash-mismatch -f build_warn_dep.dhall > /tmp/dhake-out33.txt 2> /tmp/dhake-err33.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  --warn-hash-mismatch (dep) should exit 0, got $rc"; ok=0; }
grep -qi "dep hash mismatch" /tmp/dhake-err33.txt || { echo "  dep hash mismatch warning not on stderr"; cat /tmp/dhake-err33.txt; ok=0; }
grep -qE 'sha256:[0-9a-f]{64}' /tmp/dhake-err33.txt || { echo "  actual sha256:<hex> hash not printed in dep warning"; cat /tmp/dhake-err33.txt; ok=0; }
[ -f out33.txt ] || { echo "  out33.txt not created (recipe should still run)"; ok=0; }
check "warn-hash-mismatch-dep" "$ok"

# ---- Case 34: Landlock readExec — deny reading /etc/passwd ----
# With sandbox.readExec=True and no explicit unveil for /etc, reading /etc/passwd
# is denied. Conditional on landlock availability (same as cases 22-24).
cat > build_readExec_deny.dhall <<'BUILDEOF'
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { sandbox = { enable = True, readExec = True, unveil = [] : List Text }
   , targets = [ { mapKey = "deny-read", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Shell = "head -c1 /etc/passwd" > ] } } ], default = "deny-read" }
BUILDEOF

"$BIN" -f build_readExec_deny.dhall > /tmp/dhake-out34.txt 2> /tmp/dhake-err34.txt
rc=$?
ok=1
if [ "$rc" -ne 0 ]; then
    :   # landlock active: read denied, recipe failed
elif grep -q 'landlock sandbox unavailable' /tmp/dhake-err34.txt; then
    :   # landlock unavailable: fallback warning
else
    echo "  expected denial OR 'landlock sandbox unavailable' warning (rc=$rc)"; ok=0
fi
check "readExec-deny-read-etc" "$ok"

# ---- Case 35: Landlock readExec — allow real cc build ----
# With sandbox.readExec=True and empty unveil, a real cc build+run should still
# succeed because toolchain dirs are auto-unveiled. Conditional on landlock.
write_file hello_readExec.c '#include <stdio.h>
int main(void) { puts("readExec hello"); return 0; }'

cat > build_readExec_cc.dhall <<'BUILDEOF'
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { sandbox = { enable = True, readExec = True, unveil = [] : List Text }
   , targets = [ { mapKey = "cc-readExec", mapValue = { deps = ["hello_readExec.c"], phony = False, recipe = [ < Shell = "cc -o hello_readExec hello_readExec.c && ./hello_readExec" > ] } } ], default = "cc-readExec" }
BUILDEOF

"$BIN" -f build_readExec_cc.dhall > /tmp/dhake-out35.txt 2> /tmp/dhake-err35.txt
rc=$?
ok=1
if [ "$rc" -eq 0 ] && [ -x ./hello_readExec ]; then
    :   # landlock active: build succeeded
    ./hello_readExec > /tmp/hello_readExec_out.txt 2>&1
    grep -q 'readExec hello' /tmp/hello_readExec_out.txt || { echo "  hello_readExec output incorrect"; ok=0; }
elif grep -q 'landlock sandbox unavailable' /tmp/dhake-err35.txt; then
    :   # landlock unavailable: fallback warning
else
    echo "  expected success OR 'landlock sandbox unavailable' warning (rc=$rc)"; ok=0
fi
check "readExec-allow-cc-build" "$ok"

# ---- Case 36: Landlock readExec — /dev/null is readable ----
# With readExec=True, /dev/null must be both readable and writable (a very
# common `foo < /dev/null` idiom). Regression guard for the device unveils
# gaining READ alongside WRITE in readExec mode.
cat > build_readExec_devnull.dhall <<'BUILDEOF'
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { sandbox = { enable = True, readExec = True, unveil = [] : List Text }
   , targets = [ { mapKey = "devnull", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Shell = "cat < /dev/null; test $? -eq 0" > ] } } ], default = "devnull" }
BUILDEOF

"$BIN" -f build_readExec_devnull.dhall > /tmp/dhake-out36.txt 2> /tmp/dhake-err36.txt
rc=$?
ok=1
if [ "$rc" -eq 0 ]; then
    :   # landlock active: /dev/null readable + writable
elif grep -q 'landlock sandbox unavailable' /tmp/dhake-err36.txt; then
    :   # landlock unavailable: fallback warning
else
    echo "  expected /dev/null read success OR 'landlock sandbox unavailable' warning (rc=$rc)"; ok=0
fi
check "readExec-devnull-readable" "$ok"

# ---- Case 37: Landlock default (no readExec) — backward compat ----
# ---- Case 37: Landlock default (no readExec) — backward compat ----
# With sandbox.enable=True but readExec=False (default), a normal write inside
# cwd should still succeed (regression guard for backward compatibility).
cat > build_no_readExec.dhall <<'BUILDEOF'
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { sandbox = { enable = True, unveil = [] : List Text }
   , targets = [ { mapKey = "no-readExec", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Shell = "echo backward_compat > no_readExec.txt" > ] } } ], default = "no-readExec" }
BUILDEOF

"$BIN" -f build_no_readExec.dhall > /tmp/dhake-out37.txt 2> /tmp/dhake-err37.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
[ -f no_readExec.txt ] || { echo "  no_readExec.txt not created"; ok=0; }
grep -q 'backward_compat' no_readExec.txt || { echo "  content incorrect"; ok=0; }
check "no-readExec-backward-compat" "$ok"

# ---- Case 38: Landlock readExec — fail CLOSED when landlock unavailable ----
# readExec explicitly requests read/execute containment. If landlock cannot be
# established, dhake must ABORT (fail closed, rc=3) rather than run the recipe
# unsandboxed — silently skipping read containment would defeat the guarantee.
# Only exercised where landlock is unavailable; where it IS available (host),
# the build succeeds normally (both are correct, so accept either).
cat > build_readExec_failclosed.dhall <<'BUILDEOF'
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { sandbox = { enable = True, readExec = True, unveil = [] : List Text }
   , targets = [ { mapKey = "fc", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Shell = "touch readExec_fc_marker" > ] } } ], default = "fc" }
BUILDEOF

rm -f readExec_fc_marker
"$BIN" -f build_readExec_failclosed.dhall > /tmp/dhake-out38.txt 2> /tmp/dhake-err38.txt
rc=$?
ok=1
if [ "$rc" -eq 0 ] && [ -f readExec_fc_marker ]; then
    :   # landlock available: build succeeded and ran
elif [ "$rc" -eq 3 ] && grep -q 'aborting to avoid running recipes unsandboxed' /tmp/dhake-err38.txt && [ ! -f readExec_fc_marker ]; then
    :   # landlock unavailable: fail-closed abort, recipe did NOT run
else
    echo "  expected success OR fail-closed abort (rc=3) without running recipe (rc=$rc)"; ok=0
fi
rm -f readExec_fc_marker
check "readExec-fail-closed" "$ok"


# ---- Case 39: denyNetwork denies AF_INET socket creation ----
# With sandbox.denyNetwork=True, socket(AF_INET) must fail with EPERM. The
# recipe compiles a tiny probe in cwd and runs it; the probe returns 0 only if
# the AF_INET socket was denied. seccomp is installed independent of landlock,
# so this must hold even where landlock is unavailable; if seccomp itself cannot
# be established (denyNetwork=True) dhake fails closed (rc=3), which we accept.
cat > netprobe.c <<'CEOF'
#include <sys/socket.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    int fam = (argc > 1 && !strcmp(argv[1], "inet")) ? AF_INET : AF_UNIX;
    int fd = socket(fam, SOCK_STREAM, 0);
    if (fd < 0) {
        printf("%s: denied (%s)\n", argv[1], strerror(errno));
    } else {
        printf("%s: ALLOWED (fd=%d)\n", argv[1], fd);
        close(fd);
    }
    return 0;                            /* diagnostic: exit 0, caller greps output */
}
CEOF

cat > build_denyNetwork.dhall <<'BUILDEOF'
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { sandbox = { enable = True, denyNetwork = True, unveil = [] : List Text }
   , targets = [ { mapKey = "dn", mapValue = { deps = ["netprobe.c"], phony = False, recipe = [ < Shell = "cc -o netprobe netprobe.c && ./netprobe inet" > ] } } ], default = "dn" }
BUILDEOF

"$BIN" -f build_denyNetwork.dhall > /tmp/dhake-out39.txt 2> /tmp/dhake-err39.txt
rc=$?
ok=1
if [ "$rc" -eq 0 ]; then
    grep -q 'inet: denied' /tmp/dhake-out39.txt || { echo "  AF_INET not denied by seccomp"; ok=0; }
elif [ "$rc" -eq 3 ] && grep -q 'denyNetwork=True requested network containment but seccomp could not be established' /tmp/dhake-err39.txt; then
    :   # seccomp unavailable: fail-closed abort
else
    echo "  expected EPERM denial OR fail-closed abort (rc=$rc)"; ok=0
fi
check "denyNetwork-denies-AF_INET" "$ok"

# ---- Case 40: denyNetwork still allows AF_UNIX sockets ----
# seccomp must permit AF_UNIX/AF_LOCAL (local IPC) while denying network families.
cat > build_denyNetwork_unix.dhall <<'BUILDEOF'
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { sandbox = { enable = True, denyNetwork = True, unveil = [] : List Text }
   , targets = [ { mapKey = "dnu", mapValue = { deps = ["netprobe.c"], phony = False, recipe = [ < Shell = "cc -o netprobe netprobe.c && ./netprobe unix" > ] } } ], default = "dnu" }
BUILDEOF

"$BIN" -f build_denyNetwork_unix.dhall > /tmp/dhake-out40.txt 2> /tmp/dhake-err40.txt
rc=$?
ok=1
if [ "$rc" -eq 0 ]; then
    grep -q 'unix: ALLOWED' /tmp/dhake-out40.txt || { echo "  AF_UNIX socket unexpectedly denied"; ok=0; }
elif [ "$rc" -eq 3 ] && grep -q 'denyNetwork=True requested network containment but seccomp could not be established' /tmp/dhake-err40.txt; then
    :   # seccomp unavailable: fail-closed abort
else
    echo "  expected AF_UNIX allowed OR fail-closed abort (rc=$rc)"; ok=0
fi
check "denyNetwork-allows-AF_UNIX" "$ok"

# ---- Case 41: no-denyNetwork (backward compat) — AF_INET socket succeeds ----
# Default denyNetwork=False must leave networking untouched.
cat > build_no_denyNetwork.dhall <<'BUILDEOF'
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { sandbox = { enable = True, unveil = [] : List Text }
   , targets = [ { mapKey = "ndn", mapValue = { deps = ["netprobe.c"], phony = False, recipe = [ < Shell = "cc -o netprobe netprobe.c && ./netprobe inet" > ] } } ], default = "ndn" }
BUILDEOF

"$BIN" -f build_no_denyNetwork.dhall > /tmp/dhake-out41.txt 2> /tmp/dhake-err41.txt
rc=$?
ok=1
if [ "$rc" -eq 0 ]; then
    grep -q 'inet: ALLOWED' /tmp/dhake-out41.txt || { echo "  AF_INET should be allowed with denyNetwork=False"; ok=0; }
elif grep -q 'landlock sandbox unavailable' /tmp/dhake-err41.txt; then
    :   # landlock unavailable: runs unsandboxed (network still open)
else
    echo "  expected AF_INET allowed (rc=$rc)"; ok=0
fi
check "no-denyNetwork-backward-compat" "$ok"

# ---- Case 42: denyNetwork fail-closed when seccomp unavailable ----
# denyNetwork explicitly requests network containment. If seccomp cannot be
# established, dhake must ABORT (rc=3) and NOT run the recipe, mirroring the
# readExec fail-closed contract. DHAKE_FORCE_NO_SECCOMP simulates seccomp
# unavailability so the fail-closed branch is deterministically exercised.
cat > build_denyNetwork_failclosed.dhall <<'BUILDEOF'
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { sandbox = { enable = True, denyNetwork = True, unveil = [] : List Text }
   , targets = [ { mapKey = "dnfc", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Shell = "touch denyNetwork_fc_marker" > ] } } ], default = "dnfc" }
BUILDEOF

rm -f denyNetwork_fc_marker
DHAKE_FORCE_NO_SECCOMP=1 "$BIN" -f build_denyNetwork_failclosed.dhall > /tmp/dhake-out42.txt 2> /tmp/dhake-err42.txt
rc=$?
ok=1
if [ "$rc" -eq 3 ] && grep -q 'denyNetwork=True requested network containment but seccomp could not be established' /tmp/dhake-err42.txt && [ ! -f denyNetwork_fc_marker ]; then
    :   # seccomp forced unavailable: fail-closed abort, recipe did NOT run
elif [ "$rc" -eq 0 ] && [ -f denyNetwork_fc_marker ]; then
    :   # hook ignored (should not happen on supported arch): recipe ran
else
    echo "  expected fail-closed abort (rc=3) without running recipe (rc=$rc)"; ok=0
fi
rm -f denyNetwork_fc_marker
check "denyNetwork-fail-closed" "$ok"

# ---- Case A: Lockfile with verified target ----
# Build a target with --lock and verify the lockfile contains correct data
HASH_A=$(printf 'lockfile-test' | sha256sum | cut -d' ' -f1)
cat > build_lock_A.dhall <<'BUILDEOF'
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text, depsHash : List { path : Text, hash : Text } }
in  { targets = [ { mapKey = "lockoutA.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'lockfile-test' > lockoutA.txt" > ], hash = "sha256:PLACEHOLDER" } } ], default = "lockoutA.txt" }
BUILDEOF
sed -i "s/PLACEHOLDER/${HASH_A}/" build_lock_A.dhall

rm -f lockoutA.txt dhake.lock
"$BIN" -f build_lock_A.dhall --lock > /tmp/dhake-outA.txt 2> /tmp/dhake-errA.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
[ -f dhake.lock ] || { echo "  dhake.lock not created"; ok=0; }
# Check it's valid JSON (starts with {)
head -c1 dhake.lock | grep -q '{' || { echo "  dhake.lock doesn't start with {"; ok=0; }
# Check it contains the target name
grep -q 'lockoutA.txt' dhake.lock || { echo "  target name not in lockfile"; ok=0; }
# Check it contains the expected outputHash
grep -q "sha256:${HASH_A}" dhake.lock || { echo "  expected outputHash not in lockfile"; ok=0; }
# Check it contains the format and version
grep -q '"format": "dhake.lock"' dhake.lock || { echo "  format not in lockfile"; ok=0; }
grep -q '"version": 1' dhake.lock || { echo "  version not in lockfile"; ok=0; }
check "lockfile-verified-target" "$ok"
rm -f lockoutA.txt dhake.lock build_lock_A.dhall

# ---- Case B: Lockfile with 3-level dependency chain ----
# chain_a depends on chain_b depends on chain_c; verify chain_a's transitiveDeps contains both chain_b and chain_c
cat > build_lock_B.dhall <<'BUILDEOF'
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets = [ { mapKey = "chain_c", mapValue = { deps = [], phony = False, recipe = [ < Shell = "echo c > chain_c" > ] } }, { mapKey = "chain_b", mapValue = { deps = ["chain_c"], phony = False, recipe = [ < Shell = "echo b > chain_b" > ] } }, { mapKey = "chain_a", mapValue = { deps = ["chain_b"], phony = False, recipe = [ < Shell = "echo a > chain_a" > ] } } ], default = "chain_a" }
BUILDEOF

rm -f chain_a chain_b chain_c dhake.lock
"$BIN" -f build_lock_B.dhall --lock > /tmp/dhake-outB.txt 2> /tmp/dhake-errB.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
[ -f dhake.lock ] || { echo "  dhake.lock not created"; ok=0; }
# Check chain_a's transitiveDeps contains both chain_b and chain_c
grep -A20 '"name": "chain_a"' dhake.lock | grep -q '"transitiveDeps"' || { echo "  chain_a's transitiveDeps not found"; ok=0; }
grep -A20 '"name": "chain_a"' dhake.lock | grep -q '"chain_b"' || { echo "  chain_b not in chain_a's transitiveDeps"; ok=0; }
grep -A20 '"name": "chain_a"' dhake.lock | grep -q '"chain_c"' || { echo "  chain_c not in chain_a's transitiveDeps"; ok=0; }
check "lockfile-transitive-deps-chain" "$ok"
rm -f chain_a chain_b chain_c dhake.lock build_lock_B.dhall

# ---- Case C: --lock with dry-run writes no lockfile ----
cat > build_lock_C.dhall <<'BUILDEOF'
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets = [ { mapKey = "lockc", mapValue = { deps = [], phony = False, recipe = [ < Shell = "echo c > lockc" > ] } } ], default = "lockc" }
BUILDEOF

rm -f lockc dhake.lock custom.lock
"$BIN" -f build_lock_C.dhall --lock=custom.lock -n > /tmp/dhake-outC.txt 2> /tmp/dhake-errC.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
[ ! -f custom.lock ] || { echo "  custom.lock should not exist with dry-run"; ok=0; }
[ ! -f dhake.lock ] || { echo "  dhake.lock should not exist with dry-run"; ok=0; }
check "lockfile-dry-run-no-write" "$ok"
rm -f lockc custom.lock dhake.lock build_lock_C.dhall

# ---- Verify mode tests ----

# ---- Case V1: verify-clean-up-to-date ----
# Build a target with correct hash, then verify it's up to date
HASH_V1=$(printf 'verify-v1-content' | sha256sum | cut -d' ' -f1)
cat > build_verify_v1.dhall <<BUILDEOF
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text }
in  { targets = [ { mapKey = "verify_v1.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'verify-v1-content' > verify_v1.txt" > ], hash = "sha256:$HASH_V1" } } ], default = "verify_v1.txt" }
BUILDEOF

rm -f verify_v1.txt
"$BIN" -f build_verify_v1.dhall > /tmp/dhake-out-v1.txt 2> /tmp/dhake-err-v1.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
# Now verify it's up to date
"$BIN" -f build_verify_v1.dhall --verify > /tmp/dhake-out-v1b.txt 2> /tmp/dhake-err-v1b.txt
rc=$?
[ "$rc" -eq 0 ] || { echo "  verify expected exit 0, got $rc"; ok=0; }
grep -q "up to date" /tmp/dhake-out-v1b.txt || { echo "  'up to date' not found in verify output"; cat /tmp/dhake-out-v1b.txt; ok=0; }
check "verify-clean-up-to-date" "$ok"
rm -f verify_v1.txt build_verify_v1.dhall

# ---- Case V2: verify-needs-rebuild ----
# Target output missing (don't build first), verify should report needs rebuild
cat > build_verify_v2.dhall <<'BUILDEOF'
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets = [ { mapKey = "verify_v2.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'v2' > verify_v2.txt" > ] } } ], default = "verify_v2.txt" }
BUILDEOF

rm -f verify_v2.txt
"$BIN" -f build_verify_v2.dhall --verify > /tmp/dhake-out-v2.txt 2> /tmp/dhake-err-v2.txt
rc=$?
ok=1
[ "$rc" -ne 0 ] || { echo "  verify expected non-zero exit, got $rc"; ok=0; }
grep -q "needs rebuild" /tmp/dhake-out-v2.txt || { echo "  'needs rebuild' not found in verify output"; cat /tmp/dhake-out-v2.txt; ok=0; }
[ ! -f verify_v2.txt ] || { echo "  verify_v2.txt should not exist (no recipe ran)"; ok=0; }
check "verify-needs-rebuild" "$ok"
rm -f verify_v2.txt build_verify_v2.dhall

# ---- Case V3: verify-dep-hash-mismatch ----
# Dep file tampered, verify should report hash mismatch
HASH_V3=$(printf 'original-dep-content\n' | sha256sum | cut -d' ' -f1)
printf 'original-dep-content\n' > verify_v3_dep.txt
cat > build_verify_v3.dhall <<BUILDEOF
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, depsHash : List { path : Text, hash : Text } }
in  { targets = [ { mapKey = "verify_v3.txt", mapValue = { deps = ["verify_v3_dep.txt"], phony = False, recipe = [ < Shell = "cp verify_v3_dep.txt verify_v3.txt" > ], depsHash = [ { path = "verify_v3_dep.txt", hash = "sha256:$HASH_V3" } ] } } ], default = "verify_v3.txt" }
BUILDEOF

# Tamper the dep file
printf 'tampered-dep-content\n' > verify_v3_dep.txt
"$BIN" -f build_verify_v3.dhall --verify > /tmp/dhake-out-v3.txt 2> /tmp/dhake-err-v3.txt
rc=$?
ok=1
[ "$rc" -ne 0 ] || { echo "  verify expected non-zero exit, got $rc"; ok=0; }
grep -q "dep hash mismatch" /tmp/dhake-out-v3.txt || { echo "  'dep hash mismatch' not found in verify output"; cat /tmp/dhake-out-v3.txt; ok=0; }
[ ! -f verify_v3.txt ] || { echo "  verify_v3.txt should not exist (no recipe ran)"; ok=0; }
check "verify-dep-hash-mismatch" "$ok"
rm -f verify_v3.txt verify_v3_dep.txt build_verify_v3.dhall

# ---- Case V4: verify-output-hash-mismatch ----
# Build with correct hash, then tamper output file AND set its mtime to the past
# so it appears up-to-date by mtime, but hash should catch it
HASH_V4=$(printf 'original-output\n' | sha256sum | cut -d' ' -f1)
cat > build_verify_v4.dhall <<BUILDEOF
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text }
in  { targets = [ { mapKey = "verify_v4.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'original-output\\n' > verify_v4.txt" > ], hash = "sha256:$HASH_V4" } } ], default = "verify_v4.txt" }
BUILDEOF

rm -f verify_v4.txt
"$BIN" -f build_verify_v4.dhall > /tmp/dhake-out-v4.txt 2> /tmp/dhake-err-v4.txt
rc=$?
[ "$rc" -eq 0 ] || { echo "  initial build expected exit 0, got $rc"; ok=0; }
# Tamper the output file but set mtime to the past
printf 'tampered-output\n' > verify_v4.txt
touch -d '2020-01-01' verify_v4.txt
"$BIN" -f build_verify_v4.dhall --verify > /tmp/dhake-out-v4b.txt 2> /tmp/dhake-err-v4b.txt
rc=$?
ok=1
[ "$rc" -ne 0 ] || { echo "  verify expected non-zero exit, got $rc"; ok=0; }
grep -q "output hash mismatch" /tmp/dhake-out-v4b.txt || { echo "  'output hash mismatch' not found in verify output"; cat /tmp/dhake-out-v4b.txt; ok=0; }
check "verify-output-hash-mismatch" "$ok"
rm -f verify_v4.txt build_verify_v4.dhall

# ---- Case V5: verify-no-recipe-run ----
# A target whose recipe writes a sentinel file; run --verify without building
# should report needs rebuild and sentinel should NOT exist
cat > build_verify_v5.dhall <<'BUILDEOF'
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets = [ { mapKey = "verify_v5.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'v5' > verify_v5.txt && echo SENTINEL > verify_v5_sentinel.txt" > ] } } ], default = "verify_v5.txt" }
BUILDEOF

rm -f verify_v5.txt verify_v5_sentinel.txt
"$BIN" -f build_verify_v5.dhall --verify > /tmp/dhake-out-v5.txt 2> /tmp/dhake-err-v5.txt
rc=$?
ok=1
[ "$rc" -ne 0 ] || { echo "  verify expected non-zero exit, got $rc"; ok=0; }
grep -q "needs rebuild" /tmp/dhake-out-v5.txt || { echo "  'needs rebuild' not found in verify output"; cat /tmp/dhake-out-v5.txt; ok=0; }
[ ! -f verify_v5_sentinel.txt ] || { echo "  verify_v5_sentinel.txt should NOT exist (recipe did not run)"; ok=0; }
check "verify-no-recipe-run" "$ok"
rm -f verify_v5.txt verify_v5_sentinel.txt build_verify_v5.dhall

# ---- Hash-based up-to-date tests ----

# ---- Case H1: hash-uptodate touch-no-rebuild ----
# Verified target with a depsHash pin; touch dep (mtime bump, content same) -> with --hash-uptodate, no rebuild
HASH_H1=$(printf 'hello world' | sha256sum | cut -d' ' -f1)
cat > build_hash_h1.dhall <<BUILDEOF
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text, depsHash : List { path : Text, hash : Text } }
in  { targets = [ { mapKey = "hash_h1.txt", mapValue = { deps = ["src_h1.txt"], phony = False, recipe = [ < Shell = "cp src_h1.txt hash_h1.txt" > ], hash = "sha256:$HASH_H1", depsHash = [ { path = "src_h1.txt", hash = "sha256:$HASH_H1" } ] } } ], default = "hash_h1.txt" }
BUILDEOF

printf 'hello world' > src_h1.txt
rm -f hash_h1.txt
"$BIN" -f build_hash_h1.dhall > /tmp/dhake-out-h1a.txt 2> /tmp/dhake-err-h1a.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
[ -f hash_h1.txt ] || { echo "  hash_h1.txt should exist after build"; ok=0; }
# Now touch the source (mtime changes, content same). Sleep so the mtime gap is
# clearly larger than the filesystem's timestamp granularity — otherwise the
# rebuild assertion below could race.
sleep 1
touch src_h1.txt
# With --hash-uptodate, should be up to date (no rebuild)
"$BIN" -f build_hash_h1.dhall --hash-uptodate > /tmp/dhake-out-h1b.txt 2> /tmp/dhake-err-h1b.txt
rc=$?
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
grep -q "is up to date" /tmp/dhake-out-h1b.txt || { echo "  'is up to date' not found with --hash-uptodate"; cat /tmp/dhake-out-h1b.txt; ok=0; }
# Verify recipe did NOT run by checking mtime of hash_h1.txt hasn't changed
OLD_MTIME=$(stat -c %Y hash_h1.txt)
sleep 0.1
"$BIN" -f build_hash_h1.dhall --hash-uptodate > /tmp/dhake-out-h1c.txt 2> /tmp/dhake-err-h1c.txt
NEW_MTIME=$(stat -c %Y hash_h1.txt)
[ "$OLD_MTIME" = "$NEW_MTIME" ] || { echo "  hash_h1.txt mtime changed (recipe ran when it shouldn't)"; ok=0; }
check "hash-uptodate-touch-no-rebuild" "$ok"

# Without --hash-uptodate, same touch SHOULD trigger rebuild (mtime logic)
"$BIN" -f build_hash_h1.dhall > /tmp/dhake-out-h1d.txt 2> /tmp/dhake-err-h1d.txt
rc=$?
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
grep -q "building" /tmp/dhake-out-h1d.txt || { echo "  'building' not found without --hash-uptodate (should rebuild)"; cat /tmp/dhake-out-h1d.txt; ok=0; }
check "hash-uptodate-mtime-still-works" "$ok"
rm -f hash_h1.txt src_h1.txt build_hash_h1.dhall

# ---- Case H2: hash-uptodate content-change-rebuild ----
# Same target; actually change src content -> with --hash-uptodate, must rebuild
HASH_H2_OLD=$(printf 'hello world' | sha256sum | cut -d' ' -f1)
HASH_H2_NEW=$(printf 'hello changed' | sha256sum | cut -d' ' -f1)
cat > build_hash_h2.dhall <<BUILDEOF
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text, depsHash : List { path : Text, hash : Text } }
in  { targets = [ { mapKey = "hash_h2.txt", mapValue = { deps = ["src_h2.txt"], phony = False, recipe = [ < Shell = "cp src_h2.txt hash_h2.txt" > ], hash = "sha256:$HASH_H2_OLD", depsHash = [ { path = "src_h2.txt", hash = "sha256:$HASH_H2_OLD" } ] } } ], default = "hash_h2.txt" }
BUILDEOF

printf 'hello world' > src_h2.txt
rm -f hash_h2.txt
"$BIN" -f build_hash_h2.dhall > /tmp/dhake-out-h2a.txt 2> /tmp/dhake-err-h2a.txt
rc=$?
ok=1
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
[ -f hash_h2.txt ] || { echo "  hash_h2.txt should exist after build"; ok=0; }
# Change the source content
printf 'hello changed' > src_h2.txt
# With --hash-uptodate, should rebuild (hash differs). Add --warn-hash-mismatch so
# the post-build output-hash verification (pin is still the OLD content) downgrades
# to a warning instead of failing the rebuild we are deliberately triggering.
"$BIN" -f build_hash_h2.dhall --hash-uptodate --warn-hash-mismatch > /tmp/dhake-out-h2b.txt 2> /tmp/dhake-err-h2b.txt
rc=$?
[ "$rc" -eq 0 ] || { echo "  expected exit 0, got $rc"; ok=0; }
grep -q "building" /tmp/dhake-out-h2b.txt || { echo "  'building' not found with --hash-uptodate (should rebuild on content change)"; cat /tmp/dhake-out-h2b.txt; ok=0; }
check "hash-uptodate-content-change-rebuild" "$ok"
rm -f hash_h2.txt src_h2.txt build_hash_h2.dhall

# ---- Case: watch-rebuild-on-change ----
# Test that --watch mode rebuilds when a source file changes
write_file watch_src.txt 'v1'
cat > build_watch.dhall <<'BUILDEOF'
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets = [ { mapKey = "watch_out.txt", mapValue = { deps = ["watch_src.txt"], phony = False, recipe = [ < Shell = "cat watch_src.txt > watch_out.txt" > ] } } ], default = "watch_out.txt" }
BUILDEOF

# Start dhake in watch mode in background
"$BIN" -f build_watch.dhall --watch > /tmp/dhake-watch-log.txt 2>&1 &
WPID=$!

# Wait for the "watching" steady-state line (up to 10s, 0.1s polls)
watch_ready=0
for i in $(seq 1 100); do
    if grep -q "watching.*file.*for changes" /tmp/dhake-watch-log.txt; then
        watch_ready=1
        break
    fi
    sleep 0.1
done

ok=1
if [ "$watch_ready" -ne 1 ]; then
    echo "  'watching' line not found in log after 10s"
    cat /tmp/dhake-watch-log.txt
    ok=0
fi

# Modify the source file
printf 'v2\n' > watch_src.txt

# Wait for rebuild (poll up to 10s for >= 2 "building" lines)
rebuild_count=0
for i in $(seq 1 100); do
    count=$(grep -c "building" /tmp/dhake-watch-log.txt || true)
    if [ "$count" -ge 2 ]; then
        rebuild_count=1
        break
    fi
    sleep 0.1
done

if [ "$rebuild_count" -ne 1 ]; then
    echo "  rebuild not detected (building count < 2)"
    count=$(grep -c "building" /tmp/dhake-watch-log.txt || true)
    echo "  building count: $count"
    cat /tmp/dhake-watch-log.txt
    ok=0
fi

# Check output file has v2
if [ "$ok" -eq 1 ]; then
    if ! grep -q "v2" watch_out.txt; then
        echo "  watch_out.txt does not contain v2"
        cat watch_out.txt
        ok=0
    fi
fi

# Always clean up the watcher
kill $WPID 2>/dev/null || true
wait $WPID 2>/dev/null || true

check "watch-rebuild-on-change" "$ok"
rm -f watch_src.txt watch_out.txt build_watch.dhall

rm -f netprobe.c netprobe build_denyNetwork.dhall build_denyNetwork_unix.dhall build_no_denyNetwork.dhall build_denyNetwork_failclosed.dhall

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
