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
#include "dhall.h"
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>

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
    struct Action *next;
} Action;

typedef struct Target {
    char *name;
    bool phony;
    char **deps;           /* dep names as strings (buildfile order) */
    int ndeps;
    Action *recipe;        /* linked list, buildfile order */
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
        a->a = term_text_cstr(sel->value);
        if (!a->a) die("target '%s': < Mkdir = ... > value must be Text", target);
    } else if (!strcmp(tag, "Rm")) {
        a->kind = ACT_RM;
        a->a = term_text_cstr(sel->value);
        if (!a->a) die("target '%s': < Rm = ... > value must be Text", target);
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

/* execute one action; returns exit code (0 = ok) */
static int run_action(Action *a) {
    switch (a->kind) {
    case ACT_SHELL: {
        printf("%s\n", a->a);           /* echo, like make */
        fflush(stdout);
        int st = system(a->a);
        if (st == -1) { fprintf(stderr, "dhake: failed to spawn shell for '%s'\n", a->a); return 2; }
        if (WIFEXITED(st)) return WEXITSTATUS(st);
        return 2;                        /* signaled */
    }
    case ACT_COPY:
        printf("cp %s %s\n", a->a, a->b);
        fflush(stdout);
        return copy_file(a->a, a->b) ? 0 : 1;
    case ACT_MKDIR: {
        printf("mkdir %s\n", a->a);
        fflush(stdout);
        if (mkdir(a->a, 0755) != 0 && errno != EEXIST) {
            fprintf(stderr, "dhake: mkdir: %s\n", strerror(errno));
            return 1;
        }
        return 0;
    }
    case ACT_RM:
        printf("rm %s\n", a->a);
        fflush(stdout);
        if (remove(a->a) != 0 && errno != ENOENT) {
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
    case ACT_MKDIR: printf("mkdir %s\n", a->a); break;
    case ACT_RM:    printf("rm %s\n", a->a); break;
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

static void usage(const char *argv0) {
    printf("dhake — a Make-like build tool driven by a Dhall buildfile\n\n");
    printf("Usage:\n");
    printf("  %s [-f FILE] [-j N] [-n] [--list] [target ...]\n", argv0);
    printf("  %s -h | --help\n\n", argv0);
    printf("Options:\n");
    printf("  -f FILE    buildfile to evaluate (default: ./Dhakefile.dhall, else ./build.dhall)\n");
    printf("  -j N       run up to N build jobs in parallel (default: 1, sequential)\n");
    printf("  -n         dry run: print the actions that would run, without running them\n");
    printf("  --list     list all targets and exit\n");
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
        else if (a[0] == '-') { die("unknown option '%s'", a); }
        else { if (nwanted == wanted_cap) { wanted_cap = wanted_cap ? wanted_cap * 2 : 4; wanted = realloc(wanted, (size_t)wanted_cap * sizeof(char *)); } wanted[nwanted++] = a; }
    }

    Term *root = eval_buildfile(buildfile);
    Build *b = build_plan(root);

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

            if (!dirty) {
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
                /* Child: run the full recipe, then _exit with the result */
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

    return failed;
}
