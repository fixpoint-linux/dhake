// watch.zig — inotify-based file watching for --watch mode.
//
// Ports dhake.c:1764-1780 (base_name/dir_name), 1784-1823 (collect_watch_files),
// 1828-1904 (setup_watch), 1908-1946 (wait_for_change).
//
// Uses std.os.linux.inotify_init1/inotify_add_watch (raw usize rc decoded via
// std.os.linux.errno) and std.os.linux.inotify_event (which has getName()).
const std = @import("std");
const opts = @import("opts.zig");
const sysio = @import("sysio.zig");
const plan = @import("plan.zig");

extern fn strerror(errnum: c_int) [*:0]const u8;

// Holds the errno captured when setupWatch returns -1 (mirrors C's errno for
// the caller's strerror message).
pub var last_errno: c_int = 0;

// inotify watch masks (Linux ABI, verified — dhake.c:1880).
const IN_MODIFY: u32 = 0x2;
const IN_CLOSE_WRITE: u32 = 0x8;
const IN_MOVED_TO: u32 = 0x80;
const IN_CREATE: u32 = 0x100;
const IN_DELETE: u32 = 0x200;
const WATCH_MASK: u32 = IN_CLOSE_WRITE | IN_MOVED_TO | IN_MODIFY | IN_CREATE | IN_DELETE;

// One inotify watch on a parent directory (dhake.c:1757-1762).
pub const WatchDir = struct {
    wd: c_int,
    dir: []u8, // heap-allocated dir path (owned)
    files: [][*:0]const u8, // basenames we care about in this dir (array owned, entries borrowed)
};

// Return basename of a path (pointer into the original string).
fn baseName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |p| {
        return path[p + 1 ..];
    }
    return path;
}

// Return directory name of a path (heap-allocated; caller must free).
fn dirName(path: []const u8) []u8 {
    const c = std.heap.c_allocator;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |p| {
        if (p == 0) return c.dupe(u8, "/") catch opts.die("out of memory");
        return c.dupe(u8, path[0..p]) catch opts.die("out of memory");
    }
    return c.dupe(u8, ".") catch opts.die("out of memory");
}

// Collect all source-file dependencies + buildfile for watching.
// Returns a heap-allocated slice of file paths (caller frees with
// c_allocator.free). *n_out is the count.
pub fn collectWatchFiles(b: *plan.Build, buildfile: []const u8, n_out: *usize) [][*:0]const u8 {
    const c = std.heap.c_allocator;

    // Count: worst case = all deps of all targets + buildfile.
    var count: usize = 1; // buildfile
    var t = b.targets;
    while (t) |tt| : (t = tt.next) {
        if (tt.state != 1) continue; // only the requested subgraph
        var j: c_int = 0;
        while (j < tt.ndeps) : (j += 1) {
            if (tt.dep_targets.?[@intCast(j)] == null) count += 1; // source file
        }
    }

    const result = c.alloc([*:0]const u8, count) catch opts.die("out of memory");
    var n: usize = 0;

    // Add buildfile first.
    result[n] = @ptrCast(buildfile.ptr);
    n += 1;

    // Add source-file deps (dep_targets[j] == NULL means it's a source path).
    t = b.targets;
    while (t) |tt| : (t = tt.next) {
        if (tt.state != 1) continue; // only the requested subgraph
        var j: c_int = 0;
        while (j < tt.ndeps) : (j += 1) {
            if (tt.dep_targets.?[@intCast(j)] == null) {
                const dep = tt.deps.?[@intCast(j)].?;
                // Dedupe: check if already in result.
                var found = false;
                for (result[0..n]) |r| {
                    if (std.mem.eql(u8, std.mem.span(r), std.mem.span(dep))) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    result[n] = dep;
                    n += 1;
                }
            }
        }
    }

    n_out.* = n;
    return result[0..n];
}

// Set up inotify watches on parent directories of the given files.
// Returns the inotify fd, or -1 on error. dirs_out and ndirs_out are set to
// the array of WatchDir structs (caller must free).
pub fn setupWatch(files: []const [*:0]const u8, dirs_out: *[]WatchDir) c_int {
    const c = std.heap.c_allocator;

    const lfd = std.os.linux.inotify_init1(0);
    if (std.os.linux.errno(lfd) != .SUCCESS) {
        last_errno = @intFromEnum(std.os.linux.errno(lfd));
        return -1;
    }
    const ifd: c_int = @intCast(lfd);

    var dirs: []WatchDir = &.{};

    for (files) |file| {
        const file_s = std.mem.span(file);
        const dir = dirName(file_s);

        // Check if we already have a watch for this dir.
        var found: isize = -1;
        for (dirs, 0..) |d, j| {
            if (std.mem.eql(u8, d.dir, dir)) {
                found = @intCast(j);
                break;
            }
        }

        const bn = baseName(file_s);
        if (found >= 0) {
            // Add file to existing WatchDir.
            const d = &dirs[@intCast(found)];
            var already = false;
            for (d.files) |f| {
                if (std.mem.eql(u8, std.mem.span(f), bn)) {
                    already = true;
                    break;
                }
            }
            if (!already) {
                d.files = c.realloc(d.files, d.files.len + 1) catch {
                    c.free(dir);
                    _ = std.os.linux.close(ifd);
                    return -1;
                };
                d.files[d.files.len - 1] = @ptrCast(bn.ptr);
            }
            c.free(dir);
        } else {
            // Create new WatchDir.
            dirs = c.realloc(dirs, dirs.len + 1) catch {
                c.free(dir);
                _ = std.os.linux.close(ifd);
                return -1;
            };
            const d = &dirs[dirs.len - 1];
            d.dir = dir; // ownership transferred
            d.wd = -1;
            d.files = c.alloc([*:0]const u8, 1) catch {
                _ = std.os.linux.close(ifd);
                return -1;
            };
            d.files[0] = @ptrCast(bn.ptr);

            // Add inotify watch on this directory.
            const dir_z: [*:0]const u8 = @ptrCast(d.dir.ptr);
            const lwd = std.os.linux.inotify_add_watch(ifd, dir_z, WATCH_MASK);
            if (std.os.linux.errno(lwd) != .SUCCESS) {
                const lerr = std.os.linux.errno(lwd);
                if (lerr == .NOENT) {
                    // Dir may not exist yet (e.g. a generated-source dir the
                    // build creates). Skip it rather than killing the whole
                    // dev-loop; its changes just won't be seen until dhake
                    // re-arms after the next rebuild.
                    sysio.writeErrFmt("dhake: --watch: warning: cannot watch '{s}' (dir missing); changes there won't trigger a rebuild\n", .{d.dir});
                    d.wd = -1; // never matches; harmless
                    continue;
                }
                _ = std.os.linux.close(ifd);
                last_errno = @intFromEnum(lerr);
                return -1;
            }
            d.wd = @intCast(lwd);
        }
    }

    dirs_out.* = dirs;
    return ifd;
}

// Wait for a change in any watched file. Returns 1 if a watched file changed,
// -1 on error, 0 on EOF.
pub fn waitForChange(ifd: c_int, dirs: []WatchDir) c_int {
    var buf: [4096]u8 = undefined;
    while (true) {
        // std.posix.read already retries on EINTR internally and returns 0 on
        // EOF, so we only distinguish EOF (0) from error (-1) here.
        const n = std.posix.read(ifd, &buf) catch return -1;
        if (n == 0) return 0; // EOF

        // Process all events in the buffer.
        var p: usize = 0;
        while (p < n) {
            const ev = @as(*align(1) const std.os.linux.inotify_event, @ptrCast(buf[p..].ptr));
            const ev_len: usize = ev.len;

            // Check if this is a valid event with a filename.
            if (ev_len > 0) {
                // The kernel NUL-terminates the name and ev.len includes the
                // terminator, so filename[ev_len-1] == '\0'. Never write past
                // the buffer: writing filename[ev_len] is a 1-byte OOB when the
                // event ends exactly at the 4096-byte read boundary.
                if ((n - (p + @sizeOf(std.os.linux.inotify_event))) < ev_len) break; // truncated event
                const filename = buf[p + @sizeOf(std.os.linux.inotify_event) ..][0..ev_len];
                // Skip the trailing NUL for comparison.
                const name = filename[0 .. ev_len - 1];
                for (dirs) |d| {
                    if (d.wd == ev.wd) {
                        for (d.files) |f| {
                            if (std.mem.eql(u8, std.mem.span(f), name)) return 1; // matched
                        }
                        break;
                    }
                }
            }

            // Advance to next event.
            p += @sizeOf(std.os.linux.inotify_event) + ev_len;
        }
    }
}

// strerror for error messages (used by main.zig's watch error path).
pub fn errstr(errnum: c_int) []const u8 {
    return std.mem.span(strerror(errnum));
}
