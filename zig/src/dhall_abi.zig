// dhall_abi.zig — extern fn declarations for the libdhall.so C-ABI surface.
//
// These mirror the `export fn` set in dhall-c/zig/src/abi.zig (which exports the
// exact `dhall.h` public surface dhake.c links against). The core is linked
// in-process via -ldhall; the concrete Arena/ImportLoader types are opaque on
// this side. See the plan CRUX DECISION: all core access is confined to this
// seam module plus dhall_types.zig (the extern-struct mirror), so a later swap
// to a native @import only rewrites THIS file.

const std = @import("std");
const dt = @import("dhall_types.zig");

// ─── Arena ─────────────────────────────────────────────────────────────────
pub extern fn arena_new() ?*anyopaque;
pub extern fn arena_reset(a: ?*anyopaque) void;
pub extern fn arena_alloc(a: ?*anyopaque, n: usize) ?*anyopaque;
pub extern fn arena_strdup(a: ?*anyopaque, s: [*:0]const u8) ?[*:0]u8;

// ─── Import loader ─────────────────────────────────────────────────────────
pub extern fn import_loader_new() ?*dt.ImportLoader;
pub extern fn import_loader_free(l: ?*dt.ImportLoader) void;
pub extern fn import_loader_push_root(l: ?*dt.ImportLoader, root: ?[*:0]const u8) void;

// ─── Parse ─────────────────────────────────────────────────────────────────
pub extern fn parse_source(
    p: *dt.Parser,
    src: [*:0]const u8,
    file: [*:0]const u8,
    err: *dt.DhallError,
) ?*dt.Term;

// ─── Error helpers ─────────────────────────────────────────────────────────
pub extern fn dhall_error_clear(e: *dt.DhallError) void;
pub extern fn dhall_error_exit(e: *dt.DhallError) c_int;

// ─── Normalize ─────────────────────────────────────────────────────────────
pub extern fn normalize(t: *dt.Term) ?*dt.Term;
pub extern fn normalize_clear_error() void;
pub extern fn normalize_has_error() bool;
pub extern fn normalize_get_error() ?*dt.DhallError;

// ─── Hashing ───────────────────────────────────────────────────────────────
pub extern fn sha256_hex(data: [*]const u8, len: usize, out: *[65]u8) void;
