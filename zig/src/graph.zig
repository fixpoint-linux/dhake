// graph.zig — dependency graph: find_target/filter_arch/resolve_deps/
// topo_order (dhake.c:1006-1088), reachability DFS (dhake.c:2587-2602),
// collect_transitive_deps (dhake.c:1666-1743) and collect_watch_files
// (dhake.c:1784-1823 — stubbed here, fully ported in U5).
const std = @import("std");
const opts = @import("opts.zig");
const plan = @import("plan.zig");

// find_target (dhake.c:1006-1010)
pub fn findTarget(b: *plan.Build, name: []const u8) ?*plan.Target {
    var t = b.targets;
    while (t) |tt| : (t = tt.next) {
        if (std.mem.eql(u8, std.mem.span(tt.name), name)) return tt;
    }
    return null;
}

// filter_arch (dhake.c:1013-1026): drop targets whose arch != arch_value.
pub fn filterArch(b: *plan.Build) void {
    const archv = opts.arch_value orelse return;
    var prevp: *?*plan.Target = &b.targets;
    var t = b.targets;
    while (t) |tt| {
        const next = tt.next;
        if (tt.arch != null and !std.mem.eql(u8, std.mem.span(tt.arch.?), std.mem.span(archv))) {
            // remove tt from the intrusive list
            prevp.* = next;
            b.ntargets -= 1;
        } else {
            prevp = &tt.next;
        }
        t = next;
    }
}

// resolve_deps (dhake.c:1030-1036): map each dep name to a Target* (NULL =
// plain source file, not a build target).
pub fn resolveDeps(b: *plan.Build) void {
    var t = b.targets;
    while (t) |tt| : (t = tt.next) {
        const a = plan.arena() orelse opts.die("out of memory");
        const nd: usize = @intCast(if (tt.ndeps != 0) tt.ndeps else 1);
        const arr = plan.allocArr(a, ?*plan.Target, nd);
        var i: usize = 0;
        while (i < @as(usize, @intCast(tt.ndeps))) : (i += 1) {
            arr[i] = findTarget(b, std.mem.span(tt.deps.?[i].?));
        }
        tt.dep_targets = arr;
    }
}

// Iterative DFS emitting a topo order (deps before dependents); detects cycles.
const Frame = struct { t: *plan.Target, i: c_int };

pub fn topoOrder(b: *plan.Build, n_out: *usize) []*plan.Target {
    const c = std.heap.c_allocator;
    const cap: usize = @intCast(if (b.ntargets != 0) b.ntargets else 1);
    var order = c.alloc(*plan.Target, cap) catch opts.die("out of memory");
    const stk = c.alloc(Frame, cap) catch opts.die("out of memory");
    defer c.free(stk);
    var n: usize = 0;

    var root = b.targets;
    while (root) |r| : (root = r.next) {
        if (r.state != 0) continue;
        var top: usize = 0;
        stk[top] = .{ .t = r, .i = 0 };
        top += 1;
        r.state = 1;
        while (top > 0) {
            const f = &stk[top - 1];
            if (f.i < f.t.ndeps) {
                const d = f.t.dep_targets.?[@intCast(f.i)];
                f.i += 1;
                if (d == null) continue; // source-file dep: not a graph node
                const dd = d.?;
                if (dd.state == 1)
                    opts.dieFmt("dependency cycle detected involving target '{s}'", .{std.mem.span(dd.name)});
                if (dd.state == 0) {
                    dd.state = 1;
                    stk[top] = .{ .t = dd, .i = 0 };
                    top += 1;
                }
            } else {
                f.t.state = 2;
                order[n] = f.t;
                n += 1;
                top -= 1;
            }
        }
    }
    n_out.* = n;
    return order[0..n];
}

// reachability DFS (dhake.c:2587-2602): mark only the subgraph reachable from
// roots (roots + transitive deps). state 0 = not needed, 1 = needed. Caller
// must have reset every target's state to 0 first (mirrors C).
pub fn markReachable(roots: []*plan.Target, order: []*plan.Target) void {
    const c = std.heap.c_allocator;
    const cap: usize = if (order.len != 0) order.len else 1;
    const stk = c.alloc(*plan.Target, cap) catch opts.die("out of memory");
    defer c.free(stk);
    var top: usize = 0;
    for (roots) |r| {
        if (r.state == 0) {
            r.state = 1;
            stk[top] = r;
            top += 1;
        }
    }
    while (top > 0) {
        top -= 1;
        const t = stk[top];
        var j: usize = 0;
        while (j < @as(usize, @intCast(t.ndeps))) : (j += 1) {
            const d = t.dep_targets.?[j];
            if (d != null and d.?.state == 0) {
                d.?.state = 1;
                stk[top] = d.?;
                top += 1;
            }
        }
    }
}

// collect_transitive_deps (dhake.c:1666-1743): names of all targets reachable
// from t's deps (excluding t itself), in a post-order DFS. Used by U3's
// lockfile/verify/explain paths; not called by the U2 build loop.
pub fn collectTransitiveDeps(b: *plan.Build, t: *plan.Target, n_out: *usize) [][*:0]const u8 {
    const c = std.heap.c_allocator;
    const total: usize = @intCast(b.ntargets);
    const visited = c.alloc(bool, total) catch opts.die("out of memory");
    defer c.free(visited);
    @memset(visited, false);

    // Map target pointer to an index.
    const all = c.alloc(*plan.Target, total) catch opts.die("out of memory");
    defer c.free(all);
    var ntargets: usize = 0;
    {
        var p = b.targets;
        while (p) |pt| : (p = pt.next) {
            all[ntargets] = pt;
            ntargets += 1;
        }
    }
    const findIdx = struct {
        fn f(arr: [*]*plan.Target, n: usize, d: *plan.Target) isize {
            var k: isize = 0;
            while (k < @as(isize, @intCast(n))) : (k += 1) if (arr[@intCast(k)] == d) return k;
            return -1;
        }
    }.f;

    const stk = c.alloc(Frame, total) catch opts.die("out of memory");
    defer c.free(stk);
    // NOTE: `result` is deliberately NOT freed here — the caller owns it
    // (matches C, where collect_transitive_deps returns a malloc'd array the
    // caller frees).
    const result = c.alloc([*:0]const u8, total) catch opts.die("out of memory");
    var top: usize = 0;
    var result_count: usize = 0;

    // Seed DFS from each dep_target of t.
    var j0: usize = 0;
    while (j0 < @as(usize, @intCast(t.ndeps))) : (j0 += 1) {
        const d = t.dep_targets.?[j0];
        if (d == null) continue; // source file, not a target
        const idx = findIdx(all.ptr, ntargets, d.?);
        if (idx < 0) continue;
        const iu: usize = @intCast(idx);
        if (!visited[iu]) {
            visited[iu] = true;
            stk[top] = .{ .t = d.?, .i = 0 };
            top += 1;
        }
    }

    while (top > 0) {
        const f = &stk[top - 1];
        if (f.i < f.t.ndeps) {
            const d = f.t.dep_targets.?[@intCast(f.i)];
            f.i += 1;
            if (d == null) continue;
            const idx = findIdx(all.ptr, ntargets, d.?);
            if (idx < 0) continue;
            const iu: usize = @intCast(idx);
            if (!visited[iu]) {
                visited[iu] = true;
                stk[top] = .{ .t = d.?, .i = 0 };
                top += 1;
            }
        } else {
            if (f.t != t) {
                result[result_count] = f.t.name;
                result_count += 1;
            }
            top -= 1;
        }
    }
    n_out.* = result_count;
    return result[0..result_count];
}

// collect_watch_files (dhake.c:1784-1823) — fully ported in U5. U2 stub.
pub fn collectWatchFiles(b: *plan.Build, buildfile: []const u8, n_out: *usize) [][*:0]const u8 {
    _ = b;
    _ = buildfile;
    const c = std.heap.c_allocator;
    n_out.* = 0;
    return c.alloc([*:0]const u8, 0) catch opts.die("out of memory");
}
