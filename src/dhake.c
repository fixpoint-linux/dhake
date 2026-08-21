/* dhake.c — dhake: a Make-like build tool driven by a Dhall buildfile.
 *
 * The buildfile is a Dhall expression that normalizes to a value of the
 * documented shape (see the plan).  This tool links the dhall-c interpreter
 * core (every src .c file EXCEPT main.c) and drives it in-process:
 *
 *     parse_source -> normalize -> (walk the normalized Term tree)
 *
 * NOTE: infer_type() is deliberately NOT called.  The ergonomic action-DSL
 * uses the shorthand union literal < Tag = v >, whose inferred type is a
 * *singleton* union (< Tag : T >).  A buildfile containing heterogeneous
 * singleton unions across targets therefore does NOT typecheck (list
 * elements must be homogeneous), even though it normalizes correctly.
 * Structural validation is done here by walking the normalized tree and
 * reporting clear errors, which is the source of truth for the DSL.
 *
 * Verified against dhall-c HEAD (src/parser.c dated 2026-08-20), cosmocc 14.1.0.
 */
#define _GNU_SOURCE 1          /* expose prctl() in cosmopolitan libc */
#include "dhall.h"
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <ftw.h>
#include <fcntl.h>
#include <sys/prctl.h>
#include <libc/calls/landlock.h>
#include <libc/calls/struct/bpf.internal.h>
#include <libc/calls/struct/seccomp.internal.h>
#include <libc/calls/struct/filter.internal.h>
#include <libc/sysv/consts/audit.h>
#include <stddef.h>
#include <sys/auxv.h>

extern const int __NR_socket;

/* ------------------------------------------------------------------ */
/* In-memory build plan                                                */
/* ------------------------------------------------------------------ */

typedef enum { ACT_SHELL, ACT_COPY, ACT_MKDIR, ACT_RM, ACT_TOUCH,
                ACT_MOVE, ACT_SYMLINK, ACT_CHMOD, ACT_ECHO, ACT_ENV, ACT_RUN } ActionKind;

typedef struct Action {
    ActionKind kind;
    char *a;               /* shell command / mkdir / rm / touch path / copy-from / move-from / symlink-from / chmod-path / echo-text / env-key / run-program */
    char *b;               /* copy-to / move-to / symlink-to / chmod-mode / env-value */
    char **av;             /* argv for Run (NULL for others) */
    int nav;              /* argc for Run (0 for others) */
    bool recursive;        /* Mkdir: create missing parents (mkdir -p); Rm: delete tree (rm -rf) */
    struct Action *next;
} Action;

typedef enum { HASH_SHA256 } HashAlg;

typedef struct Hash {
    HashAlg alg;
    char *hex;             /* bare digest for comparison */
    char *spec;            /* original "algo:hex" string for messages */
} Hash;

typedef struct DepHash {
    char *path;
    Hash hash;
} DepHash;

typedef struct Target {
    char *name;
    bool phony;
    char **deps;           /* dep names as strings (buildfile order) */
    int ndeps;
    Action *recipe;        /* linked list, buildfile order */
    /* sandbox unveil whitelist (per-target, "perms:path" entries) */
    char **unveil;
    int nunveil;
    /* verified builds */
    Hash *out_hash;        /* expected output hash (NULL = no check) */
    DepHash *dep_hash;    /* expected dep hashes */
    int ndep_hash;        /* number of dep hashes */
    /* resolved graph state */
    struct Target **dep_targets;   /* resolved Target* per dep */
    int state;             /* 0 unvisited, 1 visiting (cycle), 2 done */
    bool dirty;            /* will (re)build this run */
    /* parallel scheduler state */
    int deps_pending;      /* count of unresolved deps (for parallel scheduling) */
    pid_t pid;             /* 0 if not running */
    struct Target *next;   /* intrusive list */
} Target;

typedef struct {
    Target *targets;       /* linked list, buildfile order */
    int ntargets;
    char *default_name;    /* NULL if none */
    /* landlock sandbox config (from optional top-level `sandbox` field) */
    bool sandbox_enabled;
    bool sandbox_read_exec; /* when true, also handle READ_FILE|READ_DIR|EXECUTE */
    bool sandbox_deny_network; /* when true, deny network socket creation via seccomp */
    char **unveil;         /* global "perms:path" whitelist entries */
    int nunveil;
    int landlock_abi;      /* probe result; <1 => unavailable */
} Build;

static Target *find_target(Build *b, const char *name);  /* fwd decl (defined later) */

/* ------------------------------------------------------------------ */
/* Small helpers                                                       */
/* ------------------------------------------------------------------ */

static void die(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fputs("dhake: error: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    exit(2);
}

static char *read_file(const char *path, size_t *len_out) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    size_t cap = 65536, len = 0;
    char *buf = malloc(cap);
    if (!buf) { fclose(f); return NULL; }
    for (;;) {
        if (len == cap) { cap *= 2; char *nb = realloc(buf, cap); if (!nb) { free(buf); fclose(f); return NULL; } buf = nb; }
        size_t n = fread(buf + len, 1, cap - len, f);
        len += n;
        if (n == 0) break;
    }
    buf[len] = '\0';
    fclose(f);
    if (len_out) *len_out = len;
    return buf;
}

/* Parse a hash spec string (e.g. "sha256:abc123...") into a Hash struct.
 * Dies on parse error, unsupported algorithm, or invalid hex length/chars.
 * The hex digest is normalized to lowercase for comparison. */
static Hash parse_hash(const char *spec, const char *where) {
    if (!spec) die("%s: hash spec is NULL", where);
    const char *colon = strchr(spec, ':');
    if (!colon) die("%s: hash spec '%s' must be '<algorithm>:<hexdigest>'", where, spec);
    size_t algo_len = (size_t)(colon - spec);
    const char *algo = spec;
    const char *hex_part = colon + 1;
    
    if (algo_len == 0) die("%s: hash spec '%s' has empty algorithm", where, spec);
    
    /* Check algorithm */
    char algo_buf[16];
    if (algo_len >= sizeof(algo_buf)) die("%s: algorithm name too long in '%s'", where, spec);
    memcpy(algo_buf, algo, algo_len);
    algo_buf[algo_len] = '\0';
    
    HashAlg alg;
    if (!strcmp(algo_buf, "sha256")) {
        alg = HASH_SHA256;
    } else {
        die("%s: unsupported hash algorithm '%s' (supported: sha256)", where, algo_buf);
    }
    
    /* Validate hex length: sha256 expects exactly 64 hex chars */
    size_t hex_len = strlen(hex_part);
    if (hex_len != 64) die("%s: hash spec '%s' has %zu hex chars, expected 64 for sha256", where, spec, hex_len);
    
    /* Validate all chars are hex digits */
    for (size_t i = 0; i < hex_len; i++) {
        char c = hex_part[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')))
            die("%s: hash spec '%s' contains non-hex character at position %zu", where, spec, i);
    }
    
    /* Normalize hex to lowercase */
    char *hex_normalized = malloc(65);
    if (!hex_normalized) die("out of memory");
    for (size_t i = 0; i < 64; i++) {
        char c = hex_part[i];
        if (c >= 'A' && c <= 'F') hex_normalized[i] = c - 'A' + 'a';
        else hex_normalized[i] = c;
    }
    hex_normalized[64] = '\0';
    
    Hash h = {
        .alg = alg,
        .hex = hex_normalized,
        .spec = strdup(spec)
    };
    if (!h.spec) die("out of memory");
    return h;
}

/* Compute SHA-256 hex digest of a file. out must be a 65-byte buffer (64 hex chars + NUL).
 * Returns true on success, false on file error. */
static bool file_sha256_hex(const char *path, char out[65]);

/* Compute hash of a file. out must be a 65-byte buffer (64 hex chars + NUL).
 * Returns true on success, false on file error. */
static bool file_hash(const Hash *h, const char *path, char out[65]) {
    switch (h->alg) {
    case HASH_SHA256:
        return file_sha256_hex(path, out);
    default:
        die("file_hash: unsupported algorithm %d", h->alg);
        return false;
    }
}

/* Compute SHA-256 hex digest of a file. out must be a 65-byte buffer (64 hex chars + NUL).
 * Returns true on success, false on file error. */
static bool file_sha256_hex(const char *path, char out[65]) {
    size_t len = 0;
    char *data = read_file(path, &len);
    if (!data) return false;
    sha256_hex(data, len, out);
    free(data);
    return true;
}

static void print_dhall_error(const DhallError *e) {
    fprintf(stderr, "dhake: error: %s", e->msg);
    if (e->has_span) {
        if (e->span.file) fprintf(stderr, " (at %s:%d:%d)", e->span.file, e->span.line, e->span.col);
        else fprintf(stderr, " (at line %d, col %d)", e->span.line, e->span.col);
    }
    fputc('\n', stderr);
}

/* ------------------------------------------------------------------ */
/* Normalized Term -> C string / scalar helpers                       */
/* ------------------------------------------------------------------ */

/* Extract a fully-collapsed Text literal as a malloc'd C string.
 * Returns NULL if t is not Text or still has unresolved interpolation. */
static char *term_text_cstr(Term *t) {
    if (!t || t->tag != TmText) return NULL;
    size_t len = 0;
    for (TextPart *p = t->as.text; p; p = p->next) {
        if (p->expr) return NULL;          /* stuck interpolation */
        if (p->lit) len += strlen(p->lit);
    }
    char *out = malloc(len + 1);
    if (!out) return NULL;
    char *q = out;
    for (TextPart *p = t->as.text; p; p = p->next)
        if (p->lit) { size_t l = strlen(p->lit); memcpy(q, p->lit, l); q += l; }
    *q = '\0';
    return out;
}

/* find a field value by label in a record literal; NULL if absent or not a record */
static Term *rec_get(Term *rec, const char *label) {
    if (!rec || rec->tag != TmRecordLit) return NULL;
    for (int i = 0; i < rec->as.rec.n; i++)
        if (!strcmp(rec->as.rec.fs[i].label, label))
            return rec->as.rec.fs[i].value;
    return NULL;
}

/* read a required Text field; die() with a clear message on shape error */
static char *rec_need_text(Term *rec, const char *label, const char *where) {
    Term *f = rec_get(rec, label);
    if (!f) die("%s: missing field '%s'", where, label);
    char *s = term_text_cstr(f);
    if (!s) die("%s: field '%s' must be Text", where, label);
    return s;
}

static bool rec_bool(Term *rec, const char *label, bool dflt, const char *where) {
    Term *f = rec_get(rec, label);
    if (!f) return dflt;
    if (f->tag != TmConst || f->as.c.kind != C_BOOL)
        die("%s: field '%s' must be Bool", where, label);
    return f->as.c.b;
}

static int list_length(Term *list) {
    int n = 0;
    for (Term *p = list; p && p->tag == TmCons; p = p->as.cons.tail) n++;
    return n;
}

/* Parse an optional `unveil : List Text` field into a strdup'd string array.
 * Returns NULL (n_out=0) when the field is absent. */
static char **parse_unveil_list(Term *rec, const char *where, int *n_out) {
    *n_out = 0;
    Term *u = rec_get(rec, "unveil");
    if (!u) return NULL;
    if (u->tag != TmNil && u->tag != TmCons)
        die("%s: 'unveil' must be a List Text", where);
    int n = list_length(u);
    if (n == 0) return NULL;
    char **out = calloc((size_t)n, sizeof(char *));
    if (!out) die("out of memory");
    int i = 0;
    for (Term *p = u; p && p->tag == TmCons; p = p->as.cons.tail) {
        char *s = term_text_cstr(p->as.cons.head);
        if (!s) die("%s: unveil entry must be Text", where);
        out[i++] = s;
    }
    *n_out = n;
    return out;
}

/* Parse an optional `depsHash : List { path : Text, hash : Text }` field.
 * Returns NULL (n_out=0) when the field is absent. Dies on shape errors. */
static DepHash *parse_dep_hash_list(Term *rec, const char *where, int *n_out) {
    *n_out = 0;
    Term *list = rec_get(rec, "depsHash");
    if (!list) return NULL;
    if (list->tag != TmNil && list->tag != TmCons)
        die("%s: 'depsHash' must be a List { path : Text, hash : Text }", where);
    int n = list_length(list);
    if (n == 0) return NULL;
    DepHash *out = calloc((size_t)n, sizeof(DepHash));
    if (!out) die("out of memory");
    int i = 0;
    for (Term *p = list; p && p->tag == TmCons; p = p->as.cons.tail) {
        Term *item = p->as.cons.head;
        if (!item || item->tag != TmRecordLit)
            die("%s: depsHash element must be a { path, hash } record", where);
        char *path = rec_need_text(item, "path", where);
        char *hash_spec = rec_need_text(item, "hash", where);
        out[i].path = path;
        out[i].hash = parse_hash(hash_spec, where);
        i++;
    }
    *n_out = n;
    return out;
}

/* When --warn-hash-mismatch is given, a hash mismatch is reported as a warning
 * (printing the actual hash so the buildfile can be updated) instead of aborting. */
static bool warn_hash_mismatch = false;

/* When --verify/--check is given, verify all pinned hashes + up-to-dateness
 * without running recipes (CI pre-flight). */
static bool want_verify = false;

/* Human-readable name of a hash algorithm, for building "<algo>:<hex>" specs. */
static const char *hash_algo_name(HashAlg alg) {
    switch (alg) {
    case HASH_SHA256: return "sha256";
    }
    return "?";
}

/* Verify all dep hashes for a target. Dies on mismatch (unless --warn-hash-mismatch).
 * Missing file is always fatal. */
static int verify_dep_hashes(Target *t) {
    for (int i = 0; i < t->ndep_hash; i++) {
        char got[65];
        if (!file_hash(&t->dep_hash[i].hash, t->dep_hash[i].path, got))
            die("target '%s': dep hash verification failed: file '%s' not found",
                t->name, t->dep_hash[i].path);
        if (strcmp(got, t->dep_hash[i].hash.hex)) {
            if (warn_hash_mismatch) {
                fprintf(stderr, "dhake: warning: target '%s': dep hash mismatch for '%s': "
                        "expected %s, got %s:%s\n",
                        t->name, t->dep_hash[i].path, t->dep_hash[i].hash.spec,
                        hash_algo_name(t->dep_hash[i].hash.alg), got);
            } else {
                die("target '%s': dep hash mismatch for '%s': expected %s, got %s",
                    t->name, t->dep_hash[i].path, t->dep_hash[i].hash.spec, got);
            }
        }
    }
    return 0;
}

/* Verify output hash for a target. Dies on mismatch (unless --warn-hash-mismatch),
 * in which case it returns 1 on mismatch. Missing file is always fatal. */
static int verify_output_hash(Target *t) {
    char got[65];
    if (!file_hash(t->out_hash, t->name, got))
        die("target '%s': output hash verification failed: file '%s' not found",
            t->name, t->name);
    if (strcmp(got, t->out_hash->hex)) {
        if (warn_hash_mismatch) {
            fprintf(stderr, "dhake: warning: target '%s': output hash mismatch: "
                    "expected %s, got %s:%s\n",
                    t->name, t->out_hash->spec, hash_algo_name(t->out_hash->alg), got);
            return 1;
        }
        die("target '%s': output hash mismatch: expected %s, got %s",
            t->name, t->out_hash->spec, got);
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* Action mapping                                                      */
/* ------------------------------------------------------------------ */

/* the selected alternative of a union literal: the field carrying a value */
static Field *union_selected(Term *u) {
    if (!u || u->tag != TmUnionLit) return NULL;
    for (int i = 0; i < u->as.uni.n; i++)
        if (u->as.uni.fs[i].value) return &u->as.uni.fs[i];
    return NULL;
}

/* Resolve a Mkdir/Rm payload, which may be:
 *   - a bare Text literal           -> non-recursive (legacy)
 *   - a record { path, <flag> }     -> recursive per <flag>
 *   - a nested single-alt union of the two (the type-honest Dhall spelling
 *     < Plain : Text | <Flag> : { path, <flag> } >)
 * Returns a strdup'd path and sets *recursive. Dies on malformed input. */
static char *action_path(Term *v, const char *flag, bool *recursive, const char *target) {
    *recursive = false;
    if (!v) die("target '%s': Mkdir/Rm payload missing", target);
    if (v->tag == TmUnionLit) {            /* nested < Plain | Flag > payload */
        Field *f = union_selected(v);
        if (!f) die("target '%s': malformed Mkdir/Rm payload", target);
        v = f->value;
    }
    if (v->tag == TmText) return term_text_cstr(v);
    if (v->tag == TmRecordLit) {
        char *p = rec_need_text(v, "path", target);
        *recursive = rec_bool(v, flag, false, target);
        return p;
    }
    die("target '%s': Mkdir/Rm payload must be Text or a { path, %s } record", target, flag);
    return NULL;
}

static Action *map_action(Term *u, const char *target) {
    if (!u || u->tag != TmUnionLit)
        die("target '%s': recipe element must be an Action union (< Tag = v >)", target);
    Field *sel = union_selected(u);
    if (!sel) die("target '%s': malformed Action union", target);
    Action *a = calloc(1, sizeof *a);
    if (!a) die("out of memory");
    const char *tag = sel->label;
    if (!strcmp(tag, "Shell")) {
        a->kind = ACT_SHELL;
        a->a = term_text_cstr(sel->value);
        if (!a->a) die("target '%s': < Shell = ... > value must be Text", target);
    } else if (!strcmp(tag, "Copy")) {
        a->kind = ACT_COPY;
        if (sel->value->tag != TmRecordLit) die("target '%s': Copy must be a { from, to } record", target);
        a->a = rec_need_text(sel->value, "from", target);
        a->b = rec_need_text(sel->value, "to", target);
    } else if (!strcmp(tag, "Mkdir")) {
        a->kind = ACT_MKDIR;
        a->a = action_path(sel->value, "parents", &a->recursive, target);
        if (!a->a) die("target '%s': < Mkdir = ... > value must be Text or a { path, parents } record", target);
    } else if (!strcmp(tag, "Rm")) {
        a->kind = ACT_RM;
        a->a = action_path(sel->value, "recursive", &a->recursive, target);
        if (!a->a) die("target '%s': < Rm = ... > value must be Text or a { path, recursive } record", target);
    } else if (!strcmp(tag, "Touch")) {
        a->kind = ACT_TOUCH;
        a->a = term_text_cstr(sel->value);
        if (!a->a) die("target '%s': < Touch = ... > value must be Text", target);
    } else if (!strcmp(tag, "Move")) {
        a->kind = ACT_MOVE;
        if (sel->value->tag != TmRecordLit) die("target '%s': Move must be a { from, to } record", target);
        a->a = rec_need_text(sel->value, "from", target);
        a->b = rec_need_text(sel->value, "to", target);
    } else if (!strcmp(tag, "Symlink")) {
        a->kind = ACT_SYMLINK;
        if (sel->value->tag != TmRecordLit) die("target '%s': Symlink must be a { from, to } record", target);
        a->a = rec_need_text(sel->value, "from", target);
        a->b = rec_need_text(sel->value, "to", target);
    } else if (!strcmp(tag, "Chmod")) {
        a->kind = ACT_CHMOD;
        if (sel->value->tag != TmRecordLit) die("target '%s': Chmod must be a { path, mode } record", target);
        a->a = rec_need_text(sel->value, "path", target);
        a->b = rec_need_text(sel->value, "mode", target);
    } else if (!strcmp(tag, "Echo")) {
        a->kind = ACT_ECHO;
        a->a = term_text_cstr(sel->value);
        if (!a->a) die("target '%s': < Echo = ... > value must be Text", target);
    } else if (!strcmp(tag, "Env")) {
        a->kind = ACT_ENV;
        if (sel->value->tag != TmRecordLit) die("target '%s': Env must be a { key, value } record", target);
        a->a = rec_need_text(sel->value, "key", target);
        a->b = rec_need_text(sel->value, "value", target);
    } else if (!strcmp(tag, "Run")) {
        a->kind = ACT_RUN;
        if (sel->value->tag != TmRecordLit) die("target '%s': Run must be a { argv : List Text } record", target);
        Term *argv_list = rec_get(sel->value, "argv");
        if (!argv_list) die("target '%s': Run must have an 'argv' field", target);
        int n = list_length(argv_list);
        if (n == 0) die("target '%s': Run argv must be non-empty", target);
        a->av = calloc((size_t)(n + 1), sizeof(char *));
        if (!a->av) die("out of memory");
        a->nav = n;
        int i = 0;
        for (Term *p = argv_list; p && p->tag == TmCons; p = p->as.cons.tail) {
            a->av[i++] = term_text_cstr(p->as.cons.head);
            if (!a->av[i-1]) die("target '%s': Run argv elements must be Text", target);
        }
        a->av[n] = NULL;
        a->a = a->av[0];  /* store program name in a for compatibility */
    } else {
        die("target '%s': unknown action '< %s = ... >'", target, tag);
    }
    return a;
}

/* map one { mapKey, mapValue } record into a Target */
static Target *map_target(Term *mapValue, const char *name) {
    if (!mapValue || mapValue->tag != TmRecordLit)
        die("target '%s': mapValue must be a record { deps, phony, recipe }", name);
    Target *t = calloc(1, sizeof *t);
    if (!t) die("out of memory");
    t->name = (char *)name;

    Term *deps = rec_get(mapValue, "deps");
    if (deps) {
        if (deps->tag != TmNil && deps->tag != TmCons)
            die("target '%s': 'deps' must be a List Text", name);
        t->ndeps = list_length(deps);
        t->deps = calloc((size_t)(t->ndeps ? t->ndeps : 1), sizeof(char *));
        int i = 0;
        for (Term *p = deps; p && p->tag == TmCons; p = p->as.cons.tail) {
            char *d = term_text_cstr(p->as.cons.head);
            if (!d) die("target '%s': dependency name must be Text", name);
            t->deps[i++] = d;
        }
    }
    t->phony = rec_bool(mapValue, "phony", false, name);
    t->unveil = parse_unveil_list(mapValue, name, &t->nunveil);

    /* verified builds: optional hash and depsHash */
    Term *hash_term = rec_get(mapValue, "hash");
    if (hash_term) {
        if (hash_term->tag != TmText)
            die("target '%s': 'hash' must be Text", name);
        char *hash_spec = term_text_cstr(hash_term);
        t->out_hash = malloc(sizeof(Hash));
        if (!t->out_hash) die("out of memory");
        *t->out_hash = parse_hash(hash_spec, name);
    }
    t->dep_hash = parse_dep_hash_list(mapValue, name, &t->ndep_hash);

    Term *recipe = rec_get(mapValue, "recipe");
    if (recipe && recipe->tag != TmNil) {
        if (recipe->tag != TmCons) die("target '%s': 'recipe' must be a List Action", name);
        Action **tail = &t->recipe;
        for (Term *p = recipe; p->tag == TmCons; p = p->as.cons.tail) {
            Action *a = map_action(p->as.cons.head, name);
            *tail = a;
            tail = &a->next;
        }
    }
    return t;
}

/* map the top-level normalized record { targets, default } into a Build */
static Build *build_plan(Term *root) {
    if (!root || root->tag != TmRecordLit)
        die("buildfile must evaluate to a record { targets, default }");
    Build *b = calloc(1, sizeof *b);
    if (!b) die("out of memory");

    Term *default_t = rec_get(root, "default");
    if (default_t) b->default_name = term_text_cstr(default_t);

    /* optional sandbox config: { enable : Bool, readExec : Bool, denyNetwork : Bool, unveil : List Text } */
    Term *sb = rec_get(root, "sandbox");
    if (sb) {
        if (sb->tag != TmRecordLit) die("buildfile: 'sandbox' must be a record { enable, readExec, denyNetwork, unveil }");
        b->sandbox_enabled = rec_bool(sb, "enable", false, "buildfile");
        b->sandbox_read_exec = rec_bool(sb, "readExec", false, "buildfile");
        b->sandbox_deny_network = rec_bool(sb, "denyNetwork", false, "buildfile");
        b->unveil = parse_unveil_list(sb, "buildfile", &b->nunveil);
        if (b->sandbox_deny_network && !b->sandbox_enabled)
            fprintf(stderr, "dhake: warning: sandbox.denyNetwork=True but sandbox.enable=False; network containment will NOT be applied\n");
    }

    Term *targets = rec_get(root, "targets");
    if (!targets) die("buildfile: missing 'targets' field");
    if (targets->tag != TmNil && targets->tag != TmCons)
        die("buildfile: 'targets' must be a List of { mapKey, mapValue }");

    Target **tail = &b->targets;
    for (Term *p = targets; p && p->tag == TmCons; p = p->as.cons.tail) {
        Term *item = p->as.cons.head;
        if (!item || item->tag != TmRecordLit)
            die("buildfile: each 'targets' element must be { mapKey, mapValue }");
        char *key = rec_need_text(item, "mapKey", "buildfile");
        if (find_target(b, key)) die("buildfile: duplicate target name '%s'", key);
        Term *mv = rec_get(item, "mapValue");
        if (!mv) die("buildfile: target '%s' missing 'mapValue'", key);
        Target *t = map_target(mv, key);
        *tail = t;
        tail = &t->next;
        b->ntargets++;
    }
    return b;
}

/* ------------------------------------------------------------------ */
/* Evaluation: parse -> normalize                                      */
/* ------------------------------------------------------------------ */

static Term *eval_buildfile(const char *path) {
    size_t len = 0;
    char *src = read_file(path, &len);
    if (!src) die("cannot open buildfile '%s'", path);

    if (!dhall_arena) dhall_arena = arena_new();
    arena_reset(dhall_arena);

    ImportLoader *loader = import_loader_new();
    import_loader_push_root(loader, path);

    Parser p;
    memset(&p, 0, sizeof p);
    p.loader = loader;
    DhallError err;
    dhall_error_clear(&err);

    Term *t = parse_source(&p, src, path, &err);
    free(src);
    if (!t) { print_dhall_error(&err); import_loader_free(loader); exit(dhall_error_exit(&err)); }

    normalize_clear_error();
    Term *nf = normalize(t);
    if (normalize_has_error()) {
        err = *normalize_get_error();
        print_dhall_error(&err);
        import_loader_free(loader);
        exit(dhall_error_exit(&err));
    }
    import_loader_free(loader);
    return nf;   /* arena-owned; valid until next arena_reset */
}

/* ------------------------------------------------------------------ */
/* Dependency graph: resolve, topo-sort, cycle detection               */
/* ------------------------------------------------------------------ */

static Target *find_target(Build *b, const char *name) {
    for (Target *t = b->targets; t; t = t->next)
        if (!strcmp(t->name, name)) return t;
    return NULL;
}

/* Resolve each dep name to a Target* (NULL => a plain source file, not a
 * build target).  A missing source file is reported lazily during the build. */
static void resolve_deps(Build *b) {
    for (Target *t = b->targets; t; t = t->next) {
        t->dep_targets = calloc((size_t)(t->ndeps ? t->ndeps : 1), sizeof(Target *));
        for (int i = 0; i < t->ndeps; i++)
            t->dep_targets[i] = find_target(b, t->deps[i]);   /* NULL = source file */
    }
}

/* iterative DFS emitting a topo order (deps before dependents); detects cycles */
static void topo_order(Build *b, Target ***order_out, int *n_out) {
    int cap = b->ntargets ? b->ntargets : 1;
    Target **order = malloc((size_t)cap * sizeof(Target *));
    int n = 0;

    for (Target *root = b->targets; root; root = root->next) {
        if (root->state != 0) continue;
        /* explicit stack of (node, next-dep-index) frames */
        typedef struct { Target *t; int i; } Frame;
        Frame *stk = malloc((size_t)cap * sizeof(Frame));
        int top = 0;
        stk[top++] = (Frame){ root, 0 };
        root->state = 1;
        while (top > 0) {
            Frame *f = &stk[top - 1];
            if (f->i < f->t->ndeps) {
                Target *d = f->t->dep_targets[f->i++];
                if (!d) continue;                 /* source-file dep: not a graph node */
                if (d->state == 1) die("dependency cycle detected involving target '%s'", d->name);
                if (d->state == 0) { d->state = 1; stk[top++] = (Frame){ d, 0 }; }
            } else {
                f->t->state = 2;
                order[n++] = f->t;
                top--;
            }
        }
        free(stk);
    }
    *order_out = order;
    *n_out = n;
}

/* ------------------------------------------------------------------ */
/* Up-to-date / mtime check                                            */
/* ------------------------------------------------------------------ */

static long long file_mtime_ns(const char *path, bool *exists) {
    struct stat st;
    if (stat(path, &st) != 0) { if (exists) *exists = false; return 0; }
    if (exists) *exists = true;
    long long ns = (long long)st.st_mtime * 1000000000LL;
#if defined(__linux__)
    ns += st.st_mtim.tv_nsec;
#endif
    return ns;
}

/* ------------------------------------------------------------------ */
/* Recipe executor                                                     */
/* ------------------------------------------------------------------ */

static bool copy_file(const char *from, const char *to) {
    FILE *in = fopen(from, "rb");
    if (!in) { fprintf(stderr, "dhake: copy: cannot open '%s'\n", from); return false; }
    FILE *out = fopen(to, "wb");
    if (!out) { fprintf(stderr, "dhake: copy: cannot open '%s'\n", to); fclose(in); return false; }
    char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, in)) > 0)
        if (fwrite(buf, 1, n, out) != n) { fprintf(stderr, "dhake: copy: write error to '%s'\n", to); fclose(in); fclose(out); return false; }
    fclose(in);
    fclose(out);
    return true;
}

static bool touch_file(const char *path) {
    int fd = open(path, O_WRONLY | O_CREAT, 0644);
    if (fd < 0) { fprintf(stderr, "dhake: touch: cannot open '%s'\n", path); return false; }
    close(fd);
    struct timeval tv[2];
    gettimeofday(&tv[0], NULL);
    tv[1] = tv[0];
    utimes(path, tv);
    return true;
}

/* ------------------------------------------------------------------ */
/* Landlock sandboxing (write-containment + optional read/execute)      */
/*                                                                     */
/* Each recipe child applies a Landlock ruleset. By default (v1) it   */
/* handles ONLY the WRITE-class rights. When sandbox.readExec=True,   */
/* READ_FILE, READ_DIR, and EXECUTE are also handled, and the standard  */
/* toolchain directories are auto-unveiled so builds can still compile */
/* and run programs. A rogue recipe can only read/exec under unveiled  */
/* directories. When readExec=False, READ/EXECUTE are left unhandled so */
/* exec() of any tool keeps working without unveiling every exec path. */
/* ------------------------------------------------------------------ */

static bool landlock_warned = false;

static int landlock_write_handled(int abi) {
    unsigned long h = LANDLOCK_ACCESS_FS_WRITE_FILE
                    | LANDLOCK_ACCESS_FS_REMOVE_DIR
                    | LANDLOCK_ACCESS_FS_REMOVE_FILE
                    | LANDLOCK_ACCESS_FS_MAKE_CHAR
                    | LANDLOCK_ACCESS_FS_MAKE_DIR
                    | LANDLOCK_ACCESS_FS_MAKE_REG
                    | LANDLOCK_ACCESS_FS_MAKE_SOCK
                    | LANDLOCK_ACCESS_FS_MAKE_FIFO
                    | LANDLOCK_ACCESS_FS_MAKE_BLOCK
                    | LANDLOCK_ACCESS_FS_MAKE_SYM;
    if (abi >= 2) h |= LANDLOCK_ACCESS_FS_REFER;
    if (abi >= 3) h |= LANDLOCK_ACCESS_FS_TRUNCATE;
    return (int)h;
}

/* Return the full handled access mask based on sandbox_read_exec flag. */
static int landlock_handled_mask(Build *b) {
    unsigned long h = landlock_write_handled(b->landlock_abi);
    if (b->sandbox_read_exec) {
        h |= LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR | LANDLOCK_ACCESS_FS_EXECUTE;
    }
    return (int)h;
}

/* Map a perms string ({r,w,c,x}) to landlock rights. `w` -> WRITE_FILE
 * (+REFER/TRUNCATE per ABI); `c` -> make/remove rights; `r` -> READ_FILE|READ_DIR;
 * `x` -> EXECUTE.
 *
 * `read_exec` must be TRUE for the r/x mappings to be emitted. This is required
 * for correctness, NOT just documentation: when read/execute are not handled
 * (readExec=False, the write-containment default), the kernel REJECTS a rule
 * whose allowed_access includes rights absent from the ruleset's
 * handled_access_fs mask (landlock_add_rule returns EINVAL). So in write-only
 * mode, r/x must map to zero to keep the cwd/tmp auto-unveil rules valid and
 * preserve the exact previous behavior. */
static unsigned long landlock_perms_rights(const char *perms, int abi, bool read_exec) {
    unsigned long h = 0;
    for (const char *p = perms; *p; p++) {
        if (*p == 'w') {
            h |= LANDLOCK_ACCESS_FS_WRITE_FILE;
            if (abi >= 2) h |= LANDLOCK_ACCESS_FS_REFER;
            if (abi >= 3) h |= LANDLOCK_ACCESS_FS_TRUNCATE;
        } else if (*p == 'c') {
            h |= LANDLOCK_ACCESS_FS_MAKE_CHAR | LANDLOCK_ACCESS_FS_MAKE_DIR
               | LANDLOCK_ACCESS_FS_MAKE_REG | LANDLOCK_ACCESS_FS_MAKE_SOCK
               | LANDLOCK_ACCESS_FS_MAKE_FIFO | LANDLOCK_ACCESS_FS_MAKE_BLOCK
               | LANDLOCK_ACCESS_FS_MAKE_SYM
               | LANDLOCK_ACCESS_FS_REMOVE_DIR | LANDLOCK_ACCESS_FS_REMOVE_FILE;
        } else if (*p == 'r' && read_exec) {
            h |= LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR;
        } else if (*p == 'x' && read_exec) {
            h |= LANDLOCK_ACCESS_FS_EXECUTE;
        }
    }
    return h;
}

/* Add a path-beneath rule for `path`. Non-fatal on ENOENT (path not yet
 * created) — landlock rules are on inodes, so unveil a directory that will
 * exist, or the parent of a to-be-created file. */
static void landlock_allow(int rfd, const char *path, unsigned long rights) {
    int fd = open(path, O_PATH | O_CLOEXEC);
    if (fd < 0) return;
    struct landlock_path_beneath_attr a = { .allowed_access = rights, .parent_fd = fd };
    if (landlock_add_rule(rfd, LANDLOCK_RULE_PATH_BENEATH, &a, 0) != 0)
        fprintf(stderr, "dhake: warning: landlock_add_rule('%s'): %s\n", path, strerror(errno));
    close(fd);
}

/* Split an unveil entry "perms:path" (perms default rwc). Returns the perms
 * string in `perms` and points *path_out at the path. */
static void landlock_parse_entry(const char *entry, char *perms, size_t perms_sz,
                                 const char **path_out) {
    const char *colon = strchr(entry, ':');
    if (colon && colon != entry) {
        size_t plen = (size_t)(colon - entry);
        int ok = (plen >= 1 && plen <= 4);   /* real perms tokens are short: max "rwcx" */
        for (size_t i = 0; ok && i < plen; i++)
            if (!strchr("rwcx", entry[i])) ok = 0;
        if (ok && colon[1] != '\0' && plen < perms_sz) {  /* non-empty path after ':' */
            memcpy(perms, entry, plen);
            perms[plen] = '\0';
            *path_out = colon + 1;
            return;
        }
    }
    snprintf(perms, perms_sz, "rwc");
    *path_out = entry;
}

/* Add one whitelist entry ("perms:path"), expanding a leading ~ to $HOME. */
static void landlock_allow_entry(int rfd, const char *entry, int abi, bool read_exec) {
    char perms[8];
    const char *path;
    landlock_parse_entry(entry, perms, sizeof perms, &path);
    unsigned long rights = landlock_perms_rights(perms, abi, read_exec);
    if (rights == 0) return;          /* e.g. a pure "r:path" entry in v1 */
    char *expanded = NULL;
    if (path[0] == '~' && (path[1] == '/' || path[1] == '\0')) {
        const char *home = getenv("HOME");
        if (home && *home) {
            const char *rest = path + 1;
            if (asprintf(&expanded, "%s%s", home, rest) < 0) expanded = NULL;
            if (expanded) path = expanded;
        }
    }
    landlock_allow(rfd, path, rights);
    free(expanded);
}

/* Auto-unveil standard toolchain directories for read/execute containment.
 * Bin dirs get READ_FILE|READ_DIR|EXECUTE, lib dirs get READ_FILE|READ_DIR|EXECUTE,
 * include dirs get READ_FILE|READ_DIR. Non-existent paths are silently skipped. */
static void landlock_auto_read_exec(int rfd) {
    unsigned long r_x = LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR | LANDLOCK_ACCESS_FS_EXECUTE;
    unsigned long r   = LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR;

    /* Bin dirs (R|X) */
    landlock_allow(rfd, "/usr/bin", r_x);
    landlock_allow(rfd, "/bin", r_x);
    landlock_allow(rfd, "/usr/sbin", r_x);
    landlock_allow(rfd, "/sbin", r_x);
    landlock_allow(rfd, "/usr/local/bin", r_x);

    /* Lib dirs (R|X) */
    landlock_allow(rfd, "/usr/lib", r_x);
    landlock_allow(rfd, "/lib", r_x);
    landlock_allow(rfd, "/usr/lib64", r_x);
    landlock_allow(rfd, "/lib64", r_x);
    landlock_allow(rfd, "/usr/local/lib", r_x);

    /* Include dirs (R) */
    landlock_allow(rfd, "/usr/include", r);
    landlock_allow(rfd, "/usr/local/include", r);
}

/* Apply the sandbox to the CURRENT process (called in the recipe child right
 * after fork). Landlock restricts this thread + its future children, so
 * builtin actions, system()'s /bin/sh, and ACT_RUN's exec child are all
 * covered.
 *
 * Fail-open vs fail-closed: in write-containment mode (readExec=False) a
 * landlock failure is non-fatal — the recipe runs unsandboxed with a single
 * warning, so buildfiles keep working on kernels/CI that block landlock. But
 * when readExec=True the user has EXPLICITLY opted into read/execute
 * containment; running unsandboxed would silently defeat that guarantee, so
 * we fail CLOSED: abort the recipe child with a clear error. */

/* seccomp BPF filter to deny network socket creation.
 * Denies socket() for AF_INET/AF_INET6/AF_PACKET/AF_NETLINK (EPERM),
 * allows AF_UNIX/AF_LOCAL and everything else.
 * Returns 0 on success, -1 on failure. */
static int seccomp_deny_network(void) {
    /* Test hook: force the fail-closed path (simulate seccomp being
     * unavailable) so tests can deterministically exercise the _exit(3)
     * branch regardless of host seccomp support. */
    if (getenv("DHAKE_FORCE_NO_SECCOMP")) return -1;

    /* Runtime arch gate: only x86_64 and aarch64 are supported */
    const char *platform = (const char *)getauxval(AT_PLATFORM);
    if (!platform || (strcmp(platform, "x86_64") != 0 && strcmp(platform, "aarch64") != 0)) {
        return -1;
    }

    /* 13-instruction BPF filter: denies socket() for AF_INET/AF_INET6/AF_PACKET/AF_NETLINK
     * (returns EPERM), allows AF_UNIX/AF_LOCAL and all other syscalls.
     *
     * Classic-BPF jump offsets are relative to the NEXT instruction:
     * true  -> pc += jt ; false -> pc += jf.  Layout (0-12):
     * 0:  LD arch
     * 1:  JEQ x86_64   jt=2 jf=0   x86 -> 4 ; else -> 2
     * 2:  JEQ aarch64  jt=1 jf=0   arm -> 4 ; else -> 3
     * 3:  RET KILL (unrecognized arch)
     * 4:  LD syscall nr
     * 5:  JEQ __NR_socket jt=0 jf=5  socket -> 6 ; else -> 11 (ALLOW)
     * 6:  LD args[0] (domain)
     * 7:  JEQ AF_INET   jt=4 jf=0   -> 12 (deny) ; else -> 8
     * 8:  JEQ AF_INET6  jt=3 jf=0   -> 12 (deny) ; else -> 9
     * 9:  JEQ AF_PACKET jt=2 jf=0   -> 12 (deny) ; else -> 10
     * 10: JEQ AF_NETLINK jt=1 jf=0  -> 12 (deny) ; else -> 11
     * 11: RET ALLOW (AF_UNIX/AF_LOCAL and other domains)
     * 12: RET ERRNO|EPERM (denied network domains)
     */
    struct sock_filter filter[] = {
        /* Load architecture */
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
        /* x86_64: if equal, skip past aarch64 check + kill to LD nr (instr 4) */
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_X86_64, 2, 0),
        /* aarch64: if equal, skip past kill to LD nr (instr 4) */
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_AARCH64, 1, 0),
        /* Kill other architectures */
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL),
        /* Load syscall number */
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        /* If not socket, skip to ALLOW (instr 11); if socket, fall through to domain check */
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_socket, 0, 5),
        /* Load first arg (domain) */
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[0])),
        /* Check AF_INET: if equal, skip to deny (instr 12); else go to next */
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AF_INET, 4, 0),
        /* Check AF_INET6: if equal, skip to deny (instr 12); else go to next */
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AF_INET6, 3, 0),
        /* Check AF_PACKET: if equal, skip to deny (instr 12); else go to next */
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AF_PACKET, 2, 0),
        /* Check AF_NETLINK: if equal, skip to deny (instr 12); else go to next (allow) */
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AF_NETLINK, 1, 0),
        /* Allow AF_UNIX/AF_LOCAL and any other domain */
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
        /* Deny network socket domains */
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA)),
    };
    struct sock_fprog prog = {
        .len = (unsigned short)(sizeof filter / sizeof filter[0]),
        .filter = filter,
    };

    /* Set NO_NEW_PRIVS (idempotent; may already be set by landlock) */
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) return -1;

    /* Install the seccomp filter */
    if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog) != 0) return -1;

    return 0;
}

static void sandbox_fail(Build *b, const char *why) {
    fprintf(stderr, "dhake: %s: landlock sandbox unavailable (requested): %s\n",
            b->sandbox_read_exec ? "error" : "warning", why);
    if (b->sandbox_read_exec) {
        fprintf(stderr, "dhake: readExec=True requested read/execute containment but landlock could not be established; aborting to avoid running unsandboxed\n");
        _exit(3);
    }
    if (!landlock_warned) landlock_warned = true;
}

static void sandbox_child(Build *b, Target *t) {
    if (!b->sandbox_enabled) return;
    if (b->sandbox_deny_network && seccomp_deny_network() != 0) {
        fprintf(stderr, "dhake: error: denyNetwork=True requested network containment but seccomp could not be established; aborting to avoid running unsandboxed\n");
        _exit(3);
    }
    if (b->landlock_abi < 1) { sandbox_fail(b, "landlock unsupported by kernel"); return; }

    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) { sandbox_fail(b, strerror(errno)); return; }

    struct landlock_ruleset_attr attr = { .handled_access_fs = landlock_handled_mask(b) };
    int rfd = landlock_create_ruleset(&attr, sizeof attr, 0);
    if (rfd < 0) { sandbox_fail(b, strerror(errno)); return; }

    /* auto-unveil: build dir + /tmp + $TMPDIR + device nulls */
    /* Use rwcx for cwd and /tmp so outputs and node_modules can be executed.
     * When readExec is off, r/x map to zero (not handled), so this reduces to
     * the previous write-containment rwc behavior. */
    unsigned long rwcx = landlock_perms_rights("rwcx", b->landlock_abi, b->sandbox_read_exec);
    landlock_allow(rfd, ".", rwcx);
    landlock_allow(rfd, "/tmp", rwcx);
    const char *td = getenv("TMPDIR");
    if (td && *td && strcmp(td, "/tmp")) landlock_allow(rfd, td, rwcx);
    landlock_allow(rfd, "/dev/null", LANDLOCK_ACCESS_FS_WRITE_FILE | (b->sandbox_read_exec ? LANDLOCK_ACCESS_FS_READ_FILE : 0));
    landlock_allow(rfd, "/dev/zero", LANDLOCK_ACCESS_FS_WRITE_FILE | (b->sandbox_read_exec ? LANDLOCK_ACCESS_FS_READ_FILE : 0));
    landlock_allow(rfd, "/dev/full", LANDLOCK_ACCESS_FS_WRITE_FILE | (b->sandbox_read_exec ? LANDLOCK_ACCESS_FS_READ_FILE : 0));
    landlock_allow(rfd, "/dev/tty", LANDLOCK_ACCESS_FS_WRITE_FILE | (b->sandbox_read_exec ? LANDLOCK_ACCESS_FS_READ_FILE : 0));

    /* Auto-unveil toolchain dirs when readExec is enabled */
    if (b->sandbox_read_exec) {
        landlock_auto_read_exec(rfd);
    }

    /* global then per-target whitelist */
    for (int i = 0; i < b->nunveil; i++) landlock_allow_entry(rfd, b->unveil[i], b->landlock_abi, b->sandbox_read_exec);
    if (t) for (int i = 0; i < t->nunveil; i++) landlock_allow_entry(rfd, t->unveil[i], b->landlock_abi, b->sandbox_read_exec);

    if (landlock_restrict_self(rfd, 0) != 0) { sandbox_fail(b, strerror(errno)); close(rfd); return; }
    close(rfd);
}

/* mkdir -p: create leading parent directories, ignoring EEXIST. */
static int mkdir_p(const char *path) {
    char *buf = strdup(path);
    if (!buf) return -1;
    char *p = buf + (buf[0] == '/' ? 1 : 0);
    for (; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(buf, 0755) != 0 && errno != EEXIST) { free(buf); return -1; }
            *p = '/';
        }
    }
    if (mkdir(buf, 0755) != 0 && errno != EEXIST) { free(buf); return -1; }
    free(buf);
    return 0;
}

static int rm_rf_cb(const char *path, const struct stat *st, int typeflag, struct FTW *ftw) {
    (void)st; (void)typeflag; (void)ftw;
    return remove(path);
}

/* rm -rf: recursively delete, ignoring missing paths. */
static int rm_rf(const char *path) {
    if (nftw(path, rm_rf_cb, 64, FTW_DEPTH | FTW_PHYS) != 0)
        return (errno == ENOENT) ? 0 : -1;
    return 0;
}

/* Run a recipe shell command with the platform's real /bin/sh, NOT system().
 *
 * We deliberately avoid system(): cosmopolitan's embedded command interpreter
 * (_cocmd, reached by system()) applies a '>' redirection by permanently
 * reassigning fd 1 of the shell process, and ';'-chained commands run in that
 * same process. So a recipe like `echo start; echo x > f; echo after; echo
 * end` sends ALL of "start", "x", "after", "end" to the redirect target — only
 * "start" ever reaches stdout. fork+execvp("/bin/sh","-c",cmd) hands the
 * command to the real POSIX shell, which scopes each redirection to a single
 * command, so redirects, $?, pipelines, etc. behave correctly.
 *
 * NOTE (parked): the proper fix is to patch cosmopolitan's cocmd.c to scope
 * redirects to a single command and rebuild the libc/toolchain (forked at
 * fixpoint-linux/cosmopolitan). Until that ships, this exec-shell is the
 * workaround. The recipe child has already applied the landlock ruleset, and
 * exec is not restricted by it, so /bin/sh and the commands it spawns still
 * run. Returns exit code (0 = ok). */
static int run_shell(const char *cmd) {
    pid_t pid = fork();
    if (pid == -1) {
        fprintf(stderr, "dhake: failed to fork shell for '%s': %s\n", cmd, strerror(errno));
        return 2;
    }
    if (pid == 0) {
        /* child */
        execl("/bin/sh", "sh", "-c", cmd, (char *)0);
        fprintf(stderr, "dhake: exec '/bin/sh' for '%s' failed: %s\n", cmd, strerror(errno));
        _exit(127);
    }
    /* parent */
    int status;
    if (waitpid(pid, &status, 0) == -1) {
        fprintf(stderr, "dhake: waitpid for '%s': %s\n", cmd, strerror(errno));
        return 2;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 2;                            /* signaled */
}

/* execute one action; returns exit code (0 = ok) */
static int run_action(Action *a) {
    switch (a->kind) {
    case ACT_SHELL: {
        printf("%s\n", a->a);           /* echo, like make */
        fflush(stdout);
        return run_shell(a->a);
    }
    case ACT_COPY:
        printf("cp %s %s\n", a->a, a->b);
        fflush(stdout);
        return copy_file(a->a, a->b) ? 0 : 1;
    case ACT_MKDIR: {
        printf(a->recursive ? "mkdir -p %s\n" : "mkdir %s\n", a->a);
        fflush(stdout);
        if ((a->recursive ? mkdir_p(a->a) : mkdir(a->a, 0755)) != 0 && errno != EEXIST) {
            fprintf(stderr, "dhake: mkdir: %s\n", strerror(errno));
            return 1;
        }
        return 0;
    }
    case ACT_RM:
        printf(a->recursive ? "rm -rf %s\n" : "rm %s\n", a->a);
        fflush(stdout);
        if ((a->recursive ? rm_rf(a->a) : remove(a->a)) != 0 && errno != ENOENT) {
            fprintf(stderr, "dhake: rm: %s\n", strerror(errno));
            return 1;
        }
        return 0;
    case ACT_TOUCH:
        printf("touch %s\n", a->a);
        fflush(stdout);
        return touch_file(a->a) ? 0 : 1;
    case ACT_MOVE: {
        printf("mv %s %s\n", a->a, a->b);
        fflush(stdout);
        if (rename(a->a, a->b) != 0) {
            fprintf(stderr, "dhake: move: %s\n", strerror(errno));
            return 1;
        }
        return 0;
    }
    case ACT_SYMLINK: {
        printf("ln -s %s %s\n", a->a, a->b);
        fflush(stdout);
        if (symlink(a->a, a->b) != 0) {
            fprintf(stderr, "dhake: symlink: %s\n", strerror(errno));
            return 1;
        }
        return 0;
    }
    case ACT_CHMOD: {
        printf("chmod %s %s\n", a->b, a->a);
        fflush(stdout);
        char *end = NULL;
        errno = 0;
        long mode = strtol(a->b, &end, 8);
        if (errno != 0 || end == a->b || *end != '\0' || mode < 0 || mode > 07777) {
            fprintf(stderr, "dhake: chmod: invalid mode '%s' (expected octal 0..7777)\n", a->b);
            return 1;
        }
        if (chmod(a->a, (mode_t)mode) != 0) {
            fprintf(stderr, "dhake: chmod: %s\n", strerror(errno));
            return 1;
        }
        return 0;
    }
    case ACT_ECHO: {
        printf("%s\n", a->a);
        fflush(stdout);
        return 0;
    }
    case ACT_ENV: {
        printf("export %s=%s\n", a->a, a->b);
        fflush(stdout);
        setenv(a->a, a->b, 1);
        return 0;
    }
    case ACT_RUN: {
        printf("%s", a->av[0]);
        for (int i = 1; i < a->nav; i++) printf(" %s", a->av[i]);
        printf("\n");
        fflush(stdout);
        pid_t pid = fork();
        if (pid == -1) {
            fprintf(stderr, "dhake: fork failed for Run: %s\n", strerror(errno));
            return 2;
        }
        if (pid == 0) {
            /* child */
            execvp(a->av[0], a->av);
            fprintf(stderr, "dhake: execvp '%s' failed: %s\n", a->av[0], strerror(errno));
            _exit(2);
        }
        /* parent */
        int status;
        waitpid(pid, &status, 0);
        if (WIFEXITED(status)) return WEXITSTATUS(status);
        return 2; /* signaled */
    }
    }
    return 2;
}

/* dry-run: print actions without executing */
static void print_action(Action *a) {
    switch (a->kind) {
    case ACT_SHELL: printf("%s\n", a->a); break;
    case ACT_COPY:  printf("cp %s %s\n", a->a, a->b); break;
    case ACT_MKDIR: printf(a->recursive ? "mkdir -p %s\n" : "mkdir %s\n", a->a); break;
    case ACT_RM:    printf(a->recursive ? "rm -rf %s\n" : "rm %s\n", a->a); break;
    case ACT_TOUCH: printf("touch %s\n", a->a); break;
    case ACT_MOVE:  printf("mv %s %s\n", a->a, a->b); break;
    case ACT_SYMLINK: printf("ln -s %s %s\n", a->a, a->b); break;
    case ACT_CHMOD: printf("chmod %s %s\n", a->b, a->a); break;
    case ACT_ECHO:  printf("echo %s\n", a->a); break;
    case ACT_ENV:   printf("export %s=%s\n", a->a, a->b); break;
    case ACT_RUN: {
        printf("%s", a->av[0]);
        for (int i = 1; i < a->nav; i++) printf(" %s", a->av[i]);
        printf("\n");
        break;
    }
    }
}

/* ------------------------------------------------------------------ */
/* CLI                                                                 */
/* ------------------------------------------------------------------ */

/* pick the default buildfile: Dhakefile.dhall, else build.dhall.  Returns
   a pointer into argv/passed arg or a static string (never freed). */
static const char *default_buildfile(void) {
    FILE *f = fopen("Dhakefile.dhall", "rb");
    if (f) { fclose(f); return "Dhakefile.dhall"; }
    return "build.dhall";
}

/* ------------------------------------------------------------------ */
/* Lockfile / SBOM support                                               */
/* ------------------------------------------------------------------ */

/* Path for --lock[=FILE] option (NULL = not requested) */
static const char *lock_path = NULL;

/* JSON string escaping: write escaped version of s to f. */
static void json_escape_str(FILE *f, const char *s) {
    if (!s) { fputs("null", f); return; }
    fputc('"', f);
    for (const char *p = s; *p; p++) {
        switch (*p) {
            case '"':  fprintf(f, "\\\""); break;
            case '\\': fprintf(f, "\\\\"); break;
            case '\b': fprintf(f, "\\b");  break;
            case '\f': fprintf(f, "\\f");  break;
            case '\n': fprintf(f, "\\n");  break;
            case '\r': fprintf(f, "\\r");  break;
            case '\t': fprintf(f, "\\t");  break;
            default:
                if (*p >= 0 && *p < 32) {
                    fprintf(f, "\\u%04x", (unsigned char)*p);
                } else {
                    fputc(*p, f);
                }
                break;
        }
    }
    fputc('"', f);
}

/* Collect transitive dependencies via iterative DFS over dep_targets.
 * Returns a NULL-terminated array of unique target names (malloc'd).
 * Excludes the starting target itself. Caller must free the array. */
static char **collect_transitive_deps(Build *b, Target *t, int *n_out) {
    /* Count total targets for sizing */
    int total = b->ntargets;
    
    /* Use a simple pointer-based visited set (target pointers are unique) */
    bool *visited = calloc((size_t)total, sizeof(bool));
    if (!visited) die("out of memory");
    
    /* Map target pointer to index */
    Target **all_targets = malloc((size_t)total * sizeof(Target *));
    if (!all_targets) { free(visited); die("out of memory"); }
    int ntargets = 0;
    for (Target *p = b->targets; p; p = p->next) {
        all_targets[ntargets++] = p;
    }
    
    /* Stack of (target, next_dep_index) */
    typedef struct { Target *t; int i; } Frame;
    Frame *stack = malloc((size_t)total * sizeof(Frame));
    if (!stack) { free(visited); free(all_targets); die("out of memory"); }
    int top = 0;
    
    /* Result array */
    char **result = malloc((size_t)total * sizeof(char *));
    if (!result) { free(visited); free(all_targets); free(stack); die("out of memory"); }
    int result_count = 0;
    
    /* Start DFS from each dep_target of t */
    for (int j = 0; j < t->ndeps; j++) {
        Target *d = t->dep_targets[j];
        if (!d) continue; /* source file, not a target */
        
        /* Find index of d */
        int idx = -1;
        for (int k = 0; k < ntargets; k++) {
            if (all_targets[k] == d) { idx = k; break; }
        }
        if (idx < 0) continue;
        
        if (!visited[idx]) {
            visited[idx] = true;
            stack[top++] = (Frame){d, 0};
        }
    }
    
    while (top > 0) {
        Frame *f = &stack[top - 1];
        if (f->i < f->t->ndeps) {
            Target *d = f->t->dep_targets[f->i++];
            if (!d) continue;
            
            /* Find index of d */
            int idx = -1;
            for (int k = 0; k < ntargets; k++) {
                if (all_targets[k] == d) { idx = k; break; }
            }
            if (idx < 0) continue;
            
            if (!visited[idx]) {
                visited[idx] = true;
                stack[top++] = (Frame){d, 0};
            }
        } else {
            /* Add to result if not the original target */
            if (f->t != t) {
                result[result_count++] = (char *)f->t->name;
            }
            top--;
        }
    }
    
    *n_out = result_count;
    free(visited);
    free(all_targets);
    free(stack);
    
    return result;
}

/* Write lockfile JSON to path. Only called on successful build (failed==0). */
static void write_lockfile(Build *b, const char *path) {
    FILE *f = fopen(path, "w");
    if (!f) { fprintf(stderr, "dhake: warning: cannot open lockfile '%s': %s\n", path, strerror(errno)); return; }
    
    /* Find default target name */
    const char *default_name = b->default_name;
    
    /* Write header */
    fprintf(f, "{\n");
    fprintf(f, "  \"format\": \"dhake.lock\",\n");
    fprintf(f, "  \"version\": 1,\n");
    fprintf(f, "  \"default\": ");
    if (default_name) {
        json_escape_str(f, default_name);
    } else {
        fputs("null", f);
    }
    fprintf(f, ",\n");
    fprintf(f, "  \"targets\": [\n");
    
    /* Write each target in buildfile order */
    bool first_target = true;
    for (Target *t = b->targets; t; t = t->next) {
        if (!first_target) fprintf(f, ",\n");
        first_target = false;
        
        fprintf(f, "    {\n");
        fprintf(f, "      \"name\": ");
        json_escape_str(f, t->name);
        fprintf(f, ",\n");
        
        fprintf(f, "      \"phony\": %s,\n", t->phony ? "true" : "false");
        
        /* deps */
        fprintf(f, "      \"deps\": [");
        for (int i = 0; i < t->ndeps; i++) {
            if (i > 0) fprintf(f, ", ");
            json_escape_str(f, t->deps[i]);
        }
        fprintf(f, "],\n");
        
        /* transitiveDeps */
        int n_trans = 0;
        char **trans_deps = collect_transitive_deps(b, t, &n_trans);
        fprintf(f, "      \"transitiveDeps\": [");
        for (int i = 0; i < n_trans; i++) {
            if (i > 0) fprintf(f, ", ");
            json_escape_str(f, trans_deps[i]);
        }
        fprintf(f, "],\n");
        free(trans_deps);
        
        /* outputHash */
        fprintf(f, "      \"outputHash\": ");
        if (t->phony) {
            fputs("null", f);
        } else {
            char actual_hash[65];
            if (file_sha256_hex(t->name, actual_hash)) {
                fprintf(f, "{\"algorithm\": \"sha256\", \"value\": \"sha256:%s\"}", actual_hash);
            } else {
                fputs("null", f);
            }
        }
        fprintf(f, ",\n");
        
        /* depHashes */
        fprintf(f, "      \"depHashes\": [");
        bool first_dep_hash = true;
        for (int i = 0; i < t->ndep_hash; i++) {
            char actual_hash[65];
            if (file_sha256_hex(t->dep_hash[i].path, actual_hash)) {
                if (!first_dep_hash) fprintf(f, ", ");
                first_dep_hash = false;
                fprintf(f, "{\"path\": ");
                json_escape_str(f, t->dep_hash[i].path);
                fprintf(f, ", \"algorithm\": \"sha256\", \"value\": \"sha256:%s\"}", actual_hash);
            }
        }
        fprintf(f, "]\n");
        
        fprintf(f, "    }");
    }
    
    fprintf(f, "\n  ]\n");
    fprintf(f, "}\n");
    
    fclose(f);
    printf("dhake: wrote lockfile %s\n", path);
}

/* Verify all pinned hashes and up-to-dateness without running recipes.
 * Returns 0 if everything is clean, nonzero if anything is dirty or mismatched. */
static int run_verify(Target **order, int n) {
    int failed = 0;
    for (int i = 0; i < n; i++) {
        Target *t = order[i];
        if (t->state != 1) continue;  /* only requested subgraph */

        /* FIRST verify all dep hashes non-fatally */
        for (int j = 0; j < t->ndep_hash; j++) {
            char got[65];
            if (!file_hash(&t->dep_hash[j].hash, t->dep_hash[j].path, got)) {
                printf("target '%s': dep hash: file '%s' not found\n", t->name, t->dep_hash[j].path);
                failed = 1;
            } else if (strcmp(got, t->dep_hash[j].hash.hex)) {
                printf("target '%s': dep hash mismatch for '%s': expected %s, got %s:%s\n",
                       t->name, t->dep_hash[j].path, t->dep_hash[j].hash.spec,
                       hash_algo_name(t->dep_hash[j].hash.alg), got);
                failed = 1;
            }
        }

        /* Handle phony targets */
        if (t->phony) {
            printf("dhake: verify: '%s' phony (always runs)\n", t->name);
            t->dirty = true;
            continue;
        }

        /* Compute dirty with the same logic as the build launch block */
        bool texists = false;
        long long tm = file_mtime_ns(t->name, &texists);
        bool dirty = !texists;
        if (!dirty) {
            for (int j = 0; j < t->ndeps; j++) {
                Target *d = t->dep_targets[j];
                if (d) {
                    if (d->dirty) { dirty = true; break; }
                    bool dexists = false;
                    long long dm = file_mtime_ns(d->name, &dexists);
                    if (!dexists) { dirty = true; break; }
                    if (dm > tm) { dirty = true; break; }
                } else {
                    bool sexists = false;
                    long long sm = file_mtime_ns(t->deps[j], &sexists);
                    if (!sexists) { dirty = true; break; }
                    if (sm > tm) { dirty = true; break; }
                }
            }
        }
        t->dirty = dirty;

        if (dirty) {
            printf("dhake: verify: '%s' needs rebuild\n", t->name);
            failed = 1;
        } else {
            /* up-to-date, non-phony: verify output hash if present */
            if (t->out_hash != NULL) {
                char got[65];
                if (!file_hash(t->out_hash, t->name, got)) {
                    printf("target '%s': output not found\n", t->name);
                    failed = 1;
                } else if (strcmp(got, t->out_hash->hex)) {
                    printf("target '%s': output hash mismatch: expected %s, got %s:%s\n",
                           t->name, t->out_hash->spec, hash_algo_name(t->out_hash->alg), got);
                    failed = 1;
                } else {
                    printf("dhake: verify: '%s' up to date\n", t->name);
                }
            } else {
                printf("dhake: verify: '%s' up to date\n", t->name);
            }
        }
    }
    return failed;
}

static void usage(const char *argv0) {
    printf("dhake — a Make-like build tool driven by a Dhall buildfile\n\n");
    printf("Usage:\n");
    printf("  %s [-f FILE] [-j N] [-n] [--list] [--warn-hash-mismatch] [--verify|--check] [--lock[=FILE]] [target ...]\n", argv0);
    printf("  %s -h | --help\n\n", argv0);
    printf("Options:\n");
    printf("  -f FILE    buildfile to evaluate (default: ./Dhakefile.dhall, else ./build.dhall)\n");
    printf("  -j N       run up to N build jobs in parallel (default: 1, sequential)\n");
    printf("  -n         dry run: print the actions that would run, without running them\n");
    printf("  --list     list all targets and exit\n");
    printf("  --warn-hash-mismatch\n");
    printf("             report verified-build hash mismatches as warnings (printing the\n");
    printf("             actual hash) instead of failing, so pinned hashes can be updated\n");
    printf("  --verify / --check\n");
    printf("             verify all pinned hashes and up-to-dateness without running recipes\n");
    printf("             (CI pre-flight); exits nonzero if anything is dirty or mismatched\n");
    printf("  --lock[=FILE]\n");
    printf("             write a lockfile (dhake.lock, or FILE if =FILE given) with\n");
    printf("             actual hashes and transitive dependencies after a successful build\n");
    printf("  target     build the named target(s); default: the buildfile's 'default'\n");
}

int main(int argc, char **argv) {
    const char *buildfile = default_buildfile();
    bool dry_run = false, want_list = false;
    int jobs = 1;  /* default: sequential */
    const char **wanted = NULL;
    int nwanted = 0, wanted_cap = 0;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(argv[0]); return 0; }
        else if (!strcmp(a, "-f")) { if (i + 1 >= argc) die("-f requires a file argument"); buildfile = argv[++i]; }
        else if (!strcmp(a, "-j")) { 
            if (i + 1 >= argc) die("-j requires a number argument"); 
            jobs = atoi(argv[++i]); 
            if (jobs < 1) die("-j must be at least 1"); 
        }
        else if (!strcmp(a, "-n") || !strcmp(a, "--dry-run")) { dry_run = true; }
        else if (!strcmp(a, "--list")) { want_list = true; }
        else if (!strcmp(a, "--warn-hash-mismatch")) { warn_hash_mismatch = true; }
        else if (!strcmp(a, "--verify") || !strcmp(a, "--check")) { want_verify = true; }
        else if (!strcmp(a, "--lock")) { lock_path = "dhake.lock"; }
        else if (!strncmp(a, "--lock=", 7)) { lock_path = a + 7; }
        else if (a[0] == '-') { die("unknown option '%s'", a); }
        else { if (nwanted == wanted_cap) { wanted_cap = wanted_cap ? wanted_cap * 2 : 4; wanted = realloc(wanted, (size_t)wanted_cap * sizeof(char *)); } wanted[nwanted++] = a; }
    }

    Term *root = eval_buildfile(buildfile);
    Build *b = build_plan(root);

    /* probe landlock ABI (only when sandboxing is requested) */
    b->landlock_abi = -1;
    if (b->sandbox_enabled) {
        b->landlock_abi = landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
        if (b->landlock_abi < 1) {
            const char *why = (b->landlock_abi < 0) ? strerror(errno) : "kernel lacks landlock support";
            if (b->sandbox_read_exec) {
                /* readExec explicitly requested read/execute containment; failing
                 * open would silently defeat it, so fail the whole build here. */
                fprintf(stderr, "dhake: error: readExec=True requested read/execute containment but landlock is unavailable (%s)\n", why);
                fprintf(stderr, "dhake: aborting to avoid running recipes unsandboxed; disable readExec or enable landlock\n");
                exit(3);
            }
            landlock_warned = true;
            fprintf(stderr, "dhake: warning: landlock sandbox unavailable (requested): %s\n", why);
        }
    }

    if (want_list) {
        for (Target *t = b->targets; t; t = t->next)
            printf("%s%s\n", t->name,
                   (b->default_name && !strcmp(t->name, b->default_name)) ? "  (default)" : "");
        return 0;
    }

    resolve_deps(b);

    Target **order; int n;
    topo_order(b, &order, &n);

    /* decide the requested target set */
    Target **roots; int nroots;
    if (nwanted > 0) {
        roots = malloc((size_t)nwanted * sizeof(Target *));
        nroots = 0;
        for (int i = 0; i < nwanted; i++) {
            Target *t = find_target(b, wanted[i]);
            if (!t) die("unknown target '%s'", wanted[i]);
            roots[nroots++] = t;
        }
    } else {
        if (!b->default_name) die("no default target (buildfile has no 'default', and no target named on argv)");
        Target *t = find_target(b, b->default_name);
        if (!t) die("default target '%s' not found in 'targets'", b->default_name);
        roots = malloc(sizeof(Target *));
        roots[0] = t;
        nroots = 1;
    }

    /* mark only the subgraph reachable from the requested roots (roots + their
     * transitive dependencies).  state 0 = not-needed, 1 = needed. */
    for (Target *t = b->targets; t; t = t->next) t->state = 0;
    {
        /* iterative DFS from roots following dep edges */
        Target **stk = malloc((size_t)(n ? n : 1) * sizeof(Target *));
        int top = 0;
        for (int i = 0; i < nroots; i++)
            if (roots[i]->state == 0) { roots[i]->state = 1; stk[top++] = roots[i]; }
        while (top > 0) {
            Target *t = stk[--top];
            for (int j = 0; j < t->ndeps; j++) {
                Target *d = t->dep_targets[j];
                if (d && d->state == 0) { d->state = 1; stk[top++] = d; }
            }
        }
        free(stk);
    }

    if (want_verify) {
        int vrc = run_verify(order, n);
        free(roots); free(order); free((void *)wanted);
        return vrc;
    }

    /* For parallel scheduling, we need to compute dirty at launch time.
     * Initialize per-target parallel state and compute deps_pending. */
    for (Target *t = b->targets; t; t = t->next) {
        t->deps_pending = 0;
        t->pid = 0;
        t->dirty = false;  /* will be computed below */
    }

    /* Compute deps_pending for each reachable target and initialize ready queue */
    for (int i = 0; i < n; i++) {
        Target *t = order[i];
        if (t->state != 1) continue;  /* not in requested subgraph */
        for (int j = 0; j < t->ndeps; j++) {
            Target *d = t->dep_targets[j];
            if (d && d->state == 1) {
                t->deps_pending++;
            }
        }
    }

    /* Ready queue: targets with deps_pending == 0 */
    Target **ready = malloc((size_t)n * sizeof(Target *));
    int ready_head = 0, ready_tail = 0;
    for (int i = 0; i < n; i++) {
        Target *t = order[i];
        if (t->state == 1 && t->deps_pending == 0) {
            ready[ready_tail++] = t;
        }
    }

    int failed = 0;
    int jobs_running = 0;

    /* If dry-run, force sequential (jobs=1) and just print */
    if (dry_run) {
        jobs = 1;
    }

    while ((ready_head < ready_tail && !failed) || jobs_running > 0) {
        /* Launch ready targets up to jobs limit */
        while (jobs_running < jobs && ready_head < ready_tail && !failed) {
            Target *t = ready[ready_head++];

            /* Compute dirty at launch time (all deps are done) */
            bool texists = false;
            long long tm = file_mtime_ns(t->name, &texists);
            bool dirty = t->phony || !texists;
            if (!dirty) {
                for (int j = 0; j < t->ndeps; j++) {
                    Target *d = t->dep_targets[j];
                    if (d) {
                        if (d->dirty) { dirty = true; break; }
                        bool dexists = false;
                        long long dm = file_mtime_ns(d->name, &dexists);
                        if (!dexists) { dirty = true; break; }
                        if (dm > tm) { dirty = true; break; }
                    } else {
                        bool sexists = false;
                        long long sm = file_mtime_ns(t->deps[j], &sexists);
                        if (!sexists) die("no rule to make target '%s', needed by '%s'", t->deps[j], t->name);
                        if (sm > tm) { dirty = true; break; }
                    }
                }
            }
            t->dirty = dirty;

            /* Verify dep hashes at launch time (integrity gate on inputs) */
            if (t->ndep_hash > 0) verify_dep_hashes(t);

            if (!dirty) {
                /* Verify output hash for up-to-date non-phony targets */
                if (t->out_hash != NULL && !t->phony) verify_output_hash(t);
                printf("dhake: '%s' is up to date\n", t->name);
                /* mark done: decrement deps_pending for dependents */
                for (int i2 = 0; i2 < n; i2++) {
                    Target *dep = order[i2];
                    if (dep->state != 1) continue;
                    for (int j = 0; j < dep->ndeps; j++) {
                        if (dep->dep_targets[j] == t) {
                            dep->deps_pending--;
                            if (dep->deps_pending == 0) {
                                ready[ready_tail++] = dep;
                            }
                        }
                    }
                }
                continue;
            }

            if (!t->recipe) {
                if (!t->phony) die("no rule to make target '%s'", t->name);
                /* phony with no recipe: mark done */
                for (int i2 = 0; i2 < n; i2++) {
                    Target *dep = order[i2];
                    if (dep->state != 1) continue;
                    for (int j = 0; j < dep->ndeps; j++) {
                        if (dep->dep_targets[j] == t) {
                            dep->deps_pending--;
                            if (dep->deps_pending == 0) {
                                ready[ready_tail++] = dep;
                            }
                        }
                    }
                }
                continue;
            }

            printf("dhake: building '%s'\n", t->name);

            if (dry_run) {
                /* dry-run: print actions sequentially, no fork */
                for (Action *a = t->recipe; a; a = a->next) {
                    print_action(a);
                }
                /* mark done */
                for (int i2 = 0; i2 < n; i2++) {
                    Target *dep = order[i2];
                    if (dep->state != 1) continue;
                    for (int j = 0; j < dep->ndeps; j++) {
                        if (dep->dep_targets[j] == t) {
                            dep->deps_pending--;
                            if (dep->deps_pending == 0) {
                                ready[ready_tail++] = dep;
                            }
                        }
                    }
                }
                continue;
            }

            /* Fork a child to run the recipe */
            pid_t pid = fork();
            if (pid == -1) {
                fprintf(stderr, "dhake: fork failed: %s\n", strerror(errno));
                failed = 2;
                break;
            }

            if (pid == 0) {
                /* Child: sandbox (landlock) then run the full recipe, then _exit */
                sandbox_child(b, t);
                int rc = 0;
                for (Action *a = t->recipe; a; a = a->next) {
                    rc = run_action(a);
                    if (rc != 0) break;
                }
                _exit(rc);
            }

            /* Parent: record pid and increment jobs_running */
            t->pid = pid;
            jobs_running++;
        }

        /* Reap completed children */
        if (jobs_running > 0) {
            int status;
            pid_t done_pid = waitpid(-1, &status, 0);
            if (done_pid == -1) {
                if (errno == EINTR) continue;
                fprintf(stderr, "dhake: waitpid failed: %s\n", strerror(errno));
                failed = 2;
                break;
            }

            jobs_running--;

            /* Find the target by pid */
            Target *completed = NULL;
            for (int i2 = 0; i2 < n; i2++) {
                Target *t2 = order[i2];
                if (t2->state == 1 && t2->pid == done_pid) {
                    completed = t2;
                    break;
                }
            }

            if (!completed) {
                fprintf(stderr, "dhake: internal error: unknown pid %ld\n", (long)done_pid);
                failed = 2;
                break;
            }

            /* Get exit code */
            int rc = 0;
            if (WIFEXITED(status)) {
                rc = WEXITSTATUS(status);
            } else {
                rc = 2;  /* signaled */
            }

            if (rc != 0 && !failed) {
                failed = rc;  /* stop scheduling new targets, but keep reaping */
            }

            /* Mark target as done: decrement deps_pending for dependents.
             * Only a SUCCESSFUL target unblocks its dependents — a failed one
             * must not schedule them (they cannot build on a broken dep). */
            if (rc == 0) {
                /* Verify output hash for successful non-phony targets */
                if (completed->out_hash != NULL && !completed->phony) {
                    if (verify_output_hash(completed) == 0)
                        printf("dhake: '%s' verified (hash %s)\n", completed->name, completed->out_hash->spec);
                }
                for (int i2 = 0; i2 < n; i2++) {
                    Target *dep = order[i2];
                    if (dep->state != 1) continue;
                    for (int j = 0; j < dep->ndeps; j++) {
                        if (dep->dep_targets[j] == completed) {
                            dep->deps_pending--;
                            if (dep->deps_pending == 0) {
                                ready[ready_tail++] = dep;
                            }
                        }
                    }
                }
            }
        }
    }

    free(ready);
    free(roots);
    free(order);
    free((void *)wanted);

    /* Write lockfile if requested, only on success, not dry-run, not --list */
    if (lock_path != NULL && !dry_run && !want_list && failed == 0) {
        write_lockfile(b, lock_path);
    }

    return failed;
}
