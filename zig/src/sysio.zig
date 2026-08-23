// sysio.zig — buffered stdout/stderr writers on std.os.linux.write, plus
// extern libc env helpers (getenv/setenv/unsetenv), read_file (dhake.c:240-256)
// and default_buildfile (dhake.c:1623-1629).
const std = @import("std");

// ─── Raw writes ──────────────────────────────────────────────────────────
pub fn writeOut(s: []const u8) void {
    _ = std.os.linux.write(1, s.ptr, s.len);
}

pub fn writeErr(s: []const u8) void {
    _ = std.os.linux.write(2, s.ptr, s.len);
}

// Formatted stdout/stderr writes (bufPrint onto a stack buffer, then raw write).
pub fn writeOutFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.os.linux.write(1, s.ptr, s.len);
}

pub fn writeErrFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.os.linux.write(2, s.ptr, s.len);
}

// ─── libc environment helpers (link -lc) ────────────────────────────────
extern fn getenv(name: [*:0]const u8) ?[*:0]u8;
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;

pub fn envGet(name: [*:0]const u8) ?[]const u8 {
    const v = getenv(name) orelse return null;
    return std.mem.span(v);
}

pub fn setEnv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) void {
    _ = setenv(name, value, overwrite);
}

pub fn unsetEnv(name: [*:0]const u8) void {
    _ = unsetenv(name);
}

// ─── read_file (dhake.c:240-256) via posix.openat + read + growable buffer ─
// Returns a NUL-terminated buffer (length = content_len + 1); *len_out is the
// content length. Caller frees with freeBuf(). NULL on open/read failure.
pub fn readFile(path: []const u8, len_out: *usize) ?[]u8 {
    const c = std.heap.c_allocator;
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    var cap: usize = 65536;
    var buf = c.alloc(u8, cap) catch {
        _ = std.os.linux.close(fd);
        return null;
    };
    var len: usize = 0;
    var tmp: [4096]u8 = undefined;
    while (true) {
        if (len == cap) {
            cap *= 2;
            buf = c.realloc(buf, cap) catch {
                c.free(buf);
                _ = std.os.linux.close(fd);
                return null;
            };
        }
        const n = std.posix.read(fd, &tmp) catch {
            c.free(buf);
            _ = std.os.linux.close(fd);
            return null;
        };
        if (n == 0) break;
        @memcpy(buf[len .. len + n], tmp[0..n]);
        len += n;
    }
    _ = std.os.linux.close(fd);
    buf[len] = 0;
    len_out.* = len;
    return buf[0 .. len + 1];
}

pub fn freeBuf(b: []u8) void {
    std.heap.c_allocator.free(b);
}

// ─── default_buildfile (dhake.c:1623-1629) ───────────────────────────────
// pick the default buildfile: Dhakefile.dhall, else build.dhall.
pub fn defaultBuildfile() []const u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, "Dhakefile.dhall", .{ .ACCMODE = .RDONLY }, 0) catch
        return "build.dhall";
    _ = std.os.linux.close(fd);
    return "Dhakefile.dhall";
}

// ─── file_mtime_ns (dhake.c:1075-1088) ───────────────────────────────────
// Return the file's mtime in nanoseconds since epoch, and set *exists.
// Uses the statx(2) syscall (the stdlib-provided stat primitive on this
// kernel — see plan RISK-1); nanosecond resolution always preserved.
pub fn fileMtimeNs(path: [*:0]const u8, exists: ?*bool) i64 {
    var st: std.os.linux.Statx = undefined;
    const rc = std.os.linux.statx(
        std.os.linux.AT.FDCWD,
        path,
        0,
        std.os.linux.STATX.BASIC_STATS,
        &st,
    );
    if (std.os.linux.errno(rc) != .SUCCESS) {
        if (exists) |e| e.* = false;
        return 0;
    }
    if (exists) |e| e.* = true;
    return @as(i64, st.mtime.sec) * 1000000000 + @as(i64, st.mtime.nsec);
}
