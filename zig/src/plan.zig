// plan.zig — in-memory build plan: Hash/DepHash/Action/Target/Build structs
// (dhake.c:57-121) plus the normalized-Term -> plan mapper
// (parse_hash/term_text_cstr/rec_get/rec_need_text/rec_bool/list_length/
//  parse_unveil_list/parse_dep_hash_list/union_selected/action_path/
//  map_action/map_target/build_plan, dhake.c:258-310 + 514-614 + 744-963).
//
// All structs are plain Zig structs kept C field-for-field. Strings are
// arena-allocated [*:0]u8 owned by the shared arena that eval.zig manages (this
// module asks eval for it via getArena() — it never declares `extern var
// dhall_arena`).
const std = @import("std");
const dt = @import("dhall_types.zig");
const abi = @import("dhall_abi.zig");
const opts = @import("opts.zig");
const eval = @import("eval.zig");
const sysio = @import("sysio.zig");

// ─── Structs (C field-for-field, dhake.c:57-121) ─────────────────────────
pub const ActionKind = enum(u32) {
    ACT_SHELL,
    ACT_COPY,
    ACT_MKDIR,
    ACT_RM,
    ACT_TOUCH,
    ACT_MOVE,
    ACT_SYMLINK,
    ACT_CHMOD,
    ACT_ECHO,
    ACT_ENV,
    ACT_RUN,
};

pub const Action = struct {
    kind: ActionKind,
    a: ?[*:0]u8,
    b: ?[*:0]u8,
    av: ?[*]?[*:0]u8, // argv for Run (NULL for others)
    nav: c_int, // argc for Run (0 for others)
    recursive: bool,
    next: ?*Action,
};

pub const HashAlg = enum(u32) {
    HASH_SHA256,
};

pub const Hash = struct {
    alg: HashAlg,
    hex: ?[*:0]u8, // bare digest for comparison
    spec: ?[*:0]u8, // original "algo:hex" string for messages
};

pub const DepHash = struct {
    path: ?[*:0]u8,
    hash: Hash,
};

pub const Target = struct {
    name: [*:0]u8,
    phony: bool,
    deps: ?[*]?[*:0]u8, // dep names as strings (buildfile order)
    ndeps: c_int,
    recipe: ?*Action, // linked list, buildfile order
    unveil: ?[*]?[*:0]u8, // per-target "perms:path" entries
    nunveil: c_int,
    cwd: ?[*:0]u8, // working directory (NULL = build root)
    arch: ?[*:0]u8, // architecture filter (NULL = any arch)
    out_hash: ?*Hash, // expected output hash (NULL = no check)
    dep_hash: ?[*]DepHash, // expected dep hashes
    ndep_hash: c_int,
    dep_targets: ?[*]?*Target, // resolved Target* per dep
    state: c_int, // 0 unvisited, 1 visiting (cycle), 2 done
    dirty: bool,
    deps_pending: c_int, // parallel scheduler state
    pid: c_int, // 0 if not running
    next: ?*Target, // intrusive list
};

pub const Build = struct {
    targets: ?*Target, // linked list, buildfile order
    ntargets: c_int,
    default_name: ?[*:0]u8, // NULL if none
    sandbox_enabled: bool,
    sandbox_read_exec: bool,
    sandbox_deny_network: bool,
    unveil: ?[*]?[*:0]u8, // global whitelist entries
    nunveil: c_int,
    landlock_abi: c_int, // probe result; <1 => unavailable
};

// ─── Arena helpers (explicit arena passing, never extern dhall_arena) ────
pub fn arena() ?*anyopaque {
    return eval.getArena();
}

fn allocZ(a: ?*anyopaque, n: usize) [*]u8 {
    const p = abi.arena_alloc(a, n) orelse opts.die("out of memory");
    return @ptrCast(@alignCast(p));
}

fn allocPtr(a: ?*anyopaque, comptime T: type) *T {
    const p = abi.arena_alloc(a, @sizeOf(T)) orelse opts.die("out of memory");
    return @ptrCast(@alignCast(p));
}

pub fn allocArr(a: ?*anyopaque, comptime T: type, n: usize) [*]T {
    const p = abi.arena_alloc(a, n * @sizeOf(T)) orelse opts.die("out of memory");
    return @ptrCast(@alignCast(p));
}

// ─── Term -> string/scalar helpers (dhake.c:514-614) ─────────────────────
// Extract a fully-collapsed Text literal as an arena-owned NUL-terminated C
// string. Returns NULL if t is not Text or still has unresolved interpolation.
fn termTextCstr(t: ?*dt.Term) ?[*:0]u8 {
    if (t == null or t.?.tag != .TmText) return null;
    var len: usize = 0;
    var p = t.?.as.text;
    while (p) |part| : (p = part.next) {
        if (part.expr != null) return null; // stuck interpolation
        if (part.lit) |lit| len += std.mem.span(lit).len;
    }
    const a = arena() orelse return null;
    const out = allocZ(a, len + 1);
    var q: usize = 0;
    p = t.?.as.text;
    while (p) |part| : (p = part.next) {
        if (part.lit) |lit| {
            const l = std.mem.span(lit);
            @memcpy(out[q .. q + l.len], l);
            q += l.len;
        }
    }
    out[q] = 0;
    return @ptrCast(out);
}

// find a field value by label in a record literal; NULL if absent/not a record
fn recGet(rec: ?*dt.Term, label: []const u8) ?*dt.Term {
    if (rec == null or rec.?.tag != .TmRecordLit) return null;
    const r = rec.?.as.rec;
    const n: usize = @intCast(r.n);
    const fs = r.fs orelse return null;
    for (fs[0..n]) |f| {
        const fl = f.label orelse continue;
        if (std.mem.eql(u8, std.mem.span(fl), label)) return f.value;
    }
    return null;
}

// read a required Text field; die() with a clear message on shape error
fn recNeedText(rec: ?*dt.Term, label: []const u8, where: []const u8) [*:0]u8 {
    const f = recGet(rec, label) orelse opts.dieFmt("{s}: missing field '{s}'", .{ where, label });
    const s = termTextCstr(f) orelse opts.dieFmt("{s}: field '{s}' must be Text", .{ where, label });
    return s;
}

fn recBool(rec: ?*dt.Term, label: []const u8, dflt: bool, where: []const u8) bool {
    const f = recGet(rec, label) orelse return dflt;
    if (f.tag != .TmConst or f.as.c.kind != .C_BOOL)
        opts.dieFmt("{s}: field '{s}' must be Bool", .{ where, label });
    return f.as.c.b;
}

fn listLength(list: ?*dt.Term) c_int {
    var n: c_int = 0;
    var p = list;
    while (p != null and p.?.tag == .TmCons) : (p = p.?.as.cons.tail) n += 1;
    return n;
}

// Parse an optional `unveil : List Text` field into an arena-owned string array.
fn parseUnveilList(rec: ?*dt.Term, where: []const u8, n_out: *c_int) ?[*]?[*:0]u8 {
    n_out.* = 0;
    const u = recGet(rec, "unveil") orelse return null;
    if (u.tag != .TmNil and u.tag != .TmCons)
        opts.dieFmt("{s}: 'unveil' must be a List Text", .{where});
    const n = listLength(u);
    if (n == 0) return null;
    const a = arena() orelse return null;
    const out = allocArr(a, ?[*:0]u8, @intCast(n));
    var i: usize = 0;
    var p: ?*dt.Term = u;
    while (p != null and p.?.tag == .TmCons) : (p = p.?.as.cons.tail) {
        const s = termTextCstr(p.?.as.cons.head) orelse
            opts.dieFmt("{s}: unveil entry must be Text", .{where});
        out[i] = s;
        i += 1;
    }
    n_out.* = n;
    return out;
}

// Parse an optional `depsHash : List { path : Text, hash : Text }` field.
fn parseDepHashList(rec: ?*dt.Term, where: []const u8, n_out: *c_int) ?[*]DepHash {
    n_out.* = 0;
    const list = recGet(rec, "depsHash") orelse return null;
    if (list.tag != .TmNil and list.tag != .TmCons)
        opts.dieFmt("{s}: 'depsHash' must be a List {{ path : Text, hash : Text }}", .{where});
    const n = listLength(list);
    if (n == 0) return null;
    const a = arena() orelse return null;
    const out = allocArr(a, DepHash, @intCast(n));
    var i: usize = 0;
    var p: ?*dt.Term = list;
    while (p != null and p.?.tag == .TmCons) : (p = p.?.as.cons.tail) {
        const item = p.?.as.cons.head;
        if (item == null or item.?.tag != .TmRecordLit)
            opts.dieFmt("{s}: depsHash element must be a {{ path, hash }} record", .{where});
        const path = recNeedText(item, "path", where);
        const hash_spec = recNeedText(item, "hash", where);
        out[i].path = path;
        out[i].hash = parseHash(hash_spec, where);
        i += 1;
    }
    n_out.* = n;
    return out;
}

// Parse a hash spec string (e.g. "sha256:abc123...") into a Hash struct
// (dhake.c:258-310). Dies on parse error. Hex normalized to lowercase.
fn parseHash(spec: ?[*:0]const u8, where: []const u8) Hash {
    const sp = spec orelse opts.dieFmt("{s}: hash spec is NULL", .{where});
    const spec_s = std.mem.span(sp);
    const colon = std.mem.indexOfScalar(u8, spec_s, ':') orelse
        opts.dieFmt("{s}: hash spec '{s}' must be '<algorithm>:<hexdigest>'", .{ where, spec_s });
    const algo_len = colon;
    const algo = spec_s[0..colon];
    const hex_part = spec_s[colon + 1 ..];

    if (algo_len == 0) opts.dieFmt("{s}: hash spec '{s}' has empty algorithm", .{ where, spec_s });

    var algo_buf: [16]u8 = undefined;
    if (algo_len >= algo_buf.len) opts.dieFmt("{s}: algorithm name too long in '{s}'", .{ where, spec_s });
    @memcpy(algo_buf[0..algo_len], algo);

    var alg: HashAlg = undefined;
    if (std.mem.eql(u8, algo_buf[0..algo_len], "sha256")) {
        alg = .HASH_SHA256;
    } else {
        opts.dieFmt("{s}: unsupported hash algorithm '{s}' (supported: sha256)", .{ where, algo_buf[0..algo_len] });
    }

    const hex_len = hex_part.len;
    if (hex_len != 64) opts.dieFmt("{s}: hash spec '{s}' has {d} hex chars, expected 64 for sha256", .{ where, spec_s, hex_len });

    for (hex_part, 0..) |c, i| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!is_hex) opts.dieFmt("{s}: hash spec '{s}' contains non-hex character at position {d}", .{ where, spec_s, i });
    }

    const a = arena() orelse opts.die("out of memory");
    const hex_normalized = allocZ(a, 65);
    for (hex_part, 0..) |c, i| {
        if (c >= 'A' and c <= 'F') {
            hex_normalized[i] = c - 'A' + 'a';
        } else {
            hex_normalized[i] = c;
        }
    }
    hex_normalized[64] = 0;

    return Hash{
        .alg = alg,
        .hex = @ptrCast(hex_normalized),
        .spec = abi.arena_strdup(a, sp) orelse opts.die("out of memory"),
    };
}

// ─── Action mapping (dhake.c:744-848) ────────────────────────────────────
// the selected alternative of a union literal: the field carrying a value
fn unionSelected(u: ?*dt.Term) ?*dt.Field {
    if (u == null or u.?.tag != .TmUnionLit) return null;
    const fs = u.?.as.uni.fs orelse return null;
    const n: usize = @intCast(u.?.as.uni.n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (fs[i].value != null) return &fs[i];
    }
    return null;
}

// Resolve a Mkdir/Rm payload (bare Text, or { path, <flag> } record, or nested
// single-alt union of the two). Returns an arena-owned path, sets *recursive.
fn actionPath(v: ?*dt.Term, flag: []const u8, recursive: *bool, target: []const u8) ?[*:0]u8 {
    recursive.* = false;
    if (v == null) opts.dieFmt("target '{s}': Mkdir/Rm payload missing", .{target});
    var vv = v;
    if (vv.?.tag == .TmUnionLit) {
        const f = unionSelected(vv) orelse opts.dieFmt("target '{s}': malformed Mkdir/Rm payload", .{target});
        vv = f.value;
    }
    if (vv.?.tag == .TmText) return termTextCstr(vv);
    if (vv.?.tag == .TmRecordLit) {
        const p = recNeedText(vv, "path", target);
        recursive.* = recBool(vv, flag, false, target);
        return p;
    }
    opts.dieFmt("target '{s}': Mkdir/Rm payload must be Text or a {{ path, {s} }} record", .{ target, flag });
}

fn mapAction(u: ?*dt.Term, target: []const u8) *Action {
    if (u == null or u.?.tag != .TmUnionLit)
        opts.dieFmt("target '{s}': recipe element must be an Action union (< Tag = v >)", .{target});
    const sel = unionSelected(u) orelse opts.dieFmt("target '{s}': malformed Action union", .{target});
    const a = allocPtr(arena() orelse opts.die("out of memory"), Action);
    a.kind = undefined;
    a.a = null;
    a.b = null;
    a.av = null;
    a.nav = 0;
    a.recursive = false;
    a.next = null;

    const tag = sel.label orelse opts.dieFmt("target '{s}': unknown action", .{target});
    const tag_s = std.mem.span(tag);

    if (std.mem.eql(u8, tag_s, "Shell")) {
        a.kind = .ACT_SHELL;
        a.a = termTextCstr(sel.value) orelse
            opts.dieFmt("target '{s}': < Shell = ... > value must be Text", .{target});
    } else if (std.mem.eql(u8, tag_s, "Copy")) {
        a.kind = .ACT_COPY;
        const sv = sel.value orelse opts.dieFmt("target '{s}': Copy must be a {{ from, to }} record", .{target});
        if (sv.tag != .TmRecordLit) opts.dieFmt("target '{s}': Copy must be a {{ from, to }} record", .{target});
        a.a = recNeedText(sv, "from", target);
        a.b = recNeedText(sv, "to", target);
    } else if (std.mem.eql(u8, tag_s, "Mkdir")) {
        a.kind = .ACT_MKDIR;
        a.a = actionPath(sel.value, "parents", &a.recursive, target);
        if (a.a == null) opts.dieFmt("target '{s}': < Mkdir = ... > value must be Text or a {{ path, parents }} record", .{target});
    } else if (std.mem.eql(u8, tag_s, "Rm")) {
        a.kind = .ACT_RM;
        a.a = actionPath(sel.value, "recursive", &a.recursive, target);
        if (a.a == null) opts.dieFmt("target '{s}': < Rm = ... > value must be Text or a {{ path, recursive }} record", .{target});
    } else if (std.mem.eql(u8, tag_s, "Touch")) {
        a.kind = .ACT_TOUCH;
        a.a = termTextCstr(sel.value) orelse
            opts.dieFmt("target '{s}': < Touch = ... > value must be Text", .{target});
    } else if (std.mem.eql(u8, tag_s, "Move")) {
        a.kind = .ACT_MOVE;
        const sv = sel.value orelse opts.dieFmt("target '{s}': Move must be a {{ from, to }} record", .{target});
        if (sv.tag != .TmRecordLit) opts.dieFmt("target '{s}': Move must be a {{ from, to }} record", .{target});
        a.a = recNeedText(sv, "from", target);
        a.b = recNeedText(sv, "to", target);
    } else if (std.mem.eql(u8, tag_s, "Symlink")) {
        a.kind = .ACT_SYMLINK;
        const sv = sel.value orelse opts.dieFmt("target '{s}': Symlink must be a {{ from, to }} record", .{target});
        if (sv.tag != .TmRecordLit) opts.dieFmt("target '{s}': Symlink must be a {{ from, to }} record", .{target});
        a.a = recNeedText(sv, "from", target);
        a.b = recNeedText(sv, "to", target);
    } else if (std.mem.eql(u8, tag_s, "Chmod")) {
        a.kind = .ACT_CHMOD;
        const sv = sel.value orelse opts.dieFmt("target '{s}': Chmod must be a {{ path, mode }} record", .{target});
        if (sv.tag != .TmRecordLit) opts.dieFmt("target '{s}': Chmod must be a {{ path, mode }} record", .{target});
        a.a = recNeedText(sv, "path", target);
        a.b = recNeedText(sv, "mode", target);
    } else if (std.mem.eql(u8, tag_s, "Echo")) {
        a.kind = .ACT_ECHO;
        a.a = termTextCstr(sel.value) orelse
            opts.dieFmt("target '{s}': < Echo = ... > value must be Text", .{target});
    } else if (std.mem.eql(u8, tag_s, "Env")) {
        a.kind = .ACT_ENV;
        const sv = sel.value orelse opts.dieFmt("target '{s}': Env must be a {{ key, value }} record", .{target});
        if (sv.tag != .TmRecordLit) opts.dieFmt("target '{s}': Env must be a {{ key, value }} record", .{target});
        a.a = recNeedText(sv, "key", target);
        a.b = recNeedText(sv, "value", target);
    } else if (std.mem.eql(u8, tag_s, "Run")) {
        a.kind = .ACT_RUN;
        const sv = sel.value orelse opts.dieFmt("target '{s}': Run must be a {{ argv : List Text }} record", .{target});
        if (sv.tag != .TmRecordLit) opts.dieFmt("target '{s}': Run must be a {{ argv : List Text }} record", .{target});
        const argv_list = recGet(sv, "argv") orelse opts.dieFmt("target '{s}': Run must have an 'argv' field", .{target});
        const n = listLength(argv_list);
        if (n == 0) opts.dieFmt("target '{s}': Run argv must be non-empty", .{target});
        const av = allocArr(arena() orelse opts.die("out of memory"), ?[*:0]u8, @intCast(n + 1));
        a.nav = n;
        var i: usize = 0;
        var p: ?*dt.Term = argv_list;
        while (p != null and p.?.tag == .TmCons) : (p = p.?.as.cons.tail) {
            av[i] = termTextCstr(p.?.as.cons.head) orelse
                opts.dieFmt("target '{s}': Run argv elements must be Text", .{target});
            i += 1;
        }
        av[@intCast(n)] = null;
        a.av = av;
        a.a = av[0];
    } else {
        opts.dieFmt("target '{s}': unknown action '< {s} = ... >'", .{ target, tag_s });
    }
    return a;
}

// ─── Target mapping (dhake.c:850-920) ────────────────────────────────────
fn mapTarget(mapValue: ?*dt.Term, name: []const u8) *Target {
    if (mapValue == null or mapValue.?.tag != .TmRecordLit)
        opts.dieFmt("target '{s}': mapValue must be a record {{ deps, phony, recipe }}", .{name});
    const a = arena() orelse opts.die("out of memory");
    const t = allocPtr(a, Target);
    const name_z: [*:0]const u8 = @ptrCast(name.ptr);
    t.name = @constCast(name_z);
    t.phony = false;
    t.deps = null;
    t.ndeps = 0;
    t.recipe = null;
    t.unveil = null;
    t.nunveil = 0;
    t.cwd = null;
    t.arch = null;
    t.out_hash = null;
    t.dep_hash = null;
    t.ndep_hash = 0;
    t.dep_targets = null;
    t.state = 0;
    t.dirty = false;
    t.deps_pending = 0;
    t.pid = 0;
    t.next = null;

    const deps = recGet(mapValue, "deps");
    if (deps != null) {
        if (deps.?.tag != .TmNil and deps.?.tag != .TmCons)
            opts.dieFmt("target '{s}': 'deps' must be a List Text", .{name});
        t.ndeps = listLength(deps);
        t.deps = allocArr(a, ?[*:0]u8, @intCast(if (t.ndeps != 0) t.ndeps else 1));
        var i: usize = 0;
        var p = deps;
        while (p != null and p.?.tag == .TmCons) : (p = p.?.as.cons.tail) {
            const d = termTextCstr(p.?.as.cons.head) orelse
                opts.dieFmt("target '{s}': dependency name must be Text", .{name});
            t.deps.?[i] = d;
            i += 1;
        }
    }
    t.phony = recBool(mapValue, "phony", false, name);
    t.unveil = parseUnveilList(mapValue, name, &t.nunveil);

    const cwdt = recGet(mapValue, "cwd");
    if (cwdt != null) {
        if (cwdt.?.tag != .TmText) opts.dieFmt("target '{s}': 'cwd' must be Text", .{name});
        t.cwd = termTextCstr(cwdt);
    }

    const archt = recGet(mapValue, "arch");
    if (archt != null) {
        var av = archt;
        if (av.?.tag == .TmSome) av = av.?.as.some.val;
        if (av.?.tag == .TmText) {
            t.arch = termTextCstr(av);
        } else if (av.?.tag == .TmNone) {
            t.arch = null;
        } else {
            opts.dieFmt("target '{s}': 'arch' must be Text", .{name});
        }
    }

    const hash_term = recGet(mapValue, "hash");
    if (hash_term != null) {
        if (hash_term.?.tag != .TmText) opts.dieFmt("target '{s}': 'hash' must be Text", .{name});
        const hash_spec = termTextCstr(hash_term);
        const oh = allocPtr(a, Hash);
        oh.* = parseHash(hash_spec, name);
        t.out_hash = oh;
    }
    t.dep_hash = parseDepHashList(mapValue, name, &t.ndep_hash);

    const recipe = recGet(mapValue, "recipe");
    if (recipe != null and recipe.?.tag != .TmNil) {
        if (recipe.?.tag != .TmCons) opts.dieFmt("target '{s}': 'recipe' must be a List Action", .{name});
        var tail: *?*Action = &t.recipe;
        var p = recipe;
        while (p != null and p.?.tag == .TmCons) : (p = p.?.as.cons.tail) {
            const act = mapAction(p.?.as.cons.head, name);
            tail.* = act;
            tail = &act.next;
        }
    }
    return t;
}

// ─── Build mapping (dhake.c:922-963) ─────────────────────────────────────
fn findTarget(b: *Build, name: []const u8) ?*Target {
    var t = b.targets;
    while (t) |tt| : (t = tt.next) {
        if (std.mem.eql(u8, std.mem.span(tt.name), name)) return tt;
    }
    return null;
}

pub fn buildPlan(root: ?*dt.Term) *Build {
    if (root == null or root.?.tag != .TmRecordLit)
        opts.die("buildfile must evaluate to a record { targets, default }");
    const a = arena() orelse opts.die("out of memory");
    const b = allocPtr(a, Build);
    b.targets = null;
    b.ntargets = 0;
    b.default_name = null;
    b.sandbox_enabled = false;
    b.sandbox_read_exec = false;
    b.sandbox_deny_network = false;
    b.unveil = null;
    b.nunveil = 0;
    b.landlock_abi = -1;

    const default_t = recGet(root, "default");
    if (default_t != null) b.default_name = termTextCstr(default_t);

    const sb = recGet(root, "sandbox");
    if (sb != null) {
        if (sb.?.tag != .TmRecordLit)
            opts.die("buildfile: 'sandbox' must be a record { enable, readExec, denyNetwork, unveil }");
        b.sandbox_enabled = recBool(sb, "enable", false, "buildfile");
        b.sandbox_read_exec = recBool(sb, "readExec", false, "buildfile");
        b.sandbox_deny_network = recBool(sb, "denyNetwork", false, "buildfile");
        b.unveil = parseUnveilList(sb, "buildfile", &b.nunveil);
        if (b.sandbox_deny_network and !b.sandbox_enabled)
            sysio.writeErr("dhake: warning: sandbox.denyNetwork=True but sandbox.enable=False; network containment will NOT be applied\n");
    }

    const targets = recGet(root, "targets") orelse opts.die("buildfile: missing 'targets' field");
    if (targets.tag != .TmNil and targets.tag != .TmCons)
        opts.die("buildfile: 'targets' must be a List of { mapKey, mapValue }");

    var tail: *?*Target = &b.targets;
    var p: ?*dt.Term = targets;
    while (p != null and p.?.tag == .TmCons) : (p = p.?.as.cons.tail) {
        const item = p.?.as.cons.head;
        if (item == null or item.?.tag != .TmRecordLit)
            opts.die("buildfile: each 'targets' element must be { mapKey, mapValue }");
        const key = recNeedText(item, "mapKey", "buildfile");
        if (findTarget(b, std.mem.span(key)) != null)
            opts.dieFmt("buildfile: duplicate target name '{s}'", .{std.mem.span(key)});
        const mv = recGet(item, "mapValue") orelse
            opts.dieFmt("buildfile: target '{s}' missing 'mapValue'", .{std.mem.span(key)});
        const t = mapTarget(mv, std.mem.span(key));
        tail.* = t;
        tail = &t.next;
        b.ntargets += 1;
    }
    return b;
}
