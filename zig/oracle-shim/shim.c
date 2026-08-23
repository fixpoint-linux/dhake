#include <sys/syscall.h>
#include <unistd.h>
#include <linux/landlock.h>
#include <stddef.h>

int landlock_create_ruleset(const struct landlock_ruleset_attr *attr, size_t size, unsigned int flags) {
    return (int)syscall(__NR_landlock_create_ruleset, attr, size, flags);
}

int landlock_add_rule(int ruleset_fd, int rule_type, const void *rule_attr, unsigned int flags) {
    return (int)syscall(__NR_landlock_add_rule, ruleset_fd, rule_type, rule_attr, flags);
}

int landlock_restrict_self(int ruleset_fd, unsigned int flags) {
    return (int)syscall(__NR_landlock_restrict_self, ruleset_fd, flags);
}

static const long nr = (long)SYS_socket;
#undef __NR_socket
const int __NR_socket = (int)nr;

long sys_inotify_init1(int flags) {
    return syscall(SYS_inotify_init1, flags);
}

long sys_inotify_add_watch(int fd, const char *path, unsigned int mask) {
    return syscall(SYS_inotify_add_watch, fd, path, mask);
}
