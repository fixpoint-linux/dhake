// main.zig — dhake (Zig) CLI entry point.
//
// U0 scaffold: minimal argv parsing plus a hidden `--abi-smoke` flag that
// exercises the full libdhall.so ABI seam in-process (parse + normalize a static
// buildfile, walk record/cons/union/text nodes, sha256 check) and prints a
// "SMOKE OK" line. The ABI smoke is the U0 gate; the real CLI modes are ported
// in later units (U1+).

const std = @import("std");
const dt = @import("dhall_types.zig");
const abi = @import("dhall_abi.zig");
const opts = @import("opts.zig");
const sysio = @import("sysio.zig");
const plan = @import("plan.zig");
const eval = @import("eval.zig");
const graph = @import("graph.zig");
const exec = @import("exec.zig");
const sandbox = @import("sandbox.zig");
const hash = @import("hash.zig");
const report = @import("report.zig");
const watch = @import("watch.zig");

extern fn strerror(errnum: c_int) [*:0]const u8;

// ─── Minimal I/O helpers (byte-parity with C's dprintf/die) ──────────────
fn out(s: []const u8) void {
    _ = std.os.linux.write(1, s.ptr, s.len);
}

fn fail(msg: []const u8) noreturn {
    _ = std.os.linux.write(2, msg.ptr, msg.len);
    std.os.linux.exit_group(1);
}

fn cstr(p: [*:0]const u8) []const u8 {
    return std.mem.span(p);
}

// ─── --abi-smoke ─────────────────────────────────────────────────────────
// Static buildfile (proven in artifact-2): a record with a `targets` list of
// {mapKey, mapValue} pairs plus a `default` text field.
const smoke_src =
    \\let Action = < Shell : Text >
    \\let Target = { deps : List Text, phony : Bool, recipe : List Action }
    \\in  { targets =
    \\        [ { mapKey = "hello"
    \\          , mapValue = { deps = [ "hello.c" ], phony = False
    \\                       , recipe = [ < Shell = "echo building hello" > ]
    \\                       }
    \\          }
    \\        ]
    \\    , default = "hello"
    \\    }
;

var text_buf: [512]u8 = undefined;

fn textOfInto(buf: []u8, t: ?*dt.Term) []const u8 {
    const tt = t orelse fail("null");
    if (tt.tag != .TmText) fail("not TmText");
    var n: usize = 0;
    var p: ?*dt.TextPart = tt.as.text;
    while (p) |part| : (p = part.next) {
        if (part.expr != null) fail("stuck interpolation");
        if (part.lit) |lit| {
            const l = cstr(lit);
            @memcpy(buf[n .. n + l.len], l);
            n += l.len;
        }
    }
    return buf[0..n];
}

fn textOf(t: ?*dt.Term) []const u8 {
    return textOfInto(text_buf[0..], t);
}

// Dedicated buffers so the three extracted fields don't alias each other
// (textOf writes into a single shared static buffer).
var default_buf: [512]u8 = undefined;
var mapkey_buf: [512]u8 = undefined;
var shell_buf: [512]u8 = undefined;

fn abi_smoke() void {
    const arena = abi.arena_new() orelse fail("arena_new");
    abi.arena_reset(arena);
    const loader = abi.import_loader_new();
    abi.import_loader_push_root(loader, "build.dhall");
    var p: dt.Parser = std.mem.zeroes(dt.Parser);
    p.loader = loader;
    var err: dt.DhallError = std.mem.zeroes(dt.DhallError);
    const t = abi.parse_source(&p, smoke_src, "build.dhall", &err) orelse fail("parse null");
    abi.normalize_clear_error();
    const nf = abi.normalize(t) orelse fail("normalize null");
    if (abi.normalize_has_error()) {
        const e = abi.normalize_get_error() orelse fail("no err ptr");
        out(e.msg[0 .. std.mem.indexOfScalar(u8, &e.msg, 0) orelse 512]);
        fail("norm err");
    }
    abi.import_loader_free(loader);

    if (nf.tag != .TmRecordLit) fail("not rec");
    const rec = nf.as.rec;

    var default_s: []const u8 = "";
    var mapkey_s: []const u8 = "";
    var phony_b: bool = false;
    var shell_s: []const u8 = "";

    const n: usize = @intCast(rec.n);
    for (rec.fs.?[0..n]) |f| {
        const label = cstr(f.label.?);
        if (std.mem.eql(u8, label, "default")) {
            default_s = textOfInto(default_buf[0..], f.value);
        } else if (std.mem.eql(u8, label, "targets")) {
            const item = f.value orelse fail("targets null");
            if (item.tag != .TmCons) fail("targets not cons");
            const head = item.as.cons.head orelse fail("cons head null");
            const hrec = head.as.rec;
            const hn: usize = @intCast(hrec.n);
            for (hrec.fs.?[0..hn]) |hf| {
                const hl = cstr(hf.label.?);
                if (std.mem.eql(u8, hl, "mapKey")) {
                    mapkey_s = textOfInto(mapkey_buf[0..], hf.value);
                } else if (std.mem.eql(u8, hl, "mapValue")) {
                    const mv = hf.value orelse fail("mapValue null");
                    const mvrec = mv.as.rec;
                    const mvn: usize = @intCast(mvrec.n);
                    for (mvrec.fs.?[0..mvn]) |mvf| {
                        const mvl = cstr(mvf.label.?);
                        if (std.mem.eql(u8, mvl, "phony")) {
                            const pv = mvf.value orelse fail("phony null");
                            if (pv.tag != .TmConst) fail("phony not const");
                            const cc = pv.as.c;
                            if (cc.kind != .C_BOOL) fail("phony not bool");
                            phony_b = cc.b;
                        } else if (std.mem.eql(u8, mvl, "recipe")) {
                            const rv = mvf.value orelse fail("recipe null");
                            if (rv.tag != .TmCons) fail("recipe not cons");
                            const act = rv.as.cons.head orelse fail("action null");
                            if (act.tag != .TmUnionLit) fail("action not union lit");
                            const uni = act.as.uni;
                            const un: usize = @intCast(uni.n);
                            for (uni.fs.?[0..un]) |uf| {
                                if (uf.value) |uv| {
                                    if (!std.mem.eql(u8, cstr(uf.label.?), "Shell")) fail("union not Shell");
                                    shell_s = textOfInto(shell_buf[0..], uv);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    var hex: [65]u8 = undefined;
    abi.sha256_hex("abc", 3, &hex);

    var msg: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&msg, "SMOKE OK default={s} mapKey={s} phony={} shell='{s}' sha256(abc)={s}\n", .{
        default_s,
        mapkey_s,
        phony_b,
        shell_s,
        hex[0..64],
    }) catch fail("bufPrint");
    out(s);

    const sp = abi.arena_strdup(arena, "x") orelse fail("arena_strdup null");
    if (cstr(sp)[0] != 'x') fail("arena_strdup corrupt");

    std.os.linux.exit_group(0);
}

// ─── usage() — VERBATIM copy of dhake.c:2397-2450 ─────────────────────────
fn usage(argv0: []const u8) void {
    sysio.writeOut("dhake \xe2\x80\x94 a Make-like build tool driven by a Dhall buildfile\n\n");
    sysio.writeOut("Usage:\n");
    sysio.writeOutFmt("  {s} [-f FILE] [-j N] [-n] [-D KEY=VALUE|--define KEY=VALUE] [--arch=NAME] [--cache[=DIR]] [--list] [--warn-hash-mismatch] [--verify|--check] [--lock[=FILE]] [--hash-uptodate|--content-addressed] [--watch|-w] [--explain|--why] [--graph[=dot|mermaid]] [--quiet|-s] [target ...]\n", .{argv0});
    sysio.writeOutFmt("  {s} -h | --help\n\n", .{argv0});
    sysio.writeOut("Options:\n");
    sysio.writeOut("  -f FILE    buildfile to evaluate (default: ./Dhakefile.dhall, else ./build.dhall)\n");
    sysio.writeOut("  -j N       run up to N build jobs in parallel (default: 1, sequential)\n");
    sysio.writeOut("  -n         dry run: print the actions that would run, without running them\n");
    sysio.writeOut("  --list     list all targets and exit\n");
    sysio.writeOut("  --warn-hash-mismatch\n");
    sysio.writeOut("             report verified-build hash mismatches as warnings (printing the\n");
    sysio.writeOut("             actual hash) instead of failing, so pinned hashes can be updated\n");
    sysio.writeOut("  --verify / --check\n");
    sysio.writeOut("             verify all pinned hashes and up-to-dateness without running recipes\n");
    sysio.writeOut("             (CI pre-flight); exits nonzero if anything is dirty or mismatched\n");
    sysio.writeOut("  --lock[=FILE]\n");
    sysio.writeOut("             write a lockfile (dhake.lock, or FILE if =FILE given) with\n");
    sysio.writeOut("             actual hashes and transitive dependencies after a successful build\n");
    sysio.writeOut("  --hash-uptodate / --content-addressed\n");
    sysio.writeOut("             for targets that pin dep hashes (depsHash), decide up-to-dateness\n");
    sysio.writeOut("             by content hashing instead of mtime comparison (ignores touch on\n");
    sysio.writeOut("             unchanged files); a content change still requires re-pinning the\n");
    sysio.writeOut("             dep hash (or --warn-hash-mismatch) before it can rebuild; only\n");
    sysio.writeOut("             affects verified targets, others use mtime\n");
    sysio.writeOut("  --watch / -w\n");
    sysio.writeOut("             rebuild and watch the requested targets' source-file dependencies;\n");
    sysio.writeOut("             on any change, rebuild (dev-loop); uses Linux inotify\n");
    sysio.writeOut("  --explain / --why\n");
    sysio.writeOut("             explain why each target in the requested subgraph needs rebuilding\n");
    sysio.writeOut("             (or is up to date); pure diagnostic, does not run recipes\n");
    sysio.writeOut("  --graph[=dot|mermaid]\n");
    sysio.writeOut("             dump the full dependency graph and exit; default format is dot,\n");
    sysio.writeOut("             mermaid is also supported; pure diagnostic, does not run recipes\n");
    sysio.writeOut("  --quiet / -s\n");
    sysio.writeOut("             suppress per-recipe command echo (summary lines and errors\n");
    sysio.writeOut("             are still shown)\n");
    sysio.writeOut("  -D KEY=VALUE / --define KEY=VALUE\n");
    sysio.writeOut("             inject KEY=VALUE into the buildfile evaluation environment,\n");
    sysio.writeOut("             making it available to env: imports (e.g. env:CC). Multiple\n");
    sysio.writeOut("             --define options accumulate; scoped to evaluation only\n");
    sysio.writeOut("  --arch=NAME\n");
    sysio.writeOut("             set the architecture to NAME for this build; makes DHAKE_ARCH=NAME\n");
    sysio.writeOut("             available in recipes via $DHAKE_ARCH and in buildfiles via\n");
    sysio.writeOut("             ${env:DHAKE_ARCH}. Default: auto-detected via uname()\n");
    sysio.writeOut("  --cache[=DIR]\n");
    sysio.writeOut("             enable ccache-style build caching: skip recipe execution when\n");
    sysio.writeOut("             a target's inputs and recipe are identical to a previous build.\n");
    sysio.writeOut("             With --cache, uses default dir ($XDG_CACHE_HOME/dhake or\n");
    sysio.writeOut("             $HOME/.cache/dhake or .dhake-cache). With --cache=DIR, uses DIR.\n");
    sysio.writeOut("             Caching is OPT-IN and disabled by default. Only enable for\n");
    sysio.writeOut("             deterministic recipes (same inputs -> same output).\n");
    sysio.writeOut("  target     build the named target(s); default: the buildfile's 'default'\n");
}

// ─── CLI entry ────────────────────────────────────────────────────────────
pub fn main(init: std.process.Init.Minimal) void {
    const args = init.args.vector;

    var buildfile: []const u8 = sysio.defaultBuildfile();
    var want_list = false;
    var dry_run = false;
    var jobs: c_int = 1; // default: sequential
    var wanted: std.ArrayListUnmanaged([]const u8) = .empty;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.span(args[i]);
        if (std.mem.eql(u8, arg, "--abi-smoke")) {
            abi_smoke();
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            usage(std.mem.span(args[0]));
            std.os.linux.exit_group(0);
        } else if (std.mem.eql(u8, arg, "-j")) {
            if (i + 1 >= args.len) opts.die("-j requires a number argument");
            i += 1;
            const val = std.mem.span(args[i]);
            jobs = std.fmt.parseInt(c_int, val, 10) catch 0;
            if (jobs < 1) opts.die("-j must be at least 1");
        } else if (std.mem.eql(u8, arg, "-f")) {
            if (i + 1 >= args.len) opts.die("-f requires a file argument");
            i += 1;
            buildfile = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "-D") or std.mem.eql(u8, arg, "--define")) {
            if (i + 1 >= args.len) opts.die("--define requires KEY=VALUE");
            i += 1;
            const def = std.mem.span(args[i]);
            const eq = std.mem.indexOfScalar(u8, def, '=');
            if (eq == null or eq.? == 0) opts.die("--define requires KEY=VALUE");
            const key = def[0..eq.?];
            if (key.len == 0) opts.die("--define requires non-empty key");
            const value = def[eq.? + 1 ..];
            opts.addDefine(key, value);
        } else if (std.mem.eql(u8, arg, "--list")) {
            want_list = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-s")) {
            opts.quiet = true;
        } else if (std.mem.eql(u8, arg, "--warn-hash-mismatch")) {
            hash.warn_hash_mismatch = true;
        } else if (std.mem.eql(u8, arg, "--verify") or std.mem.eql(u8, arg, "--check")) {
            opts.want_verify = true;
        } else if (std.mem.eql(u8, arg, "--lock")) {
            opts.lock_path = "dhake.lock";
        } else if (arg.len >= 7 and std.mem.eql(u8, arg[0..7], "--lock=")) {
            opts.lock_path = arg[7..];
        } else if (std.mem.eql(u8, arg, "--hash-uptodate") or std.mem.eql(u8, arg, "--content-addressed")) {
            opts.hash_uptodate = true;
        } else if (std.mem.eql(u8, arg, "--explain") or std.mem.eql(u8, arg, "--why")) {
            opts.want_explain = true;
        } else if (std.mem.eql(u8, arg, "--watch") or std.mem.eql(u8, arg, "-w")) {
            opts.watch_mode = true;
        } else if (std.mem.eql(u8, arg, "--graph")) {
            opts.graph_format = "dot";
        } else if (arg.len >= 8 and std.mem.eql(u8, arg[0..8], "--graph=")) {
            const f = arg[8..];
            if (!std.mem.eql(u8, f, "dot") and !std.mem.eql(u8, f, "mermaid"))
                opts.die("--graph format must be 'dot' or 'mermaid'");
            opts.graph_format = f;
        } else if (std.mem.eql(u8, arg, "--cache")) {
            opts.cache_dir = opts.defaultCacheDir();
        } else if (arg.len >= 8 and std.mem.eql(u8, arg[0..8], "--cache=")) {
            const v = arg[8..];
            if (v.len == 0) opts.die("--cache requires a directory (use --cache=DIR)");
            const c = std.heap.c_allocator;
            const z = c.dupeZ(u8, v) catch opts.die("out of memory");
            opts.cache_dir = @ptrCast(z.ptr);
        } else if (arg.len >= 7 and std.mem.eql(u8, arg[0..7], "--arch=")) {
            const v = arg[7..];
            if (v.len == 0) opts.die("--arch requires a name (use --arch=NAME)");
            const c = std.heap.c_allocator;
            const z = c.dupeZ(u8, v) catch opts.die("out of memory");
            opts.arch_param = @ptrCast(z.ptr);
        } else if (arg.len > 0 and arg[0] == '-') {
            opts.dieFmt("unknown option '{s}'", .{arg});
        } else {
            wanted.append(std.heap.c_allocator, arg) catch opts.die("out of memory");
        }
    }

    // Set arch_value and DHAKE_ARCH env var (persists into recipe children)
    opts.arch_value = if (opts.arch_param != null) opts.arch_param else opts.detectArch();
    sysio.setEnv("DHAKE_ARCH", opts.arch_value.?, 1);

    if (want_list) {
        opts.applyDefines();
        const root = eval.evalBuildfile(buildfile);
        opts.restoreDefines();
        const b = plan.buildPlan(root);
        var t = b.targets;
        while (t) |tt| : (t = tt.next) {
            var msg: [512]u8 = undefined;
            const is_default = b.default_name != null and
                std.mem.eql(u8, std.mem.span(tt.name), std.mem.span(b.default_name.?));
            const s = std.fmt.bufPrint(&msg, "{s}{s}\n", .{
                std.mem.span(tt.name),
                if (is_default) "  (default)" else "",
            }) catch opts.die("out of memory formatting list");
            out(s);
        }
        std.os.linux.exit_group(0);
    }

    // ─── Build path (wrapped in a loop for --watch rebuild) ──────────────
    var failed: c_int = 0;
    while (true) {
    opts.applyDefines();
    const root = eval.evalBuildfile(buildfile);
    opts.restoreDefines();
    const b = plan.buildPlan(root);

    // Probe landlock ABI (only when sandboxing is requested).
    b.landlock_abi = -1;
    if (b.sandbox_enabled) {
        b.landlock_abi = sandbox.probeLandlock();
        if (b.landlock_abi < 1) {
            if (b.sandbox_read_exec) {
                sysio.writeErr("dhake: error: readExec=True requested read/execute containment but landlock is unavailable (landlock unsupported by kernel)\n");
                sysio.writeErr("dhake: aborting to avoid running recipes unsandboxed; disable readExec or enable landlock\n");
                std.os.linux.exit_group(3);
            }
            sandbox.landlock_warned = true;
            sysio.writeErr("dhake: warning: landlock sandbox unavailable (requested): landlock unsupported by kernel\n");
        }
    }

    // Filter targets by architecture (not in --list/--graph/--lock/--verify/
    // --explain paths, which are topology dumps).
    if (opts.lock_path == null and !opts.want_verify and !opts.want_explain and opts.graph_format == null) {
        graph.filterArch(b);
    }
    graph.resolveDeps(b);

    var n: usize = 0;
    const order = graph.topoOrder(b, &n);
    defer std.heap.c_allocator.free(order);

    // Decide the requested target set.
    var roots: std.ArrayListUnmanaged(*plan.Target) = .empty;
    defer roots.deinit(std.heap.c_allocator);
    if (wanted.items.len > 0) {
        for (wanted.items) |w| {
            const t = graph.findTarget(b, w) orelse opts.dieFmt("unknown target '{s}'", .{w});
            roots.append(std.heap.c_allocator, t) catch opts.die("out of memory");
        }
    } else {
        if (b.default_name == null) opts.die("no default target (buildfile has no 'default', and no target named on argv)");
        const t = graph.findTarget(b, std.mem.span(b.default_name.?)) orelse
            opts.dieFmt("default target '{s}' not found in 'targets'", .{std.mem.span(b.default_name.?)});
        roots.append(std.heap.c_allocator, t) catch opts.die("out of memory");
    }

    // Mark only the subgraph reachable from the requested roots.
    {
        var tt = b.targets;
        while (tt) |x| : (tt = x.next) x.state = 0;
    }
    graph.markReachable(roots.items, order);

    if (opts.graph_format) |fmt| {
        report.runGraph(b, fmt);
        std.os.linux.exit_group(0);
    }

    if (opts.want_verify) {
        const vrc = report.runVerify(order);
        std.os.linux.exit_group(@intCast(vrc));
    }

    if (opts.want_explain) {
        const ec = report.runExplain(order);
        std.os.linux.exit_group(if (ec != 0) 1 else 0);
    }

    // ─── Parallel scheduler (port of dhake.c:2622-2884) ──────────────────
    failed = 0;

    // Initialize per-target parallel state.
    {
        var tt = b.targets;
        while (tt) |t2| : (tt = t2.next) {
            t2.deps_pending = 0;
            t2.pid = 0;
            t2.dirty = false; // computed below at launch time
        }
    }

    // Compute deps_pending for each reachable target (number of in-subgraph
    // dependency targets still to be satisfied before it is ready).
    for (order[0..n]) |t2| {
        if (t2.state != 1) continue;
        var j: c_int = 0;
        while (j < t2.ndeps) : (j += 1) {
            const d = t2.dep_targets.?[@intCast(j)];
            if (d != null and d.?.state == 1) t2.deps_pending += 1;
        }
    }

    // Ready queue: targets with deps_pending == 0.
    const ready = std.heap.c_allocator.alloc(*plan.Target, n) catch opts.die("out of memory");
    defer std.heap.c_allocator.free(ready);
    var ready_head: usize = 0;
    var ready_tail: usize = 0;
    for (order[0..n]) |t2| {
        if (t2.state == 1 and t2.deps_pending == 0) {
            ready[ready_tail] = t2;
            ready_tail += 1;
        }
    }

    var jobs_running: c_int = 0;

    // If dry-run, force sequential (jobs=1) and just print.
    if (dry_run) jobs = 1;

    while ((ready_head < ready_tail and failed == 0) or jobs_running > 0) {
        // Launch ready targets up to the jobs limit.
        while (jobs_running < jobs and ready_head < ready_tail and failed == 0) {
            const t2 = ready[ready_head];
            ready_head += 1;

            // Compute dirty at launch time (all deps are done).
            const hash_result = hash.hashUptodateDirty(t2);
            var dirty: bool = undefined;
            if (hash_result >= 0) {
                dirty = (hash_result == 1);
            } else {
                var texists = false;
                const tm = sysio.fileMtimeNs(t2.name, &texists);
                dirty = t2.phony or !texists;
                if (!dirty) {
                    var j: c_int = 0;
                    while (j < t2.ndeps) : (j += 1) {
                        const d = t2.dep_targets.?[@intCast(j)];
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
                            const sm = sysio.fileMtimeNs(t2.deps.?[@intCast(j)].?, &sexists);
                            if (!sexists)
                                opts.dieFmt("no rule to make target '{s}', needed by '{s}'", .{ std.mem.span(t2.deps.?[@intCast(j)].?), std.mem.span(t2.name) });
                            if (sm > tm) {
                                dirty = true;
                                break;
                            }
                        }
                    }
                }
            }
            t2.dirty = dirty;

            // Verify dep hashes at launch time (integrity gate on inputs).
            if (t2.ndep_hash > 0) _ = hash.verifyDepHashes(t2);

            if (!dirty) {
                // Verify output hash for up-to-date non-phony targets.
                if (t2.out_hash != null and !t2.phony) _ = hash.verifyOutputHash(t2);
                sysio.writeOutFmt("dhake: '{s}' is up to date\n", .{std.mem.span(t2.name)});
                // mark done: decrement deps_pending for dependents
                {
                    var ix: usize = 0;
                    while (ix < n) : (ix += 1) {
                        const dep = order[ix];
                        if (dep.state != 1) continue;
                        var jj: c_int = 0;
                        while (jj < dep.ndeps) : (jj += 1) {
                            if (dep.dep_targets.?[@intCast(jj)] == t2) {
                                dep.deps_pending -= 1;
                                if (dep.deps_pending == 0) {
                                    ready[ready_tail] = dep;
                                    ready_tail += 1;
                                }
                            }
                        }
                    }
                }
                continue;
            }

            if (t2.recipe == null) {
                if (!t2.phony) opts.dieFmt("no rule to make target '{s}'", .{std.mem.span(t2.name)});
                // phony with no recipe: mark done
                {
                    var ix: usize = 0;
                    while (ix < n) : (ix += 1) {
                        const dep = order[ix];
                        if (dep.state != 1) continue;
                        var jj: c_int = 0;
                        while (jj < dep.ndeps) : (jj += 1) {
                            if (dep.dep_targets.?[@intCast(jj)] == t2) {
                                dep.deps_pending -= 1;
                                if (dep.deps_pending == 0) {
                                    ready[ready_tail] = dep;
                                    ready_tail += 1;
                                }
                            }
                        }
                    }
                }
                continue;
            }

            sysio.writeOutFmt("dhake: building '{s}'\n", .{std.mem.span(t2.name)});

            if (dry_run) {
                // dry-run: print actions sequentially, no fork
                var a = t2.recipe;
                while (a) |aa| : (a = aa.next) exec.printAction(aa);
                // mark done
                {
                    var ix: usize = 0;
                    while (ix < n) : (ix += 1) {
                        const dep = order[ix];
                        if (dep.state != 1) continue;
                        var jj: c_int = 0;
                        while (jj < dep.ndeps) : (jj += 1) {
                            if (dep.dep_targets.?[@intCast(jj)] == t2) {
                                dep.deps_pending -= 1;
                                if (dep.deps_pending == 0) {
                                    ready[ready_tail] = dep;
                                    ready_tail += 1;
                                }
                            }
                        }
                    }
                }
                continue;
            }

            // Cache check: if caching is enabled and we have a cache hit, restore and skip.
            if (opts.cache_dir != null and !t2.phony) {
                var ck: [65]u8 = undefined;
                if (hash.cacheKey(t2, &ck) and hash.cacheHit(ck[0..64])) {
                    if (hash.cacheRestore(t2, ck[0..64])) {
                        t2.dirty = false;
                        if (!opts.quiet) sysio.writeOutFmt("dhake: '{s}' from cache\n", .{std.mem.span(t2.name)});
                        // mark done: same decrement-dependents block
                        {
                            var ix: usize = 0;
                            while (ix < n) : (ix += 1) {
                                const dep = order[ix];
                                if (dep.state != 1) continue;
                                var jj: c_int = 0;
                                while (jj < dep.ndeps) : (jj += 1) {
                                    if (dep.dep_targets.?[@intCast(jj)] == t2) {
                                        dep.deps_pending -= 1;
                                        if (dep.deps_pending == 0) {
                                            ready[ready_tail] = dep;
                                            ready_tail += 1;
                                        }
                                    }
                                }
                            }
                        }
                        continue;
                    }
                }
            }

            // Fork a child to run the recipe.
            const pid = std.os.linux.fork();
            if (std.os.linux.errno(pid) != .SUCCESS) {
                sysio.writeErrFmt("dhake: fork failed: {s}\n", .{std.mem.span(strerror(@intFromEnum(std.os.linux.errno(pid))))});
                failed = 2;
                break;
            }

            if (pid == 0) {
                // Child: sandbox (landlock) then run the full recipe, then _exit.
                sandbox.sandboxChild(b, t2);
                if (t2.cwd != null) {
                    const cwdp = t2.cwd.?;
                    const crc = std.os.linux.chdir(cwdp);
                    if (std.os.linux.errno(crc) != .SUCCESS) {
                        sysio.writeErrFmt("dhake: target '{s}': chdir('{s}') failed: {s}\n", .{ std.mem.span(t2.name), std.mem.span(cwdp), std.mem.span(strerror(@intFromEnum(std.os.linux.errno(crc)))) });
                        std.os.linux.exit_group(1);
                    }
                }
                var rc: c_int = 0;
                var a = t2.recipe;
                while (a) |aa| : (a = aa.next) {
                    rc = exec.runAction(aa);
                    if (rc != 0) break;
                }
                std.os.linux.exit_group(@intCast(rc));
            }

            // Parent: record pid and increment jobs_running.
            t2.pid = @intCast(pid);
            jobs_running += 1;
        }

        // Reap completed children.
        if (jobs_running > 0) {
            var status: u32 = 0;
            const done_pid = std.os.linux.waitpid(-1, &status, 0);
            if (std.os.linux.errno(done_pid) != .SUCCESS) {
                if (std.os.linux.errno(done_pid) == .INTR) continue;
                sysio.writeErrFmt("dhake: waitpid failed: {s}\n", .{std.mem.span(strerror(@intFromEnum(std.os.linux.errno(done_pid))))});
                failed = 2;
                break;
            }

            jobs_running -= 1;

            // Find the target by pid.
            var completed: ?*plan.Target = null;
            {
                var ix: usize = 0;
                while (ix < n) : (ix += 1) {
                    const t2 = order[ix];
                    if (t2.state == 1 and t2.pid == @as(c_int, @intCast(done_pid))) {
                        completed = t2;
                        break;
                    }
                }
            }

            const ct = completed orelse {
                sysio.writeErrFmt("dhake: internal error: unknown pid {d}\n", .{done_pid});
                failed = 2;
                break;
            };

            // Get exit code.
            const rc: c_int = if (exec.wifexited(status)) exec.wexitstatus(status) else 2;

            if (rc != 0 and failed == 0) {
                failed = rc; // stop scheduling new targets, but keep reaping
            }

            // Mark target as done. Only a SUCCESSFUL target unblocks its
            // dependents — a failed one must not schedule them.
            if (rc == 0) {
                // Verify output hash for successful non-phony targets.
                var out_ok = true;
                if (ct.out_hash != null and !ct.phony) {
                    out_ok = (hash.verifyOutputHash(ct) == 0);
                    if (out_ok)
                        sysio.writeOutFmt("dhake: '{s}' verified (hash {s})\n", .{ std.mem.span(ct.name), std.mem.span(ct.out_hash.?.spec.?) });
                }
                // Store in cache if enabled (skip caching output that failed
                // hash verification under --warn-hash-mismatch).
                if (out_ok and opts.cache_dir != null and !ct.phony) {
                    var ck: [65]u8 = undefined;
                    if (hash.cacheKey(ct, &ck)) {
                        _ = hash.cacheStore(ct, ck[0..64]);
                    }
                }
                {
                    var ix: usize = 0;
                    while (ix < n) : (ix += 1) {
                        const dep = order[ix];
                        if (dep.state != 1) continue;
                        var jj: c_int = 0;
                        while (jj < dep.ndeps) : (jj += 1) {
                            if (dep.dep_targets.?[@intCast(jj)] == ct) {
                                dep.deps_pending -= 1;
                                if (dep.deps_pending == 0) {
                                    ready[ready_tail] = dep;
                                    ready_tail += 1;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Write lockfile if requested, only on success, not dry-run, not --list.
    if (opts.lock_path != null and !dry_run and failed == 0) {
        report.writeLockfile(b, opts.lock_path.?);
    }

    // Watch mode: set up inotify and wait for changes.
    if (opts.watch_mode) {
        var nwatch: usize = 0;
        const wf = watch.collectWatchFiles(b, buildfile, &nwatch);
        defer std.heap.c_allocator.free(wf);
        var dirs: []watch.WatchDir = &.{};
        const ifd = watch.setupWatch(wf, &dirs);
        defer {
            for (dirs) |d| {
                std.heap.c_allocator.free(d.dir);
                std.heap.c_allocator.free(d.files);
            }
            std.heap.c_allocator.free(dirs);
        }
        if (ifd < 0) {
            sysio.writeErrFmt("dhake: --watch requires Linux inotify: {s}\n", .{watch.errstr(watch.last_errno)});
            break;
        }
        sysio.writeOutFmt("dhake: watching {d} file(s) for changes (Ctrl-C to quit)\n", .{nwatch});
        const ch = watch.waitForChange(ifd, dirs);
        _ = std.os.linux.close(ifd);
        if (ch == 1) {
            sysio.writeOut("dhake: change detected, rebuilding...\n");
            continue; // rebuild
        } else {
            // watch read failed (error/EOF): report it, don't silently exit 0.
            sysio.writeErrFmt("dhake: --watch: error waiting for changes: {s}\n", .{watch.errstr(@intCast(5))});
            failed = 2;
            break;
        }
    }

    break; // not in watch mode, exit after one build
    }

    std.os.linux.exit_group(@intCast(failed));
}
