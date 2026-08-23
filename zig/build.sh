#!/bin/sh
# build.sh — build the Zig dhake binary (links libdhall.so in-process).
#
# Build command proven in the plan (U0 / artifact-2). libdhall.so is linked via
# the C-ABI seam (zig/src/dhall_types.zig + zig/src/dhall_abi.zig); -rpath
# embeds the search path so the binary runs without LD_LIBRARY_PATH.
set -eu
cd "$(dirname "$0")/.."

# The vendored dhall-c core (vendor/dhall-c submodule) provides libdhall.so
# (built by the Dhakefile 'libdhall.so' target via `zig build-obj abi.zig`
# + `cc -shared` + `strip`, which yields SONAME libdhall.so and a deterministic
# output). Link against THAT, not a dev sibling checkout. Use $ORIGIN (expands
# to the
# directory of the produced binary, i.e. zig-out/) so the RUNPATH is relative
# to the repo and the build is self-hostable + byte-deterministic from a fresh
# clone at any path (the Dhakefile pins the output hash).
#
# -L needs a concrete dir at link time; derive it from this script's location
# (the repo root, cd'd above) rather than a hardcoded /workspace path.
DHALL_LIB="$(pwd)/vendor/dhall-c/zig/lib"

ZIG_GLOBAL_CACHE_DIR=/tmp/.zcache \
ZIG_LOCAL_CACHE_DIR=/tmp/.zlcache \
zig build-exe zig/src/main.zig \
    -lc \
    -L"$DHALL_LIB" \
    -ldhall \
    -fno-each-lib-rpath \
    -rpath '$ORIGIN/../vendor/dhall-c/zig/lib' \
    -femit-bin=zig-out/dhake \
    -O ReleaseSafe \
    -fstrip \

echo "built zig-out/dhake"
