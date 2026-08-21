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
# A non-phony target produces a file with a declared sha256.
# First run: build succeeds + verified message. Second run: up-to-date.
HASH26=$(printf 'hello' | sha256sum | cut -d' ' -f1)
cat > build_output_hash_correct.dhall <<BUILDEOF
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, sha256 : Text, depsSha256 : List { path : Text, sha256 : Text } }
in  { targets = [ { mapKey = "out26.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'hello' > out26.txt" > ], sha256 = "${HASH26}" } } ], default = "out26.txt" }
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
# Same as case 26 but with a wrong sha256. Build must fail.
cat > build_output_hash_wrong.dhall <<BUILDEOF
let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, sha256 : Text, depsSha256 : List { path : Text, sha256 : Text } }
in  { targets = [ { mapKey = "out27.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'hello' > out27.txt" > ], sha256 = "0000000000000000000000000000000000000000000000000000000000000000" } } ], default = "out27.txt" }
BUILDEOF

rm -f out27.txt
"$BIN" -f build_output_hash_wrong.dhall > /tmp/dhake-out27.txt 2> /tmp/dhake-err27.txt
rc=$?
ok=1
[ "$rc" -ne 0 ] || { echo "  expected non-zero exit, got $rc"; ok=0; }
grep -qi "hash mismatch" /tmp/dhake-err27.txt || { echo "  hash mismatch error not found on stderr"; cat /tmp/dhake-err27.txt; ok=0; }
check "output-hash-wrong" "$ok"

# ---- Case 28: Dep hash correct then tampered ----
# A target with depsSha256 verifying its source dep. First run succeeds.
# Then tamper the dep file -> second run fails with dep hash mismatch.
HASH28=$(printf 'input28' | sha256sum | cut -d' ' -f1)
cat > build_dep_hash.dhall <<BUILDEOF
let Action = < Shell : Text | Copy : { from : Text, to : Text } >
let Target = { deps : List Text, phony : Bool, recipe : List Action, sha256 : Text, depsSha256 : List { path : Text, sha256 : Text } }
in  { targets = [ { mapKey = "depout28.txt", mapValue = { deps = ["input28.txt"], phony = False, recipe = [ < Copy = { from = "input28.txt", to = "depout28.txt" } > ], depsSha256 = [ { path = "input28.txt", sha256 = "${HASH28}" } ] } } ], default = "depout28.txt" }
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
let Target = { deps : List Text, phony : Bool, recipe : List Action, sha256 : Text, depsSha256 : List { path : Text, sha256 : Text } }
in  { targets = [ { mapKey = "out29.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'hello29' > out29.txt" > ], sha256 = "${HASH29}" } } ], default = "out29.txt" }
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

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
