// eval.zig — buildfile evaluation: parse -> normalize (dhake.c:969-1000) and
// print_dhall_error (dhake.c:505-512).
//
// ARENA DISCIPLINE: this module OWNS the shared evaluation arena. It never
// declares `extern var dhall_arena` (copy-relocation would leave the core's
// internal global NULL). Instead a module-local `var arena: ?*anyopaque = null`
// holds it; getArena() lazily creates it via arena_new() (which installs the
// core-internal global, proven in the plan), and every arena_alloc/arena_strdup
// elsewhere is handed the arena pointer explicitly.
const std = @import("std");
const dt = @import("dhall_types.zig");
const abi = @import("dhall_abi.zig");
const opts = @import("opts.zig");
const sysio = @import("sysio.zig");

var arena: ?*anyopaque = null;

// Return the shared arena, creating it on first use (mirrors C's
// `if (!dhall_arena) dhall_arena = arena_new();`).
pub fn getArena() ?*anyopaque {
    if (arena == null) arena = abi.arena_new();
    return arena;
}

fn msgLen(msg: *const [512]u8) usize {
    return std.mem.indexOfScalar(u8, msg, 0) orelse 512;
}

fn fmtInt(buf: []u8, v: anytype) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch &[_]u8{};
}

pub fn printDhallError(e: *const dt.DhallError) void {
    sysio.writeErr("dhake: error: ");
    sysio.writeErr(e.msg[0..msgLen(&e.msg)]);
    if (e.has_span) {
        if (e.span.file) |f| {
            sysio.writeErr(" (at ");
            sysio.writeErr(std.mem.span(f));
            sysio.writeErr(":");
            var tmp: [32]u8 = undefined;
            sysio.writeErr(fmtInt(&tmp, e.span.line));
            sysio.writeErr(":");
            sysio.writeErr(fmtInt(&tmp, e.span.col));
            sysio.writeErr(")");
        } else {
            sysio.writeErr(" (at line ");
            var tmp: [32]u8 = undefined;
            sysio.writeErr(fmtInt(&tmp, e.span.line));
            sysio.writeErr(", col ");
            sysio.writeErr(fmtInt(&tmp, e.span.col));
            sysio.writeErr(")");
        }
    }
    sysio.writeErr("\n");
}

pub fn evalBuildfile(path: []const u8) ?*dt.Term {
    var len: usize = 0;
    const src = sysio.readFile(path, &len) orelse
        opts.dieFmt("cannot open buildfile '{s}'", .{path});

    const a = getArena() orelse opts.die("arena_new: out of memory");
    abi.arena_reset(a);

    const loader = abi.import_loader_new();
    const path_z: [*:0]const u8 = @ptrCast(path.ptr);
    abi.import_loader_push_root(loader, path_z);

    var p: dt.Parser = std.mem.zeroes(dt.Parser);
    p.loader = loader;
    var err: dt.DhallError = std.mem.zeroes(dt.DhallError);
    abi.dhall_error_clear(&err);

    const src_z: [*:0]const u8 = @ptrCast(src.ptr);
    const t = abi.parse_source(&p, src_z, path_z, &err);
    sysio.freeBuf(src);
    if (t == null) {
        printDhallError(&err);
        abi.import_loader_free(loader);
        std.os.linux.exit_group(@intCast(abi.dhall_error_exit(&err)));
    }

    abi.normalize_clear_error();
    const nf = abi.normalize(t.?);
    if (abi.normalize_has_error()) {
        err = abi.normalize_get_error().?.*;
        printDhallError(&err);
        abi.import_loader_free(loader);
        std.os.linux.exit_group(@intCast(abi.dhall_error_exit(&err)));
    }
    abi.import_loader_free(loader);
    return nf; // arena-owned; valid until next arena_reset
}
