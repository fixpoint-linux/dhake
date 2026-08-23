// report.zig — lockfile / SBOM output, verify mode, and explain mode.
//
// Ports dhake.c:1639-1661 (json_escape_str), 1666-1743 (collect_transitive_deps
// — implemented in graph.zig), 1948-2038 (write_lockfile), 2042-2121 (run_verify),
// 2127-2236 (target_dirty_explain), 2240-2258 (run_explain).
//
// write_lockfile emits byte-identical JSON to C (2-space indent, exact key order,
// outputHash/depHashes shapes) and prints 'dhake: wrote lockfile %s' on stdout.
const std = @import("std");
const plan = @import("plan.zig");
const opts = @import("opts.zig");
const sysio = @import("sysio.zig");
const graph = @import("graph.zig");
const hash = @import("hash.zig");

const gpa = std.heap.c_allocator;

// ─── JSON string escaping (dhake.c:1639-1661) ────────────────────────────
// Append the escaped JSON representation of s to `out`.
pub fn jsonEscapeStr(out: *std.ArrayList(u8), s: []const u8) void {
    out.appendSlice(gpa, "\"") catch {};
    for (s) |ch| {
        switch (ch) {
            '"' => out.appendSlice(gpa, "\\\"") catch {},
            '\\' => out.appendSlice(gpa, "\\\\") catch {},
            8 => out.appendSlice(gpa, "\\b") catch {},
            12 => out.appendSlice(gpa, "\\f") catch {},
            '\n' => out.appendSlice(gpa, "\\n") catch {},
            '\r' => out.appendSlice(gpa, "\\r") catch {},
            '\t' => out.appendSlice(gpa, "\\t") catch {},
            else => {
                if (ch < 32) {
                    var tmp: [6]u8 = undefined;
                    const t = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{ch}) catch "\\u0000";
                    out.appendSlice(gpa, t) catch {};
                } else {
                    out.append(gpa, ch) catch {};
                }
            },
        }
    }
    out.appendSlice(gpa, "\"") catch {};
}

// ─── Lockfile / SBOM write (dhake.c:1948-2038) ───────────────────────────
// Write lockfile JSON to path. Only called on successful build (failed==0).
pub fn writeLockfile(b: *plan.Build, path: []const u8) void {
    const pathz: [*:0]const u8 = @ptrCast(path.ptr);
    const f = fopen(pathz, "w") orelse {
        sysio.writeErrFmt("dhake: warning: cannot open lockfile '{s}': {s}\n", .{ path, std.mem.span(strerror(__errno_location().*)) });
        return;
    };
    defer _ = fclose(f);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    // Header
    out.appendSlice(gpa, "{\n") catch return;
    out.appendSlice(gpa, "  \"format\": \"dhake.lock\",\n") catch return;
    out.appendSlice(gpa, "  \"version\": 1,\n") catch return;
    out.appendSlice(gpa, "  \"default\": ") catch return;
    if (b.default_name) |dn| {
        jsonEscapeStr(&out, std.mem.span(dn));
    } else {
        out.appendSlice(gpa, "null") catch return;
    }
    out.appendSlice(gpa, ",\n") catch return;
    out.appendSlice(gpa, "  \"targets\": [\n") catch return;

    // Each target in buildfile order
    var first_target = true;
    var t = b.targets;
    while (t) |tt| : (t = tt.next) {
        if (!first_target) out.appendSlice(gpa, ",\n") catch return;
        first_target = false;

        out.appendSlice(gpa, "    {\n") catch return;
        out.appendSlice(gpa, "      \"name\": ") catch return;
        jsonEscapeStr(&out, std.mem.span(tt.name));
        out.appendSlice(gpa, ",\n") catch return;

        // phony
        if (tt.phony) {
            out.appendSlice(gpa, "      \"phony\": true,\n") catch return;
        } else {
            out.appendSlice(gpa, "      \"phony\": false,\n") catch return;
        }

        // deps
        out.appendSlice(gpa, "      \"deps\": [") catch return;
        var i: c_int = 0;
        while (i < tt.ndeps) : (i += 1) {
            if (i > 0) out.appendSlice(gpa, ", ") catch return;
            jsonEscapeStr(&out, std.mem.span(tt.deps.?[@intCast(i)].?));
        }
        out.appendSlice(gpa, "],\n") catch return;

        // transitiveDeps
        var n_trans: usize = 0;
        const trans_deps = graph.collectTransitiveDeps(b, tt, &n_trans);
        out.appendSlice(gpa, "      \"transitiveDeps\": [") catch return;
        var ti: usize = 0;
        while (ti < n_trans) : (ti += 1) {
            if (ti > 0) out.appendSlice(gpa, ", ") catch return;
            jsonEscapeStr(&out, std.mem.span(trans_deps[ti]));
        }
        out.appendSlice(gpa, "],\n") catch return;
        std.heap.c_allocator.free(trans_deps);

        // outputHash
        out.appendSlice(gpa, "      \"outputHash\": ") catch return;
        if (tt.phony) {
            out.appendSlice(gpa, "null") catch return;
        } else {
            var actual_hash: [65]u8 = undefined;
            if (hash.fileSha256Hex(tt.name, &actual_hash)) {
                out.appendSlice(gpa, "{\"algorithm\": \"sha256\", \"value\": \"sha256:") catch return;
                out.appendSlice(gpa, actual_hash[0..64]) catch return;
                out.appendSlice(gpa, "\"}") catch return;
            } else {
                out.appendSlice(gpa, "null") catch return;
            }
        }
        out.appendSlice(gpa, ",\n") catch return;

        // depHashes
        out.appendSlice(gpa, "      \"depHashes\": [") catch return;
        var first_dep_hash = true;
        var j: c_int = 0;
        while (j < tt.ndep_hash) : (j += 1) {
            var actual_hash: [65]u8 = undefined;
            if (hash.fileSha256Hex(tt.dep_hash.?[@intCast(j)].path.?, &actual_hash)) {
                if (!first_dep_hash) out.appendSlice(gpa, ", ") catch return;
                first_dep_hash = false;
                out.appendSlice(gpa, "{\"path\": ") catch return;
                jsonEscapeStr(&out, std.mem.span(tt.dep_hash.?[@intCast(j)].path.?));
                out.appendSlice(gpa, ", \"algorithm\": \"sha256\", \"value\": \"sha256:") catch return;
                out.appendSlice(gpa, actual_hash[0..64]) catch return;
                out.appendSlice(gpa, "\"}") catch return;
            }
        }
        out.appendSlice(gpa, "]\n") catch return;

        out.appendSlice(gpa, "    }") catch return;
    }

    out.appendSlice(gpa, "\n  ]\n") catch return;
    out.appendSlice(gpa, "}\n") catch return;

    _ = fwrite(out.items.ptr, 1, out.items.len, f);
    sysio.writeOutFmt("dhake: wrote lockfile {s}\n", .{path});
}

// ─── Verify mode (dhake.c:2042-2121) ─────────────────────────────────────
// Verify all pinned hashes and up-to-dateness without running recipes.
// Returns 0 if everything is clean, nonzero if anything is dirty or mismatched.
pub fn runVerify(order: []*plan.Target) c_int {
    var failed: c_int = 0;
    for (order) |t| {
        if (t.state != 1) continue; // only requested subgraph

        // FIRST verify all dep hashes non-fatally
        var j: c_int = 0;
        while (j < t.ndep_hash) : (j += 1) {
            const dh = &t.dep_hash.?[@intCast(j)];
            const path_s = std.mem.span(dh.path.?);
            var got: [65]u8 = undefined;
            if (!hash.fileHash(&dh.hash, dh.path.?, &got)) {
                sysio.writeOutFmt("target '{s}': dep hash: file '{s}' not found\n", .{ std.mem.span(t.name), path_s });
                failed = 1;
            } else if (!std.mem.eql(u8, got[0..64], std.mem.span(dh.hash.hex.?))) {
                sysio.writeOutFmt("target '{s}': dep hash mismatch for '{s}': expected {s}, got {s}:{s}\n", .{ std.mem.span(t.name), path_s, std.mem.span(dh.hash.spec.?), hash.hashAlgoName(dh.hash.alg), got[0..64] });
                failed = 1;
            }
        }

        // Handle phony targets
        if (t.phony) {
            sysio.writeOutFmt("dhake: verify: '{s}' phony (always runs)\n", .{std.mem.span(t.name)});
            t.dirty = true;
            continue;
        }

        // Compute dirty with the same logic as the build launch block
        const hash_result = hash.hashUptodateDirty(t);
        var dirty: bool = undefined;
        if (hash_result >= 0) {
            dirty = (hash_result == 1);
        } else {
            var texists = false;
            const tm = sysio.fileMtimeNs(t.name, &texists);
            dirty = !texists;
            if (!dirty) {
                var j2: c_int = 0;
                while (j2 < t.ndeps) : (j2 += 1) {
                    const d = t.dep_targets.?[@intCast(j2)];
                    if (d) |dd| {
                        if (dd.dirty) {
                            dirty = true;
                            break;
                        }
                        var dexists = false;
                        const dm = sysio.fileMtimeNs(dd.name, &dexists);
                        if (!dexists) {
                            dirty = true;
                            break;
                        }
                        if (dm > tm) {
                            dirty = true;
                            break;
                        }
                    } else {
                        var sexists = false;
                        const sm = sysio.fileMtimeNs(t.deps.?[@intCast(j2)].?, &sexists);
                        if (!sexists) {
                            dirty = true;
                            break;
                        }
                        if (sm > tm) {
                            dirty = true;
                            break;
                        }
                    }
                }
            }
        }
        t.dirty = dirty;

        if (dirty) {
            sysio.writeOutFmt("dhake: verify: '{s}' needs rebuild\n", .{std.mem.span(t.name)});
            failed = 1;
        } else {
            // up-to-date, non-phony: verify output hash if present
            if (t.out_hash != null) {
                var got: [65]u8 = undefined;
                if (!hash.fileHash(t.out_hash.?, t.name, &got)) {
                    sysio.writeOutFmt("target '{s}': output not found\n", .{std.mem.span(t.name)});
                    failed = 1;
                } else if (!std.mem.eql(u8, got[0..64], std.mem.span(t.out_hash.?.hex.?))) {
                    sysio.writeOutFmt("target '{s}': output hash mismatch: expected {s}, got {s}:{s}\n", .{ std.mem.span(t.name), std.mem.span(t.out_hash.?.spec.?), hash.hashAlgoName(t.out_hash.?.alg), got[0..64] });
                    failed = 1;
                } else {
                    sysio.writeOutFmt("dhake: verify: '{s}' up to date\n", .{std.mem.span(t.name)});
                }
            } else {
                sysio.writeOutFmt("dhake: verify: '{s}' up to date\n", .{std.mem.span(t.name)});
            }
        }
    }
    return failed;
}

// ─── Explain a single target (dhake.c:2127-2236) ─────────────────────────
// Fills `reason` (a []u8 buffer, cap bytes) with a human-readable reason if
// dirty. Returns 1 if dirty, 0 if clean.
//
// bufPrint does NOT NUL-terminate; every path that writes a reason must leave a
// trailing NUL so the caller can treat the buffer as a C string (C's
// target_dirty_explain snprintf always terminates). setReason does both.
fn setReason(reason: []u8, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(reason, fmt, args) catch return;
    if (s.len < reason.len) reason[s.len] = 0;
}

fn targetDirtyExplain(t: *plan.Target, reason: []u8) bool {
    if (t.phony) {
        const msg = "phony target (always runs)";
        @memcpy(reason[0..msg.len], msg);
        reason[msg.len] = 0;
        return true;
    }

    // Try content-addressed path first
    const hash_result = hash.hashUptodateDirty(t);
    if (hash_result >= 0) {
        if (hash_result == 0) {
            reason[0] = 0;
            return false; // clean
        }
        // hash_result == 1: dirty. Re-derive the reason from content checks.
        var texists = false;
        _ = sysio.fileMtimeNs(t.name, &texists);
        if (!texists) {
            setReason(reason, "output \"{s}\" does not exist", .{std.mem.span(t.name)});
            return true;
        }
        // Check target deps
        var j: c_int = 0;
        while (j < t.ndeps) : (j += 1) {
            const d = t.dep_targets.?[@intCast(j)];
            if (d != null and d.?.dirty) {
                setReason(reason, "\"{s}\" needs rebuild", .{std.mem.span(d.?.name)});
                return true;
            }
        }
        // Check pinned source deps
        const tm = sysio.fileMtimeNs(t.name, null);
        j = 0;
        while (j < t.ndeps) : (j += 1) {
            const d = t.dep_targets.?[@intCast(j)];
            if (d != null) continue;
            const path = t.deps.?[@intCast(j)].?;
            var pin: ?*const plan.DepHash = null;
            var k: c_int = 0;
            while (k < t.ndep_hash) : (k += 1) {
                if (std.mem.eql(u8, std.mem.span(t.dep_hash.?[@intCast(k)].path.?), std.mem.span(path))) {
                    pin = &t.dep_hash.?[@intCast(k)];
                    break;
                }
            }
            if (pin) |p| {
                var got: [65]u8 = undefined;
                if (!hash.fileHash(&p.hash, path, &got)) {
                    setReason(reason, "input \"{s}\" does not exist", .{std.mem.span(path)});
                    return true;
                }
                if (!std.mem.eql(u8, got[0..64], std.mem.span(p.hash.hex.?))) {
                    setReason(reason, "input \"{s}\" hash changed (expected {s}, got {s}:{s})", .{ std.mem.span(path), std.mem.span(p.hash.spec.?), hash.hashAlgoName(p.hash.alg), got[0..64] });
                    return true;
                }
            } else {
                // Unpinned source dep: mtime fallback
                var sexists = false;
                const sm = sysio.fileMtimeNs(path, &sexists);
                if (!sexists) {
                    setReason(reason, "input \"{s}\" does not exist", .{std.mem.span(path)});
                    return true;
                }
                if (sm > tm) {
                    setReason(reason, "input \"{s}\" is newer than \"{s}\"", .{ std.mem.span(path), std.mem.span(t.name) });
                    return true;
                }
            }
        }
        // Fallback for content path dirty but no specific reason found
        const msg = "input content changed";
        @memcpy(reason[0..msg.len], msg);
        reason[msg.len] = 0;
        return true;
    }

    // mtime path
    var texists = false;
    const tm = sysio.fileMtimeNs(t.name, &texists);
    if (!texists) {
        setReason(reason, "output \"{s}\" does not exist", .{std.mem.span(t.name)});
        return true;
    }

    var j: c_int = 0;
    while (j < t.ndeps) : (j += 1) {
        const d = t.dep_targets.?[@intCast(j)];
        if (d) |dd| {
            if (dd.dirty) {
                setReason(reason, "\"{s}\" needs rebuild", .{std.mem.span(dd.name)});
                return true;
            }
            var dexists = false;
            const dm = sysio.fileMtimeNs(dd.name, &dexists);
            if (!dexists) {
                setReason(reason, "dependency \"{s}\" does not exist", .{std.mem.span(dd.name)});
                return true;
            }
            if (dm > tm) {
                setReason(reason, "\"{s}\" is newer than \"{s}\"", .{ std.mem.span(dd.name), std.mem.span(t.name) });
                return true;
            }
        } else {
            const path = t.deps.?[@intCast(j)].?;
            var sexists = false;
            const sm = sysio.fileMtimeNs(path, &sexists);
            if (!sexists) {
                setReason(reason, "input \"{s}\" does not exist", .{std.mem.span(path)});
                return true;
            }
            if (sm > tm) {
                setReason(reason, "input \"{s}\" is newer than \"{s}\"", .{ std.mem.span(path), std.mem.span(t.name) });
                return true;
            }
        }
    }

    reason[0] = 0;
    return false; // clean
}

// ─── Explain mode (dhake.c:2240-2258) ────────────────────────────────────
// Explain why each target in the requested subgraph is dirty or clean.
// Returns the count of dirty targets (nonzero exit code if any).
pub fn runExplain(order: []*plan.Target) c_int {
    var dirty_count: c_int = 0;
    for (order) |t| {
        if (t.state != 1) continue; // only requested subgraph

        var reason: [512]u8 = undefined;
        const dirty = targetDirtyExplain(t, &reason);
        t.dirty = dirty;

        if (dirty) {
            const reason_s: [*:0]const u8 = @ptrCast(&reason);
            sysio.writeOutFmt("dhake: '{s}' needs rebuild: {s}\n", .{ std.mem.span(t.name), std.mem.span(reason_s) });
            dirty_count += 1;
        } else {
            sysio.writeOutFmt("dhake: '{s}' is up to date\n", .{std.mem.span(t.name)});
        }
    }
    return dirty_count;
}

// ─── Graph dump (dhake.c:2261-2395) ──────────────────────────────────────
// Emit a dependency graph in dot or mermaid format, byte-identical to C.
// Like C, iterates ALL targets in buildfile order regardless of state (graph
// is a topology dump).
pub fn runGraph(b: *plan.Build, format: []const u8) void {
    const is_dot = std.mem.eql(u8, format, "dot");

    if (is_dot) {
        sysio.writeOut("digraph dhake {\n");
        sysio.writeOut("  node [shape=box];\n");
    } else {
        sysio.writeOut("graph TD\n");
    }

    // Track seen source-file leaf nodes to dedupe them.
    var seen: std.ArrayList([*:0]const u8) = .empty;
    defer seen.deinit(gpa);

    var t = b.targets;
    while (t) |tt| : (t = tt.next) {
        // Escape double quotes in name for dot.
        var esc_buf: [1024]u8 = undefined;
        const node_name = if (is_dot) escapeInto(&esc_buf, std.mem.span(tt.name)) else std.mem.span(tt.name);

        if (is_dot) {
            if (tt.out_hash) |oh| {
                if (oh.spec) |spec| {
                    var spec_buf: [1024]u8 = undefined;
                    const spec_s = escapeInto(&spec_buf, std.mem.span(spec));
                    if (tt.phony) {
                        sysio.writeOutFmt("  \"{s}\" [label=\"{s}\\n{s}\",shape=ellipse,style=dashed];\n", .{ node_name, node_name, spec_s });
                    } else {
                        sysio.writeOutFmt("  \"{s}\" [label=\"{s}\\n{s}\",];\n", .{ node_name, node_name, spec_s });
                    }
                } else {
                    if (tt.phony) {
                        sysio.writeOutFmt("  \"{s}\" [shape=ellipse,style=dashed];\n", .{node_name});
                    } else {
                        sysio.writeOutFmt("  \"{s}\" [];\n", .{node_name});
                    }
                }
            } else {
                if (tt.phony) {
                    sysio.writeOutFmt("  \"{s}\" [shape=ellipse,style=dashed];\n", .{node_name});
                } else {
                    sysio.writeOutFmt("  \"{s}\" [];\n", .{node_name});
                }
            }
        } else {
            // Mermaid: use () for phony targets, [] for regular.
            if (tt.phony) {
                if (tt.out_hash) |oh| {
                    if (oh.spec) |spec| {
                        sysio.writeOutFmt("  {s}[(\"{s}\\n{s}\")]\n", .{ node_name, node_name, std.mem.span(spec) });
                    } else {
                        sysio.writeOutFmt("  {s}[(\"{s}\")]\n", .{ node_name, node_name });
                    }
                } else {
                    sysio.writeOutFmt("  {s}[(\"{s}\")]\n", .{ node_name, node_name });
                }
            } else {
                if (tt.out_hash) |oh| {
                    if (oh.spec) |spec| {
                        sysio.writeOutFmt("  {s}[\"{s}\\n{s}\"]\n", .{ node_name, node_name, std.mem.span(spec) });
                    } else {
                        sysio.writeOutFmt("  {s}[\"{s}\"]\n", .{ node_name, node_name });
                    }
                } else {
                    sysio.writeOutFmt("  {s}[\"{s}\"]\n", .{ node_name, node_name });
                }
            }
        }

        // Emit edges for this target's dependencies.
        var j: c_int = 0;
        while (j < tt.ndeps) : (j += 1) {
            const dep_target = tt.dep_targets.?[@intCast(j)];
            if (dep_target) |dtp| {
                // Target dependency.
                var dep_esc: [1024]u8 = undefined;
                const dep_name = if (is_dot) escapeInto(&dep_esc, std.mem.span(dtp.name)) else std.mem.span(dtp.name);
                if (is_dot) {
                    sysio.writeOutFmt("  \"{s}\" -> \"{s}\";\n", .{ node_name, dep_name });
                } else {
                    sysio.writeOutFmt("  {s} --> {s}\n", .{ node_name, dep_name });
                }
            } else {
                // Source file leaf dependency.
                const dep_name = std.mem.span(tt.deps.?[@intCast(j)].?);
                var dseen = false;
                for (seen.items) |s| {
                    if (std.mem.eql(u8, std.mem.span(s), dep_name)) {
                        dseen = true;
                        break;
                    }
                }
                if (!dseen) {
                    seen.append(gpa, tt.deps.?[@intCast(j)].?) catch {};
                    if (is_dot) {
                        sysio.writeOutFmt("  \"{s}\" [shape=ellipse,color=gray];\n", .{dep_name});
                    } else {
                        sysio.writeOutFmt("  {s}[\"{s}\"]\n", .{ dep_name, dep_name });
                    }
                }
                // Emit edge to leaf.
                if (is_dot) {
                    sysio.writeOutFmt("  \"{s}\" -> \"{s}\";\n", .{ node_name, dep_name });
                } else {
                    sysio.writeOutFmt("  {s} --> {s}\n", .{ node_name, dep_name });
                }
            }
        }
    }

    if (is_dot) {
        sysio.writeOut("}\n");
    }
}

// Escape double quotes with backslashes for dot labels (dhake.c:2281-2292).
// Writes the escaped string into buf (clamped to buf.len) and returns the
// used prefix as a slice.
fn escapeInto(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    for (s) |ch| {
        if (n + 2 > buf.len) break;
        if (ch == '"') {
            buf[n] = '\\';
            n += 1;
        }
        buf[n] = ch;
        n += 1;
    }
    return buf[0..n];
}

// ─── extern libc stdio (write_lockfile writes via FILE* for C parity) ────
extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
extern fn fclose(stream: *anyopaque) c_int;
extern fn strerror(errnum: c_int) [*:0]const u8;
extern fn __errno_location() *c_int;
