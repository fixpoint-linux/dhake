// build.zig — target-able dhake build (the 32-bit path).
//
// zig/build.sh remains the documented NATIVE build: it links the prebuilt
// shared vendor/dhall-c/zig/lib/libdhall.so through the C-ABI seam and is
// what the self-hosting Dhakefile recipe invokes (its output hash is pinned).
// A shared glibc object cannot serve an x86-linux-musl link, so this
// build.zig exists for the cross path: it compiles the SAME dhall-c Zig core
// (vendor/dhall-c/zig/src/abi.zig, the C-ABI export layer) IN-GRAPH for
// whatever -Dtarget was requested and links it statically — no libdhall.so,
// no dynamic loader. This is the pattern the siblings use
// (fx-init/zig/build.zig, fxstore/build.zig, fx-core/build.zig).
//
//   zig build -Dtarget=x86-linux-musl -Doptimize=ReleaseSmall --prefix DIR
//
// build.zig lives at the REPO ROOT because zig 0.16 locates build.zig only in
// the cwd or its parents (same note as fxstore/build.zig).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The dhall-c core's modules import each other by bare filename
    // (`@import("parser.zig")`), which only resolves when the module root
    // lives in that directory — so the root source file IS vendored abi.zig.
    const dhall_core_mod = b.createModule(.{
        .root_source_file = b.path("vendor/dhall-c/zig/src/abi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const dhall_core = b.addLibrary(.{
        .name = "dhall_core",
        .linkage = .static,
        .root_module = dhall_core_mod,
    });

    // dhake itself: unchanged sources; zig/src/dhall_abi.zig's `extern fn`
    // decls resolve against the core's `export fn` symbols at link time,
    // exactly as they did against libdhall.so.
    const dhake_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const exe = b.addExecutable(.{ .name = "dhake", .root_module = dhake_mod });
    dhake_mod.linkLibrary(dhall_core);

    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);

    // The repo's only Zig unit test (the dhall.h mirror-struct layout check).
    // It was unreachable before — there was no build.zig to run it — and it is
    // worth having per-target, since the mirror structs are a C ABI.
    const unit_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("zig/src/dhall_types.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(unit_tests).step);
}
