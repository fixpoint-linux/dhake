#!/bin/sh
# oracle.sh — rebuild the C oracle (current src/dhake.c linked against the
# current libdhall.so via the oracle-shim). Required because the prebuilt
# dhall-c/zig/dhake-build/dhake binary is ABI-drifted (scores 48/43); a fresh
# oracle scores 78/13 on tests/build.sh.
#
# All intermediates are emitted under zig-out/ (/workspace-persistent + ignored).
set -eu
cd "$(dirname "$0")/.."
mkdir -p zig-out

# Step 1: compile dhake.c against the shim's include tree + dhall-c sources.
cc -I zig/oracle-shim/inc -I /workspace/dhall-c/src -D_GNU_SOURCE=1 -std=c11 -O2 -D_POSIX_C_SOURCE=200809L -c src/dhake.c -o zig-out/dhake_oracle.o

# Step 2: compile the shim (landlock + inotify + __NR_socket wrappers).
cc -c zig/oracle-shim/shim.c -o zig-out/shim.o

# Step 3: link against libdhall.so, embedding rpath.
cc zig-out/dhake_oracle.o zig-out/shim.o -L/workspace/dhall-c/zig/lib -ldhall -Wl,-rpath,/workspace/dhall-c/zig/lib -o zig-out/dhake.oracle

echo "built zig-out/dhake.oracle"
