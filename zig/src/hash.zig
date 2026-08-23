// hash.zig — file hashing + ccache-style build cache + hash-based up-to-date
// checks + hash verification.
//
// Ports dhake.c:324-343 (file_hash/file_sha256_hex), 616-618 (warn_hash_mismatch),
// 641-646 (hash_algo_name), 650-689 (verify_dep_hashes/verify_output_hash),
// 701-738 (hash_uptodate_dirty), 349-503 (cache_key/cache_path/cache_hit/
// cache_restore/cache_store).
//
// The cache key-material layout MUST be byte-identical to C (it feeds sha256
// and a divergent layout would break cache-hit parity with the oracle).
const std = @import("std");
const abi = @import("dhall_abi.zig");
const plan = @import("plan.zig");
const opts = @import("opts.zig");
const sysio = @import("sysio.zig");
const exec = @import("exec.zig");

// When --warn-hash-mismatch is given, a hash mismatch is reported as a warning.
pub var warn_hash_mismatch: bool = false;

// Human-readable name of a hash algorithm (dhake.c:641-646).
pub fn hashAlgoName(alg: plan.HashAlg) []const u8 {
    return switch (alg) {
        .HASH_SHA256 => "sha256",
    };
}

// Compute hash of a file (dhake.c:324-332). out must be a 65-byte buffer.
pub fn fileHash(h: *const plan.Hash, path: [*:0]const u8, out: *[65]u8) bool {
    switch (h.alg) {
        .HASH_SHA256 => return fileSha256Hex(path, out),
    }
}

// Compute SHA-256 hex digest of a file (dhake.c:336-343). Returns false on
// file error. out receives 64 hex chars (index 64 unused here).
pub fn fileSha256Hex(path: [*:0]const u8, out: *[65]u8) bool {
    var len: usize = 0;
    const data = sysio.readFile(std.mem.span(path), &len) orelse return false;
    defer sysio.freeBuf(data);
    abi.sha256_hex(data.ptr, len, out);
    return true;
}

// Verify all dep hashes for a target (dhake.c:650-669). Dies on mismatch unless
// --warn-hash-mismatch. Missing file is always fatal.
pub fn verifyDepHashes(t: *plan.Target) c_int {
    var i: c_int = 0;
    while (i < t.ndep_hash) : (i += 1) {
        const dh = &t.dep_hash.?[@intCast(i)];
        const path_s = std.mem.span(dh.path.?);
        var got: [65]u8 = undefined;
        if (!fileHash(&dh.hash, dh.path.?, &got))
            opts.dieFmt("target '{s}': dep hash verification failed: file '{s}' not found", .{ std.mem.span(t.name), path_s });
        if (!std.mem.eql(u8, got[0..64], std.mem.span(dh.hash.hex.?))) {
            if (warn_hash_mismatch) {
                sysio.writeErrFmt("dhake: warning: target '{s}': dep hash mismatch for '{s}': expected {s}, got {s}:{s}\n", .{ std.mem.span(t.name), path_s, std.mem.span(dh.hash.spec.?), hashAlgoName(dh.hash.alg), got[0..64] });
            } else {
                opts.dieFmt("target '{s}': dep hash mismatch for '{s}': expected {s}, got {s}", .{ std.mem.span(t.name), path_s, std.mem.span(dh.hash.spec.?), got[0..64] });
            }
        }
    }
    return 0;
}

// Verify output hash for a target (dhake.c:673-689). Dies on mismatch unless
// --warn-hash-mismatch, in which case returns 1 on mismatch. Missing file fatal.
pub fn verifyOutputHash(t: *plan.Target) c_int {
    var got: [65]u8 = undefined;
    if (!fileHash(t.out_hash.?, t.name, &got))
        opts.dieFmt("target '{s}': output hash verification failed: file '{s}' not found", .{ std.mem.span(t.name), std.mem.span(t.name) });
    if (!std.mem.eql(u8, got[0..64], std.mem.span(t.out_hash.?.hex.?))) {
        if (warn_hash_mismatch) {
            sysio.writeErrFmt("dhake: warning: target '{s}': output hash mismatch: expected {s}, got {s}:{s}\n", .{ std.mem.span(t.name), std.mem.span(t.out_hash.?.spec.?), hashAlgoName(t.out_hash.?.alg), got[0..64] });
            return 1;
        }
        opts.dieFmt("target '{s}': output hash mismatch: expected {s}, got {s}", .{ std.mem.span(t.name), std.mem.span(t.out_hash.?.spec.?), got[0..64] });
    }
    return 0;
}

// Hash-based up-to-date check (dhake.c:701-738). Returns: 1 = dirty, 0 =
// up-to-date, -1 = not applicable (see C comment for semantics).
pub fn hashUptodateDirty(t: *plan.Target) c_int {
    if (!opts.hash_uptodate or t.phony or t.ndep_hash == 0) return -1;

    // Output must exist
    var texists = false;
    _ = sysio.fileMtimeNs(t.name, &texists);
    if (!texists) return 1;

    // A target-dep that will be rebuilt forces a rebuild of this target too
    var j: c_int = 0;
    while (j < t.ndeps) : (j += 1) {
        const d = t.dep_targets.?[@intCast(j)];
        if (d != null and d.?.dirty) return 1;
    }

    const tm = sysio.fileMtimeNs(t.name, null);
    j = 0;
    while (j < t.ndeps) : (j += 1) {
        const d = t.dep_targets.?[@intCast(j)];
        if (d != null) continue; // target deps handled above
        const path = t.deps.?[@intCast(j)].?;
        // Pinned source dep? compare by content.
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
            if (!fileHash(&p.hash, path, &got)) return 1; // missing input
            if (!std.mem.eql(u8, got[0..64], std.mem.span(p.hash.hex.?))) return 1; // content changed
        } else {
            // Unpinned source dep: mtime fallback (source newer than output)
            var sexists = false;
            const sm = sysio.fileMtimeNs(path, &sexists);
            if (!sexists) return 1;
            if (sm > tm) return 1;
        }
    }
    return 0; // up-to-date
}

// ─── Build cache helpers (dhake.c:349-503) ───────────────────────────────

// Compute the cache key for a target (dhake.c:353-449). out must be a 65-byte
// buffer. Returns false if any input is unhashable (missing file). Key layout is
// byte-identical to C.
pub fn cacheKey(t: *plan.Target, out: *[65]u8) bool {
    const c = std.heap.c_allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(c);

    // Target name + arch
    buf.appendSlice(c, "t:") catch return false;
    buf.appendSlice(c, std.mem.span(t.name)) catch return false;
    buf.appendSlice(c, "\n") catch return false;
    buf.appendSlice(c, "arch:") catch return false;
    buf.appendSlice(c, if (opts.arch_value != null) std.mem.span(opts.arch_value.?) else "") catch return false;
    buf.appendSlice(c, "\n") catch return false;

    // Recipe actions
    var a = t.recipe;
    while (a) |aa| : (a = aa.next) {
        switch (aa.kind) {
            .ACT_SHELL => {
                buf.appendSlice(c, "sh:") catch return false;
                buf.appendSlice(c, if (aa.a != null) std.mem.span(aa.a.?) else "") catch return false;
                buf.appendSlice(c, "\n") catch return false;
            },
            .ACT_RUN => {
                buf.appendSlice(c, "run:") catch return false;
                var i: c_int = 0;
                while (i < aa.nav) : (i += 1) {
                    if (i > 0) buf.appendSlice(c, " ") catch return false;
                    buf.appendSlice(c, if (aa.av.?[@intCast(i)] != null) std.mem.span(aa.av.?[@intCast(i)].?) else "") catch return false;
                }
                buf.appendSlice(c, "\n") catch return false;
            },
            .ACT_COPY => {
                buf.appendSlice(c, "copy:") catch return false;
                buf.appendSlice(c, if (aa.a != null) std.mem.span(aa.a.?) else "") catch return false;
                buf.appendSlice(c, "->") catch return false;
                buf.appendSlice(c, if (aa.b != null) std.mem.span(aa.b.?) else "") catch return false;
                buf.appendSlice(c, "\n") catch return false;
            },
            .ACT_MKDIR => {
                buf.appendSlice(c, "mkdir:") catch return false;
                buf.appendSlice(c, if (aa.a != null) std.mem.span(aa.a.?) else "") catch return false;
                buf.appendSlice(c, "\n") catch return false;
            },
            .ACT_RM => {
                buf.appendSlice(c, "rm:") catch return false;
                buf.appendSlice(c, if (aa.a != null) std.mem.span(aa.a.?) else "") catch return false;
                buf.appendSlice(c, "\n") catch return false;
            },
            .ACT_TOUCH => {
                buf.appendSlice(c, "touch:") catch return false;
                buf.appendSlice(c, if (aa.a != null) std.mem.span(aa.a.?) else "") catch return false;
                buf.appendSlice(c, "\n") catch return false;
            },
            .ACT_MOVE => {
                buf.appendSlice(c, "move:") catch return false;
                buf.appendSlice(c, if (aa.a != null) std.mem.span(aa.a.?) else "") catch return false;
                buf.appendSlice(c, "->") catch return false;
                buf.appendSlice(c, if (aa.b != null) std.mem.span(aa.b.?) else "") catch return false;
                buf.appendSlice(c, "\n") catch return false;
            },
            .ACT_SYMLINK => {
                buf.appendSlice(c, "symlink:") catch return false;
                buf.appendSlice(c, if (aa.a != null) std.mem.span(aa.a.?) else "") catch return false;
                buf.appendSlice(c, "->") catch return false;
                buf.appendSlice(c, if (aa.b != null) std.mem.span(aa.b.?) else "") catch return false;
                buf.appendSlice(c, "\n") catch return false;
            },
            .ACT_CHMOD => {
                buf.appendSlice(c, "chmod:") catch return false;
                buf.appendSlice(c, if (aa.a != null) std.mem.span(aa.a.?) else "") catch return false;
                buf.appendSlice(c, ":") catch return false;
                buf.appendSlice(c, if (aa.b != null) std.mem.span(aa.b.?) else "") catch return false;
                buf.appendSlice(c, "\n") catch return false;
            },
            .ACT_ECHO => {
                buf.appendSlice(c, "echo:") catch return false;
                buf.appendSlice(c, if (aa.a != null) std.mem.span(aa.a.?) else "") catch return false;
                buf.appendSlice(c, "\n") catch return false;
            },
            .ACT_ENV => {
                buf.appendSlice(c, "env:") catch return false;
                buf.appendSlice(c, if (aa.a != null) std.mem.span(aa.a.?) else "") catch return false;
                buf.appendSlice(c, "=") catch return false;
                buf.appendSlice(c, if (aa.b != null) std.mem.span(aa.b.?) else "") catch return false;
                buf.appendSlice(c, "\n") catch return false;
            },
        }
    }

    // Input dependency content hashes
    var j: c_int = 0;
    while (j < t.ndeps) : (j += 1) {
        const path = if (t.dep_targets.?[@intCast(j)] != null) t.dep_targets.?[@intCast(j)].?.name else t.deps.?[@intCast(j)].?;
        var hex: [65]u8 = undefined;
        if (!fileSha256Hex(path, &hex)) return false;
        buf.appendSlice(c, "d:") catch return false;
        buf.appendSlice(c, std.mem.span(path)) catch return false;
        buf.appendSlice(c, "=") catch return false;
        buf.appendSlice(c, hex[0..64]) catch return false;
        buf.appendSlice(c, "\n") catch return false;
    }

    abi.sha256_hex(buf.items.ptr, buf.items.len, out);
    return true;
}

// Build "<cache_dir>/<key>" on the heap (dhake.c:453-462). Returns a
// NUL-terminated buffer (caller frees); NULL on alloc failure.
fn cachePath(key: []const u8) ?[]u8 {
    const c = std.heap.c_allocator;
    const cd = std.mem.span(opts.cache_dir.?);
    const need = cd.len + 1 + key.len + 1;
    const p = c.alloc(u8, need) catch return null;
    var n: usize = 0;
    @memcpy(p[n .. n + cd.len], cd);
    n += cd.len;
    p[n] = '/';
    n += 1;
    @memcpy(p[n .. n + key.len], key);
    n += key.len;
    p[n] = 0;
    n += 1;
    return p;
}

// Check if a cache entry exists for the given key (dhake.c:465-472).
pub fn cacheHit(key: []const u8) bool {
    const p = cachePath(key) orelse return false;
    defer std.heap.c_allocator.free(p);
    var st: std.os.linux.Statx = undefined;
    const rc = std.os.linux.statx(std.os.linux.AT.FDCWD, @ptrCast(p.ptr), 0, std.os.linux.STATX.BASIC_STATS, &st);
    if (std.os.linux.errno(rc) != .SUCCESS) return false;
    return std.os.linux.S.ISREG(@intCast(st.mode));
}

// Restore a target's output from the cache (dhake.c:475-490). Unlink a stale
// entry BEFORE returning on verify failure so a poisoned entry cannot keep
// dying on later same-input builds.
pub fn cacheRestore(t: *plan.Target, key: []const u8) bool {
    const p = cachePath(key) orelse return false;
    defer std.heap.c_allocator.free(p);
    if (!exec.copyFile(@ptrCast(p.ptr), t.name)) return false;
    if (t.out_hash != null and !t.phony) {
        if (verifyOutputHash(t) != 0) {
            _ = unlink(@ptrCast(p.ptr));
            return false;
        }
    }
    return true;
}

// Store a target's output into the cache (dhake.c:493-503). Best-effort.
pub fn cacheStore(t: *plan.Target, key: []const u8) bool {
    var st: std.os.linux.Statx = undefined;
    const src_rc = std.os.linux.statx(std.os.linux.AT.FDCWD, t.name, 0, std.os.linux.STATX.BASIC_STATS, &st);
    if (std.os.linux.errno(src_rc) != .SUCCESS) return false;
    if (!std.os.linux.S.ISREG(@intCast(st.mode))) return false;
    const p = cachePath(key) orelse return false;
    defer std.heap.c_allocator.free(p);
    if (exec.mkdirP(opts.cache_dir.?) != 0) return false;
    const ok = exec.copyFile(t.name, @ptrCast(p.ptr));
    return ok;
}

extern fn unlink(path: [*:0]const u8) c_int;
