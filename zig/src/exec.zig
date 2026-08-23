// exec.zig — recipe executor: copy_file/touch_file/mkdir_p/rm_rf
// (dhake.c:1094-1106, 1108-1117, 1411-1437) and run_shell/run_action/
// action_echo/print_action (dhake.c:1456-1617).
//
// libc fns not in stdlib are declared extern here (we link -lc): mkdir/chmod/
// rename/symlink/remove/utimes/execvp/setenv/strerror plus the errno accessor
// __errno_location() and the `environ` global.
const std = @import("std");
const plan = @import("plan.zig");
const opts = @import("opts.zig");
const sysio = @import("sysio.zig");

// ─── extern libc ────────────────────────────────────────────────────────────
extern fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern fn chmod(path: [*:0]const u8, mode: c_uint) c_int;
extern fn rename(oldpath: [*:0]const u8, newpath: [*:0]const u8) c_int;
extern fn symlink(target: [*:0]const u8, linkpath: [*:0]const u8) c_int;
extern fn remove(path: [*:0]const u8) c_int;
extern fn utimes(path: [*:0]const u8, times: ?*const anyopaque) c_int;
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn execvp(file: [*:0]const u8, argv: [*]const ?[*:0]const u8) c_int;
extern fn strerror(errnum: c_int) [*:0]const u8;
extern fn __errno_location() *c_int;
extern var environ: [*:null]?[*:0]u8;

fn errnoVal() c_int {
    return __errno_location().*;
}

fn strerr() []const u8 {
    return std.mem.span(strerror(errnoVal()));
}

// ─── wait-status decoding (WIFEXITED/WEXITSTATUS/WIFSIGNALED/WTERMSIG) ────
pub fn wifexited(status: u32) bool {
    return (status & 0x7f) == 0;
}
pub fn wexitstatus(status: u32) c_int {
    return @intCast((status >> 8) & 0xff);
}
pub fn wifsignaled(status: u32) bool {
    return @as(i32, @bitCast(status & 0x7f)) != 0 and ((@as(i32, @bitCast((status & 0x7f) + 1)) >> 1) > 0);
}
pub fn wtermsig(status: u32) c_int {
    return @intCast(status & 0x7f);
}

// ─── copy_file (dhake.c:1094-1106): 64KiB copy loop ───────────────────────
pub fn copyFile(from: [*:0]const u8, to: [*:0]const u8) bool {
    const inf = std.posix.openat(std.posix.AT.FDCWD, std.mem.span(from), .{ .ACCMODE = .RDONLY }, 0) catch {
        sysio.writeErrFmt("dhake: copy: cannot open '{s}'\n", .{std.mem.span(from)});
        return false;
    };
    const outf = std.posix.openat(std.posix.AT.FDCWD, std.mem.span(to), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch {
        sysio.writeErrFmt("dhake: copy: cannot open '{s}'\n", .{std.mem.span(to)});
        _ = std.os.linux.close(inf);
        return false;
    };
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = std.posix.read(inf, &buf) catch {
            sysio.writeErrFmt("dhake: copy: write error to '{s}'\n", .{std.mem.span(to)});
            _ = std.os.linux.close(inf);
            _ = std.os.linux.close(outf);
            return false;
        };
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const w = std.os.linux.write(outf, buf[off..n].ptr, n - off);
            if (std.os.linux.errno(w) != .SUCCESS) {
                sysio.writeErrFmt("dhake: copy: write error to '{s}'\n", .{std.mem.span(to)});
                _ = std.os.linux.close(inf);
                _ = std.os.linux.close(outf);
                return false;
            }
            off += w;
        }
    }
    _ = std.os.linux.close(inf);
    _ = std.os.linux.close(outf);
    return true;
}

// ─── touch_file (dhake.c:1108-1117): create + set current mtime/atime ────
fn touchFile(path: [*:0]const u8) bool {
    const fd = std.posix.openat(std.posix.AT.FDCWD, std.mem.span(path), .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644) catch {
        sysio.writeErrFmt("dhake: touch: cannot open '{s}'\n", .{std.mem.span(path)});
        return false;
    };
    _ = std.os.linux.close(fd);
    _ = utimes(path, null);
    return true;
}

// ─── mkdir_p (dhake.c:1411-1425): create parents, ignore EEXIST ──────────
pub fn mkdirP(path: [*:0]const u8) c_int {
    const c = std.heap.c_allocator;
    const len = std.mem.len(path);
    const buf = c.alloc(u8, len + 1) catch return -1;
    defer c.free(buf);
    @memcpy(buf[0..len], path[0..len]);
    buf[len] = 0;
    var i: usize = if (len > 0 and buf[0] == '/') 1 else 0;
    while (i < len) : (i += 1) {
        if (buf[i] == '/') {
            buf[i] = 0;
            const r = mkdir(@ptrCast(buf.ptr), 0o755);
            const e = errnoVal();
            buf[i] = '/';
            if (r != 0 and e != @intFromEnum(std.os.linux.E.EXIST)) return -1;
        }
    }
    if (mkdir(@ptrCast(buf.ptr), 0o755) != 0 and errnoVal() != @intFromEnum(std.os.linux.E.EXIST)) return -1;
    return 0;
}

// ─── rm_rf (dhake.c:1427-1437) — recursive delete via getdents64+unlinkat ─
// FTW_PHYS parity: never follows symlinks (a symlink is unlinked as a file,
// DT_LNK != DT_DIR). Missing path (ENOENT) is a success (returns 0).
fn rmRf(path: [*:0]const u8) c_int {
    const fd = std.posix.openat(std.posix.AT.FDCWD, std.mem.span(path), .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0) catch {
        if (errnoVal() == @intFromEnum(std.os.linux.E.NOENT)) return 0;
        return -1;
    };
    defer _ = std.os.linux.close(fd);
    var rc: c_int = 0;
    var buf: [8192]u8 align(8) = undefined;
    outer: while (true) {
        const n = std.os.linux.getdents64(fd, &buf, buf.len);
        if (std.os.linux.errno(n) != .SUCCESS) {
            rc = -1;
            break;
        }
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const d: *align(1) const std.os.linux.dirent64 = @ptrCast(buf[off..].ptr);
            const name_ptr: [*:0]const u8 = @ptrCast(&d.name);
            const name = std.mem.span(name_ptr);
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                const plen = std.mem.len(path);
                var child: [4096]u8 = undefined;
                if (plen + 1 + name.len >= child.len) {
                    rc = -1;
                    break :outer;
                }
                @memcpy(child[0..plen], path[0..plen]);
                child[plen] = '/';
                @memcpy(child[plen + 1 .. plen + 1 + name.len], name);
                child[plen + 1 + name.len] = 0;
                const child_z: [*:0]const u8 = @ptrCast(&child);
                if (d.type == 4) { // DT_DIR
                    if (rmRf(child_z) != 0) {
                        rc = -1;
                        break :outer;
                    }
                } else {
                    const u = std.os.linux.unlinkat(std.posix.AT.FDCWD, child_z, 0);
                    if (std.os.linux.errno(u) != .SUCCESS) {
                        rc = -1;
                        break :outer;
                    }
                }
            }
            off += d.reclen;
        }
    }
    const u = std.os.linux.unlinkat(std.posix.AT.FDCWD, path, std.os.linux.AT.REMOVEDIR);
    if (std.os.linux.errno(u) != .SUCCESS and std.os.linux.errno(u) != .NOENT) rc = -1;
    return rc;
}

// ─── run_shell (dhake.c:1456-1477): fork + exec /bin/sh -c cmd ───────────
fn runShell(cmd: [*:0]const u8) c_int {
    const pid = std.os.linux.fork();
    if (std.os.linux.errno(pid) != .SUCCESS) {
        sysio.writeErrFmt("dhake: failed to fork shell for '{s}': {s}\n", .{ std.mem.span(cmd), std.mem.span(strerror(@intFromEnum(std.os.linux.errno(pid)))) });
        return 2;
    }
    if (pid == 0) {
        // child
        const argv = [_]?[*:0]const u8{ "/bin/sh", "-c", cmd, null };
        const argv_p: [*:null]const ?[*:0]const u8 = @ptrCast(&argv);
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(@constCast(environ));
        _ = std.os.linux.execve("/bin/sh", argv_p, envp);
        sysio.writeErrFmt("dhake: exec '/bin/sh' for '{s}' failed: {s}\n", .{ std.mem.span(cmd), strerr() });
        std.os.linux.exit_group(127);
    }
    // parent
    var status: u32 = 0;
    const w = std.os.linux.waitpid(@intCast(pid), &status, 0);
    if (std.os.linux.errno(w) != .SUCCESS) {
        sysio.writeErrFmt("dhake: waitpid for '{s}': {s}\n", .{ std.mem.span(cmd), std.mem.span(strerror(@intFromEnum(std.os.linux.errno(w)))) });
        return 2;
    }
    if (wifexited(status)) return wexitstatus(status);
    if (wifsignaled(status)) return 128 + wtermsig(status);
    return 2;
}

// ─── action_echo (dhake.c:1574-1595) — echo command text to stdout ───────
fn actionEcho(a: *plan.Action) void {
    if (opts.quiet) return;
    switch (a.kind) {
        .ACT_SHELL => sysio.writeOutFmt("{s}\n", .{std.mem.span(a.a.?)}),
        .ACT_COPY => sysio.writeOutFmt("cp {s} {s}\n", .{ std.mem.span(a.a.?), std.mem.span(a.b.?) }),
        .ACT_MKDIR => if (a.recursive) sysio.writeOutFmt("mkdir -p {s}\n", .{std.mem.span(a.a.?)}) else sysio.writeOutFmt("mkdir {s}\n", .{std.mem.span(a.a.?)}),
        .ACT_RM => if (a.recursive) sysio.writeOutFmt("rm -rf {s}\n", .{std.mem.span(a.a.?)}) else sysio.writeOutFmt("rm {s}\n", .{std.mem.span(a.a.?)}),
        .ACT_TOUCH => sysio.writeOutFmt("touch {s}\n", .{std.mem.span(a.a.?)}),
        .ACT_MOVE => sysio.writeOutFmt("mv {s} {s}\n", .{ std.mem.span(a.a.?), std.mem.span(a.b.?) }),
        .ACT_SYMLINK => sysio.writeOutFmt("ln -s {s} {s}\n", .{ std.mem.span(a.a.?), std.mem.span(a.b.?) }),
        .ACT_CHMOD => sysio.writeOutFmt("chmod {s} {s}\n", .{ std.mem.span(a.b.?), std.mem.span(a.a.?) }),
        .ACT_ECHO => sysio.writeOutFmt("{s}\n", .{std.mem.span(a.a.?)}),
        .ACT_ENV => sysio.writeOutFmt("export {s}={s}\n", .{ std.mem.span(a.a.?), std.mem.span(a.b.?) }),
        .ACT_RUN => {
            sysio.writeOutFmt("{s}", .{std.mem.span(a.av.?[0].?)});
            var i: usize = 1;
            while (i < @as(usize, @intCast(a.nav))) : (i += 1)
                sysio.writeOutFmt(" {s}", .{std.mem.span(a.av.?[i].?)});
            sysio.writeOut("\n");
        },
    }
    // C flushes stdout after echo; our writes are unbuffered raw writes, so no flush needed.
}

// ─── print_action (dhake.c:1598-1617) — dry-run: print without executing ──
pub fn printAction(a: *plan.Action) void {
    switch (a.kind) {
        .ACT_SHELL => sysio.writeOutFmt("{s}\n", .{std.mem.span(a.a.?)}),
        .ACT_COPY => sysio.writeOutFmt("cp {s} {s}\n", .{ std.mem.span(a.a.?), std.mem.span(a.b.?) }),
        .ACT_MKDIR => if (a.recursive) sysio.writeOutFmt("mkdir -p {s}\n", .{std.mem.span(a.a.?)}) else sysio.writeOutFmt("mkdir {s}\n", .{std.mem.span(a.a.?)}),
        .ACT_RM => if (a.recursive) sysio.writeOutFmt("rm -rf {s}\n", .{std.mem.span(a.a.?)}) else sysio.writeOutFmt("rm {s}\n", .{std.mem.span(a.a.?)}),
        .ACT_TOUCH => sysio.writeOutFmt("touch {s}\n", .{std.mem.span(a.a.?)}),
        .ACT_MOVE => sysio.writeOutFmt("mv {s} {s}\n", .{ std.mem.span(a.a.?), std.mem.span(a.b.?) }),
        .ACT_SYMLINK => sysio.writeOutFmt("ln -s {s} {s}\n", .{ std.mem.span(a.a.?), std.mem.span(a.b.?) }),
        .ACT_CHMOD => sysio.writeOutFmt("chmod {s} {s}\n", .{ std.mem.span(a.b.?), std.mem.span(a.a.?) }),
        .ACT_ECHO => sysio.writeOutFmt("echo {s}\n", .{std.mem.span(a.a.?)}),
        .ACT_ENV => sysio.writeOutFmt("export {s}={s}\n", .{ std.mem.span(a.a.?), std.mem.span(a.b.?) }),
        .ACT_RUN => {
            sysio.writeOutFmt("{s}", .{std.mem.span(a.av.?[0].?)});
            var i: usize = 1;
            while (i < @as(usize, @intCast(a.nav))) : (i += 1)
                sysio.writeOutFmt(" {s}", .{std.mem.span(a.av.?[i].?)});
            sysio.writeOut("\n");
        },
    }
}

// ─── run_action (dhake.c:1483-1571) — execute one action, return exit code ─
pub fn runAction(a: *plan.Action) c_int {
    switch (a.kind) {
        .ACT_SHELL => {
            actionEcho(a);
            return runShell(a.a.?);
        },
        .ACT_COPY => {
            actionEcho(a);
            return if (copyFile(a.a.?, a.b.?)) 0 else 1;
        },
        .ACT_MKDIR => {
            actionEcho(a);
            const r = if (a.recursive) mkdirP(a.a.?) else mkdir(a.a.?, 0o755);
            if (r != 0 and errnoVal() != @intFromEnum(std.os.linux.E.EXIST)) {
                sysio.writeErrFmt("dhake: mkdir: {s}\n", .{strerr()});
                return 1;
            }
            return 0;
        },
        .ACT_RM => {
            actionEcho(a);
            const r = if (a.recursive) rmRf(a.a.?) else remove(a.a.?);
            if (r != 0 and errnoVal() != @intFromEnum(std.os.linux.E.NOENT)) {
                sysio.writeErrFmt("dhake: rm: {s}\n", .{strerr()});
                return 1;
            }
            return 0;
        },
        .ACT_TOUCH => {
            actionEcho(a);
            return if (touchFile(a.a.?)) 0 else 1;
        },
        .ACT_MOVE => {
            actionEcho(a);
            if (rename(a.a.?, a.b.?) != 0) {
                sysio.writeErrFmt("dhake: move: {s}\n", .{strerr()});
                return 1;
            }
            return 0;
        },
        .ACT_SYMLINK => {
            actionEcho(a);
            if (symlink(a.a.?, a.b.?) != 0) {
                sysio.writeErrFmt("dhake: symlink: {s}\n", .{strerr()});
                return 1;
            }
            return 0;
        },
        .ACT_CHMOD => {
            actionEcho(a);
            const mode_s = std.mem.span(a.b.?);
            const mode = std.fmt.parseInt(u32, mode_s, 8) catch {
                sysio.writeErrFmt("dhake: chmod: invalid mode '{s}' (expected octal 0..7777)\n", .{mode_s});
                return 1;
            };
            if (mode > 0o7777) {
                sysio.writeErrFmt("dhake: chmod: invalid mode '{s}' (expected octal 0..7777)\n", .{mode_s});
                return 1;
            }
            if (chmod(a.a.?, mode) != 0) {
                sysio.writeErrFmt("dhake: chmod: {s}\n", .{strerr()});
                return 1;
            }
            return 0;
        },
        .ACT_ECHO => {
            actionEcho(a);
            return 0;
        },
        .ACT_ENV => {
            actionEcho(a);
            _ = setenv(a.a.?, a.b.?, 1);
            return 0;
        },
        .ACT_RUN => {
            actionEcho(a);
            const pid = std.os.linux.fork();
            if (std.os.linux.errno(pid) != .SUCCESS) {
                sysio.writeErrFmt("dhake: fork failed for Run: {s}\n", .{std.mem.span(strerror(@intFromEnum(std.os.linux.errno(pid))))});
                return 2;
            }
            if (pid == 0) {
                // child
                const argv: [*]const ?[*:0]const u8 = @ptrCast(a.av.?);
                _ = execvp(a.a.?, argv);
                sysio.writeErrFmt("dhake: execvp '{s}' failed: {s}\n", .{ std.mem.span(a.a.?), strerr() });
                std.os.linux.exit_group(2);
            }
            // parent
            var status: u32 = 0;
            _ = std.os.linux.waitpid(@intCast(pid), &status, 0);
            if (wifexited(status)) return wexitstatus(status);
            return 2; // signaled
        },
    }
    return 2;
}
