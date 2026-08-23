// opts.zig — global flags / defines / arch / cache_dir state + die() +
// detect_arch() (dhake.c:129-215, 217-238, plus default_cache_dir 150-168).
const std = @import("std");
const sysio = @import("sysio.zig");

// ─── die(): byte-parity with C's die() -> 'dhake: error: <msg>' exit(2) ────
pub fn die(msg: []const u8) noreturn {
    sysio.writeErr("dhake: error: ");
    sysio.writeErr(msg);
    sysio.writeErr("\n");
    std.os.linux.exit_group(2);
}

// Formatted die: formats with Zig-style format string then dies.
pub fn dieFmt(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch "out of memory formatting error";
    die(s);
}

// ─── --define KEY=VALUE support (dhake.c:129-215) ─────────────────────────
const DefineEntry = struct {
    key: [*:0]u8,
    value: [*:0]u8,
    saved_value: ?[]const u8, // NULL means was unset before
};

var defines: []DefineEntry = &.{};
var ndefines: usize = 0;
var defines_cap: usize = 0;

fn oom() noreturn {
    die("out of memory");
}

fn dupeZ(s: []const u8) [*:0]u8 {
    const c = std.heap.c_allocator;
    const p = c.dupeZ(u8, s) catch oom();
    return p.ptr;
}

pub fn addDefine(key: []const u8, value: []const u8) void {
    const c = std.heap.c_allocator;
    if (ndefines == defines_cap) {
        defines_cap = if (defines_cap != 0) defines_cap * 2 else 4;
        const old = defines[0..ndefines];
        const nb = c.alloc(DefineEntry, defines_cap) catch oom();
        @memcpy(nb[0..ndefines], old);
        c.free(old);
        defines = nb;
    }
    defines[ndefines] = .{
        .key = dupeZ(key),
        .value = dupeZ(value),
        .saved_value = null,
    };
    ndefines += 1;
}

pub fn applyDefines() void {
    const c = std.heap.c_allocator;
    for (defines[0..ndefines]) |*d| {
        d.saved_value = null;
        if (sysio.envGet(d.key)) |sv| {
            const p = c.dupeZ(u8, sv) catch oom();
            d.saved_value = p;
        }
        sysio.setEnv(d.key, d.value, 1);
    }
}

pub fn restoreDefines() void {
    const c = std.heap.c_allocator;
    var i: usize = ndefines;
    while (i > 0) {
        i -= 1;
        const d = &defines[i];
        if (d.saved_value) |sv| {
            sysio.setEnv(d.key, @ptrCast(sv.ptr), 1);
            c.free(sv);
            d.saved_value = null;
        } else {
            sysio.unsetEnv(d.key);
        }
    }
}

pub fn freeDefines() void {
    const c = std.heap.c_allocator;
    for (defines[0..ndefines]) |d| {
        c.free(d.key);
        c.free(d.value);
        if (d.saved_value) |sv| c.free(sv);
    }
    c.free(defines);
    defines = &.{};
    ndefines = 0;
    defines_cap = 0;
}

// ─── --arch=NAME support (dhake.c:141-142) ────────────────────────────────
pub var arch_param: ?[*:0]const u8 = null;
pub var arch_value: ?[*:0]const u8 = null;

// ─── --quiet/-s support (dhake.c:2491) ───────────────────────────────────
pub var quiet: bool = false;

// ─── --verify/--check (dhake.c:620-622) ─────────────────────────────────
pub var want_verify: bool = false;

// ─── --hash-uptodate / --content-addressed (dhake.c:624-626) ─────────────
pub var hash_uptodate: bool = false;

// ─── --explain / --why (dhake.c:2490) ────────────────────────────────────
pub var want_explain: bool = false;

// ─── --watch / -w (dhake.c:2489) ────────────────────────────────────────
pub var watch_mode: bool = false;

// ─── --graph[=dot|mermaid] (dhake.c:2505-2510) ───────────────────────────
// NULL = not requested; "dot" or "mermaid" otherwise.
pub var graph_format: ?[]const u8 = null;

// ─── --lock[=FILE] (dhake.c:1635-1636) ───────────────────────────────────
pub var lock_path: ?[]const u8 = null; // NULL = not requested

// ─── --cache[=DIR] support (dhake.c:145) ─────────────────────────────────
pub var cache_dir: ?[*:0]u8 = null; // NULL = disabled

// Return the default cache directory path (heap-allocated). Caller must free.
pub fn defaultCacheDir() [*:0]u8 {
    const c = std.heap.c_allocator;
    const xdg = sysio.envGet("XDG_CACHE_HOME");
    const home = sysio.envGet("HOME");
    var base: ?[]const u8 = null;
    var suffix: []const u8 = "";
    if (xdg != null and xdg.?.len != 0) {
        base = xdg;
        suffix = "/dhake";
    } else if (home != null and home.?.len != 0) {
        base = home;
        suffix = "/.cache/dhake";
    }
    if (base) |b| {
        const total = b.len + suffix.len + 1;
        const p = c.alloc(u8, total) catch die("default_cache_dir: out of memory");
        var n: usize = 0;
        @memcpy(p[n .. n + b.len], b);
        n += b.len;
        @memcpy(p[n .. n + suffix.len], suffix);
        n += suffix.len;
        p[n] = 0;
        return @ptrCast(p.ptr);
    }
    return dupeZ(".dhake-cache");
}

// Detect the native architecture using uname(). Normalizes arm64 to aarch64.
var machine_buf: [256]u8 = undefined;
pub fn detectArch() [*:0]const u8 {
    const u = std.posix.uname();
    const mach = std.mem.sliceTo(&u.machine, 0);
    if (std.mem.eql(u8, mach, "arm64") or std.mem.eql(u8, mach, "ARM64") or std.mem.eql(u8, mach, "aarch64"))
        return "aarch64";
    if (std.mem.eql(u8, mach, "x86_64") or std.mem.eql(u8, mach, "amd64") or std.mem.eql(u8, mach, "AMD64"))
        return "x86_64";
    @memcpy(machine_buf[0..mach.len], mach);
    machine_buf[mach.len] = 0;
    const z: [*:0]const u8 = @ptrCast(&machine_buf);
    return z;
}
