// sandbox.zig — landlock + seccomp sandbox (write-containment + optional
// read/execute containment + optional network denial).
//
// U4 port of dhake.c:1119-1408 (the C source is the spec and is NOT modified).
// Two independent mechanisms:
//   * seccomp_deny_network (dhake.c:1286-1357): a classic-BPF filter installed
//     via prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER) that denies socket() for
//     AF_INET/AF_INET6/AF_PACKET/AF_NETLINK (EPERM) and allows everything else
//     (incl. AF_UNIX/AF_LOCAL).
//   * landlock (dhake.c:1119-1268): a path-beneath ruleset that handles only
//     the WRITE-class rights by default, or READ_FILE/READ_DIR/EXECUTE too when
//     sandbox_read_exec is set. Applied in the recipe child after fork.
//
// Fail-open vs fail-closed: in write-containment mode (readExec=False) a
// landlock failure is a single warning and the recipe runs unsandboxed. When
// readExec=True the user explicitly opted into read/execute containment, so we
// fail CLOSED (exit 3) rather than silently running unsandboxed. denyNetwork is
// likewise fail-closed.
const std = @import("std");
const builtin = @import("builtin");
const plan = @import("plan.zig");
const sysio = @import("sysio.zig");

extern fn strerror(errnum: c_int) [*:0]const u8;

pub var landlock_warned: bool = false;

// ─── Landlock ABI / rule constants (Linux landlock.h) ────────────────────
const LANDLOCK_CREATE_RULESET_VERSION: u32 = 1;
const LANDLOCK_RULE_PATH_BENEATH: u32 = 1;

const LANDLOCK_ACCESS_FS_EXECUTE: u64 = 1 << 0;
const LANDLOCK_ACCESS_FS_WRITE_FILE: u64 = 1 << 1;
const LANDLOCK_ACCESS_FS_READ_FILE: u64 = 1 << 2;
const LANDLOCK_ACCESS_FS_READ_DIR: u64 = 1 << 3;
const LANDLOCK_ACCESS_FS_REMOVE_DIR: u64 = 1 << 4;
const LANDLOCK_ACCESS_FS_REMOVE_FILE: u64 = 1 << 5;
const LANDLOCK_ACCESS_FS_MAKE_CHAR: u64 = 1 << 6;
const LANDLOCK_ACCESS_FS_MAKE_DIR: u64 = 1 << 7;
const LANDLOCK_ACCESS_FS_MAKE_REG: u64 = 1 << 8;
const LANDLOCK_ACCESS_FS_MAKE_SOCK: u64 = 1 << 9;
const LANDLOCK_ACCESS_FS_MAKE_FIFO: u64 = 1 << 10;
const LANDLOCK_ACCESS_FS_MAKE_BLOCK: u64 = 1 << 11;
const LANDLOCK_ACCESS_FS_MAKE_SYM: u64 = 1 << 12;
const LANDLOCK_ACCESS_FS_REFER: u64 = 1 << 13; // abi >= 2
const LANDLOCK_ACCESS_FS_TRUNCATE: u64 = 1 << 14; // abi >= 3

const RulesetAttr = extern struct {
    handled_access_fs: u64,
};

const PathBeneathAttr = extern struct {
    allowed_access: u64,
    parent_fd: i32,
};
comptime {
    // The kernel's landlock_path_beneath_attr is `__attribute__((packed))`
    // (u64 + s32 = 12 bytes); only parent_fd's offset and the first 12 bytes
    // are ever read, so the LP64 padding is harmless. u64 is 4-byte aligned
    // on i386, so the same extern struct is 12 bytes there and 16 on LP64 —
    // pin the layout this target actually produces (offset first: it is the
    // one the kernel depends on).
    std.debug.assert(@offsetOf(PathBeneathAttr, "parent_fd") == 8);
    std.debug.assert(@sizeOf(PathBeneathAttr) == if (@sizeOf(usize) == 8) 16 else 12);
}

// ─── seccomp BPF filter types (linux/filter.h) ───────────────────────────
const SockFilter = extern struct {
    code: u16,
    jt: u8,
    jf: u8,
    k: u32,
};

const SockFprog = extern struct {
    len: u16,
    filter: [*]const SockFilter,
};

// Classic-BPF opcodes used by the filter (BPF_* bitfields combined exactly as
// the C macros BPF_STMT / BPF_JUMP produce them).
const BPF_LD_W_ABS: u16 = 0x00 | 0x00 | 0x20; // BPF_LD | BPF_W | BPF_ABS
const BPF_JMP_JEQ_K: u16 = 0x05 | 0x10 | 0x00; // BPF_JMP | BPF_JEQ | BPF_K
const BPF_RET_K: u16 = 0x06 | 0x00; // BPF_RET | BPF_K

// seccomp verdicts (std/os/linux/seccomp.zig).
const SECCOMP_RET_KILL = std.os.linux.SECCOMP.RET.KILL;
const SECCOMP_RET_ALLOW = std.os.linux.SECCOMP.RET.ALLOW;
const SECCOMP_RET_ERRNO = std.os.linux.SECCOMP.RET.ERRNO;
const SECCOMP_RET_DATA = std.os.linux.SECCOMP.RET.DATA;
const EPERM: u32 = 1;

// Compile-time architecture gate. Replaces the C runtime getauxval(AT_PLATFORM)
// check (dhake.c:1293-1296). For a native binary this is equivalent: the Zig
// binary is compiled for exactly the arch it runs on, and only x86_64/aarch64
// are supported. INTENTIONAL DIVERGENCE (documented per plan U4).
const arch_ok = (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64);

/// seccomp BPF filter to deny network socket creation (dhake.c:1286-1357).
/// Returns 0 on success, -1 on failure.
fn seccompDenyNetwork() c_int {
    // Test hook: force the fail-closed path (simulate seccomp being
    // unavailable) so tests can deterministically exercise the _exit(3)
    // branch regardless of host seccomp support.
    if (sysio.envGet("DHAKE_FORCE_NO_SECCOMP") != null) return -1;

    if (!arch_ok) return -1;

    const off_arch = @offsetOf(std.os.linux.SECCOMP.data, "arch");
    const off_nr = @offsetOf(std.os.linux.SECCOMP.data, "nr");
    const off_arg0 = @offsetOf(std.os.linux.SECCOMP.data, "arg0");

    const socket_nr = @intFromEnum(std.os.linux.SYS.socket);

    // 13-instruction filter, layout identical to dhake.c:1317-1344.
    // 0:  LD arch
    // 1:  JEQ x86_64   jt=2 jf=0   x86 -> 4 ; else -> 2
    // 2:  JEQ aarch64  jt=1 jf=0   arm -> 4 ; else -> 3
    // 3:  RET KILL (unrecognized arch)
    // 4:  LD syscall nr
    // 5:  JEQ __NR_socket jt=0 jf=5  socket -> 6 ; else -> 11 (ALLOW)
    // 6:  LD args[0] (domain)
    // 7:  JEQ AF_INET   jt=4 jf=0   -> 12 (deny) ; else -> 8
    // 8:  JEQ AF_INET6  jt=3 jf=0   -> 12 (deny) ; else -> 9
    // 9:  JEQ AF_PACKET jt=2 jf=0   -> 12 (deny) ; else -> 10
    // 10: JEQ AF_NETLINK jt=1 jf=0  -> 12 (deny) ; else -> 11
    // 11: RET ALLOW (AF_UNIX/AF_LOCAL and other domains)
    // 12: RET ERRNO|EPERM (denied network domains)
    const filter = [_]SockFilter{
        // Load architecture
        .{ .code = BPF_LD_W_ABS, .jt = 0, .jf = 0, .k = off_arch },
        // x86_64: if equal, skip past aarch64 check + kill to LD nr (instr 4)
        .{ .code = BPF_JMP_JEQ_K, .jt = 2, .jf = 0, .k = 0xC000003E }, // AUDIT_ARCH_X86_64
        // aarch64: if equal, skip past kill to LD nr (instr 4)
        .{ .code = BPF_JMP_JEQ_K, .jt = 1, .jf = 0, .k = 0xC00000B7 }, // AUDIT_ARCH_AARCH64
        // Kill other architectures
        .{ .code = BPF_RET_K, .jt = 0, .jf = 0, .k = SECCOMP_RET_KILL },
        // Load syscall number
        .{ .code = BPF_LD_W_ABS, .jt = 0, .jf = 0, .k = off_nr },
        // If not socket, skip to ALLOW (instr 11); if socket, fall through to domain check
        .{ .code = BPF_JMP_JEQ_K, .jt = 0, .jf = 5, .k = socket_nr },
        // Load first arg (domain)
        .{ .code = BPF_LD_W_ABS, .jt = 0, .jf = 0, .k = off_arg0 },
        // Check AF_INET: if equal, skip to deny (instr 12); else go to next
        .{ .code = BPF_JMP_JEQ_K, .jt = 4, .jf = 0, .k = @intCast(std.os.linux.AF.INET) },
        // Check AF_INET6: if equal, skip to deny (instr 12); else go to next
        .{ .code = BPF_JMP_JEQ_K, .jt = 3, .jf = 0, .k = @intCast(std.os.linux.AF.INET6) },
        // Check AF_PACKET: if equal, skip to deny (instr 12); else go to next
        .{ .code = BPF_JMP_JEQ_K, .jt = 2, .jf = 0, .k = @intCast(std.os.linux.AF.PACKET) },
        // Check AF_NETLINK: if equal, skip to deny (instr 12); else go to next (allow)
        .{ .code = BPF_JMP_JEQ_K, .jt = 1, .jf = 0, .k = @intCast(std.os.linux.AF.NETLINK) },
        // Allow AF_UNIX/AF_LOCAL and any other domain
        .{ .code = BPF_RET_K, .jt = 0, .jf = 0, .k = SECCOMP_RET_ALLOW },
        // Deny network socket domains
        .{ .code = BPF_RET_K, .jt = 0, .jf = 0, .k = SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA) },
    };

    var prog = SockFprog{ .len = @intCast(filter.len), .filter = &filter };

    // PR_SET_NO_NEW_PRIVS (idempotent; may already be set by landlock)
    const nn = std.os.linux.prctl(38, 1, 0, 0, 0);
    if (std.os.linux.errno(nn) != .SUCCESS) return -1;

    // PR_SET_SECCOMP, SECCOMP_MODE_FILTER
    const sc = std.os.linux.prctl(22, 2, @intFromPtr(&prog), 0, 0);
    if (std.os.linux.errno(sc) != .SUCCESS) return -1;

    return 0;
}

/// Return the full handled access mask based on sandbox_read_exec flag
/// (dhake.c:1133-1156).
fn landlockWriteHandled(abi: c_int) u64 {
    var h: u64 = LANDLOCK_ACCESS_FS_WRITE_FILE |
        LANDLOCK_ACCESS_FS_REMOVE_DIR |
        LANDLOCK_ACCESS_FS_REMOVE_FILE |
        LANDLOCK_ACCESS_FS_MAKE_CHAR |
        LANDLOCK_ACCESS_FS_MAKE_DIR |
        LANDLOCK_ACCESS_FS_MAKE_REG |
        LANDLOCK_ACCESS_FS_MAKE_SOCK |
        LANDLOCK_ACCESS_FS_MAKE_FIFO |
        LANDLOCK_ACCESS_FS_MAKE_BLOCK |
        LANDLOCK_ACCESS_FS_MAKE_SYM;
    if (abi >= 2) h |= LANDLOCK_ACCESS_FS_REFER;
    if (abi >= 3) h |= LANDLOCK_ACCESS_FS_TRUNCATE;
    return h;
}

fn landlockHandledMask(b: *plan.Build) u64 {
    var h = landlockWriteHandled(b.landlock_abi);
    if (b.sandbox_read_exec) {
        h |= LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR | LANDLOCK_ACCESS_FS_EXECUTE;
    }
    return h;
}

/// Map a perms string ({r,w,c,x}) to landlock rights (dhake.c:1169-1189).
/// `read_exec` must be TRUE for the r/x mappings to be emitted — required for
/// correctness: when read/execute are not handled, the kernel rejects a rule
/// whose allowed_access includes rights absent from the handled_access_fs mask
/// (landlock_add_rule returns EINVAL). So in write-only mode r/x map to zero.
fn landlockPermsRights(perms: []const u8, abi: c_int, read_exec: bool) u64 {
    var h: u64 = 0;
    for (perms) |ch| {
        if (ch == 'w') {
            h |= LANDLOCK_ACCESS_FS_WRITE_FILE;
            if (abi >= 2) h |= LANDLOCK_ACCESS_FS_REFER;
            if (abi >= 3) h |= LANDLOCK_ACCESS_FS_TRUNCATE;
        } else if (ch == 'c') {
            h |= LANDLOCK_ACCESS_FS_MAKE_CHAR |
                LANDLOCK_ACCESS_FS_MAKE_DIR |
                LANDLOCK_ACCESS_FS_MAKE_REG |
                LANDLOCK_ACCESS_FS_MAKE_SOCK |
                LANDLOCK_ACCESS_FS_MAKE_FIFO |
                LANDLOCK_ACCESS_FS_MAKE_BLOCK |
                LANDLOCK_ACCESS_FS_MAKE_SYM |
                LANDLOCK_ACCESS_FS_REMOVE_DIR |
                LANDLOCK_ACCESS_FS_REMOVE_FILE;
        } else if (ch == 'r' and read_exec) {
            h |= LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR;
        } else if (ch == 'x' and read_exec) {
            h |= LANDLOCK_ACCESS_FS_EXECUTE;
        }
    }
    return h;
}

/// Add a path-beneath rule for `path` (dhake.c:1194-1201). Non-fatal on open
/// failure (path not yet created) — landlock rules are on inodes.
fn landlockAllow(rfd: c_int, path: []const u8, rights: u64) void {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .PATH = true, .CLOEXEC = true }, 0) catch return;
    var a = PathBeneathAttr{ .allowed_access = rights, .parent_fd = fd };
    // syscallN's arg width is target-dependent (u64 on x86_64, u32 on i386):
    // let @intCast infer it rather than pinning u64.
    const rc = std.os.linux.syscall4(.landlock_add_rule, @intCast(rfd), LANDLOCK_RULE_PATH_BENEATH, @intFromPtr(&a), 0);
    if (std.os.linux.errno(rc) != .SUCCESS) {
        sysio.writeErrFmt("dhake: warning: landlock_add_rule('{s}'): {s}\n", .{
            path,
            std.mem.span(strerror(@intFromEnum(std.os.linux.errno(rc)))),
        });
    }
    _ = std.os.linux.close(fd);
}

/// Split an unveil entry "perms:path" (perms default rwc) (dhake.c:1205-1222).
fn landlockParseEntry(entry: []const u8, perms_buf: []u8) struct { perms: []const u8, path: []const u8 } {
    if (std.mem.indexOfScalar(u8, entry, ':')) |colon| {
        if (colon != 0) {
            const plen = colon;
            var ok = (plen >= 1 and plen <= 4); // real perms tokens are short: max "rwcx"
            for (entry[0..plen]) |c| {
                if (!(c == 'r' or c == 'w' or c == 'c' or c == 'x')) ok = false;
            }
            if (ok and colon + 1 < entry.len and plen < perms_buf.len) { // non-empty path after ':'
                @memcpy(perms_buf[0..plen], entry[0..plen]);
                perms_buf[plen] = 0;
                return .{ .perms = perms_buf[0..plen], .path = entry[colon + 1 ..] };
            }
        }
    }
    @memcpy(perms_buf[0..3], "rwc");
    perms_buf[3] = 0;
    return .{ .perms = perms_buf[0..3], .path = entry };
}

/// Add one whitelist entry ("perms:path"), expanding a leading ~ to $HOME
/// (dhake.c:1225-1242).
fn landlockAllowEntry(rfd: c_int, entry: []const u8, abi: c_int, read_exec: bool) void {
    var perms_buf: [8]u8 = undefined;
    const pe = landlockParseEntry(entry, &perms_buf);
    const rights = landlockPermsRights(pe.perms, abi, read_exec);
    if (rights == 0) return; // e.g. a pure "r:path" entry in v1
    var path = pe.path;
    if (path.len >= 1 and path[0] == '~' and (path.len == 1 or path[1] == '/')) {
        if (sysio.envGet("HOME")) |home| {
            if (home.len > 0) {
                const rest = path[1..];
                const c = std.heap.c_allocator;
                const buf = c.alloc(u8, home.len + rest.len + 1) catch return;
                defer c.free(buf);
                @memcpy(buf[0..home.len], home);
                @memcpy(buf[home.len .. home.len + rest.len], rest);
                buf[home.len + rest.len] = 0;
                path = buf[0 .. home.len + rest.len];
            }
        }
    }
    landlockAllow(rfd, path, rights);
}

/// Auto-unveil standard toolchain directories for read/execute containment
/// (dhake.c:1247-1268). Bin/lib dirs get R|X, include dirs get R.
fn landlockAutoReadExec(rfd: c_int) void {
    const r_x = LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR | LANDLOCK_ACCESS_FS_EXECUTE;
    const r = LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR;

    // Bin dirs (R|X)
    landlockAllow(rfd, "/usr/bin", r_x);
    landlockAllow(rfd, "/bin", r_x);
    landlockAllow(rfd, "/usr/sbin", r_x);
    landlockAllow(rfd, "/sbin", r_x);
    landlockAllow(rfd, "/usr/local/bin", r_x);

    // Lib dirs (R|X)
    landlockAllow(rfd, "/usr/lib", r_x);
    landlockAllow(rfd, "/lib", r_x);
    landlockAllow(rfd, "/usr/lib64", r_x);
    landlockAllow(rfd, "/lib64", r_x);
    landlockAllow(rfd, "/usr/local/lib", r_x);

    // Include dirs (R)
    landlockAllow(rfd, "/usr/include", r);
    landlockAllow(rfd, "/usr/local/include", r);
}

/// sandbox_fail (dhake.c:1359-1367).
fn sandboxFail(b: *plan.Build, why: []const u8) void {
    sysio.writeErrFmt("dhake: {s}: landlock sandbox unavailable (requested): {s}\n", .{
        if (b.sandbox_read_exec) "error" else "warning",
        why,
    });
    if (b.sandbox_read_exec) {
        sysio.writeErr("dhake: readExec=True requested read/execute containment but landlock could not be established; aborting to avoid running unsandboxed\n");
        std.os.linux.exit_group(3);
    }
    if (!landlock_warned) landlock_warned = true;
}

// Probe the landlock ABI version via landlock_create_ruleset(NULL, 0,
// LANDLOCK_CREATE_RULESET_VERSION=1). Returns the version (>=1) or -1.
pub fn probeLandlock() c_int {
    const rc = std.os.linux.syscall3(.landlock_create_ruleset, 0, 0, LANDLOCK_CREATE_RULESET_VERSION);
    if (std.os.linux.errno(rc) != .SUCCESS) return -1;
    return @intCast(rc);
}

/// sandbox_child (dhake.c:1369-1408). Apply the sandbox to the CURRENT process
/// (called in the recipe child right after fork). Landlock restricts this
/// thread + its future children.
pub fn sandboxChild(b: *plan.Build, t: ?*plan.Target) void {
    if (!b.sandbox_enabled) return;
    if (b.sandbox_deny_network and seccompDenyNetwork() != 0) {
        sysio.writeErr("dhake: error: denyNetwork=True requested network containment but seccomp could not be established; aborting to avoid running unsandboxed\n");
        std.os.linux.exit_group(3);
    }
    if (b.landlock_abi < 1) {
        sandboxFail(b, "landlock unsupported by kernel");
        return;
    }

    const nn = std.os.linux.prctl(38, 1, 0, 0, 0);
    if (std.os.linux.errno(nn) != .SUCCESS) {
        sandboxFail(b, std.mem.span(strerror(@intFromEnum(std.os.linux.errno(nn)))));
        return;
    }

    var attr = RulesetAttr{ .handled_access_fs = landlockHandledMask(b) };
    const rfd_rc = std.os.linux.syscall3(.landlock_create_ruleset, @intFromPtr(&attr), @sizeOf(RulesetAttr), 0);
    if (std.os.linux.errno(rfd_rc) != .SUCCESS) {
        sandboxFail(b, std.mem.span(strerror(@intFromEnum(std.os.linux.errno(rfd_rc)))));
        return;
    }
    const rfd: c_int = @intCast(rfd_rc);

    // auto-unveil: build dir + /tmp + $TMPDIR + device nulls.
    // Use rwcx for cwd and /tmp so outputs and node_modules can be executed.
    // When readExec is off, r/x map to zero (not handled), so this reduces to
    // the previous write-containment rwc behavior.
    const rwcx = landlockPermsRights("rwcx", b.landlock_abi, b.sandbox_read_exec);
    landlockAllow(rfd, ".", rwcx);
    landlockAllow(rfd, "/tmp", rwcx);
    if (sysio.envGet("TMPDIR")) |td| {
        if (td.len > 0 and !std.mem.eql(u8, td, "/tmp")) landlockAllow(rfd, td, rwcx);
    }
    const dev_rights = LANDLOCK_ACCESS_FS_WRITE_FILE | (if (b.sandbox_read_exec) LANDLOCK_ACCESS_FS_READ_FILE else 0);
    landlockAllow(rfd, "/dev/null", dev_rights);
    landlockAllow(rfd, "/dev/zero", dev_rights);
    landlockAllow(rfd, "/dev/full", dev_rights);
    landlockAllow(rfd, "/dev/tty", dev_rights);

    // Auto-unveil toolchain dirs when readExec is enabled
    if (b.sandbox_read_exec) {
        landlockAutoReadExec(rfd);
    }

    // global then per-target whitelist
    if (b.unveil) |u| {
        for (0..@as(usize, @intCast(b.nunveil))) |i| landlockAllowEntry(rfd, std.mem.span(u[i].?), b.landlock_abi, b.sandbox_read_exec);
    }
    if (t) |tt| {
        if (tt.unveil) |u| {
            for (0..@as(usize, @intCast(tt.nunveil))) |i| landlockAllowEntry(rfd, std.mem.span(u[i].?), b.landlock_abi, b.sandbox_read_exec);
        }
    }

    const rs = std.os.linux.syscall2(.landlock_restrict_self, @intCast(rfd), 0);
    if (std.os.linux.errno(rs) != .SUCCESS) {
        sandboxFail(b, std.mem.span(strerror(@intFromEnum(std.os.linux.errno(rs)))));
        _ = std.os.linux.close(rfd);
        return;
    }
    _ = std.os.linux.close(rfd);
}
