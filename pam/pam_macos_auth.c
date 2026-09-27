#define _GNU_SOURCE
#define PAM_SM_AUTH

#if !defined(__aarch64__)
#error "macos-auth supports only arm64/aarch64 build targets"
#endif

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <security/pam_appl.h>
#include <security/pam_modules.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#ifdef __linux__
#include <sys/syscall.h>
#else
#include <libproc.h>
#include <sys/proc_info.h>
#endif
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#ifndef PAM_AUTHINFO_UNAVAIL
#define PAM_AUTHINFO_UNAVAIL PAM_AUTH_ERR
#endif

#define MACOS_AUTH_DEFAULT_HELPER "/usr/bin/macos-auth-helper"
#define MACOS_AUTH_DEFAULT_CONFIG "/etc/macos-auth/config.toml"
#define MACOS_AUTH_DEFAULT_TIMEOUT_MS 20000
#define MACOS_AUTH_HELPER_TIMEOUT_EXIT 10

#define MACOS_AUTH_EXIT_APPROVED 0
#define MACOS_AUTH_EXIT_UNAVAILABLE 10
#define MACOS_AUTH_EXIT_CANCELLED 11
#define MACOS_AUTH_EXIT_FAILED 12
#define MACOS_AUTH_EXIT_DENIED 20
#define MACOS_AUTH_EXIT_TAMPER 30
#define MACOS_AUTH_EXIT_UNSAFE_CONFIG 31
#define MACOS_AUTH_EXIT_PROTOCOL 32

#ifndef MACOS_AUTH_EXECFD
#ifdef __linux__
#define MACOS_AUTH_EXECFD(fd, argv, envp) fexecve(fd, argv, envp)
#else
/* macOS can build the shim but cannot securely execute an fd. */
#define MACOS_AUTH_EXECFD(fd, argv, envp) ((void)(fd), (void)(argv), (void)(envp), errno = ENOTSUP)
#endif
#endif

struct macos_auth_options {
    const char *helper_path;
    const char *config_path;
    bool debug;
    unsigned int timeout_ms;
};

static void log_message(int priority, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vsyslog(priority, fmt, args);
    va_end(args);
}

static bool starts_with(const char *value, const char *prefix) {
    return strncmp(value, prefix, strlen(prefix)) == 0;
}

static unsigned int parse_uint_option(const char *value, unsigned int fallback) {
    if (value == NULL || value[0] == '\0') {
        return fallback;
    }
    char *end = NULL;
    errno = 0;
    unsigned long parsed = strtoul(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || parsed == 0 || parsed > 600000UL) {
        return fallback;
    }
    return (unsigned int)parsed;
}

static void parse_options(int argc, const char **argv, struct macos_auth_options *options) {
    options->helper_path = MACOS_AUTH_DEFAULT_HELPER;
    options->config_path = MACOS_AUTH_DEFAULT_CONFIG;
    options->debug = false;
    options->timeout_ms = MACOS_AUTH_DEFAULT_TIMEOUT_MS;

    for (int i = 0; i < argc; i++) {
        const char *arg = argv[i];
        if (strcmp(arg, "debug") == 0) {
            options->debug = true;
        } else if (starts_with(arg, "helper=")) {
            options->helper_path = arg + strlen("helper=");
        } else if (starts_with(arg, "conf=")) {
            options->config_path = arg + strlen("conf=");
        } else if (starts_with(arg, "timeout_ms=")) {
            options->timeout_ms = parse_uint_option(arg + strlen("timeout_ms="), MACOS_AUTH_DEFAULT_TIMEOUT_MS);
        }
    }
}

static bool trusted_metadata(const struct stat *st, bool directory) {
    return st->st_uid == 0 && (st->st_mode & 0022) == 0 &&
        (directory ? S_ISDIR(st->st_mode) : (S_ISREG(st->st_mode) && (st->st_mode & S_IXUSR) != 0));
}

/* Return the validated executable fd, never reopen its pathname for execution. */
static int validate_helper_path(const char *helper_path) {
    if (helper_path == NULL || helper_path[0] != '/') {
        log_message(LOG_AUTHPRIV | LOG_ERR, "macos-auth: helper path must be absolute");
        return -1;
    }

    size_t length = strlen(helper_path);
    if (length < 2 || helper_path[length - 1] == '/') {
        return -1;
    }
    char *path = strdup(helper_path);
    if (path == NULL) {
        return -1;
    }
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    struct stat st;
    bool valid = fd >= 0 && fstat(fd, &st) == 0 && trusted_metadata(&st, true);
    char *save = NULL;
    char *component = strtok_r(path, "/", &save);
    while (valid && component != NULL) {
        if (strcmp(component, ".") == 0 || strcmp(component, "..") == 0) {
            valid = false;
            break;
        }
        char *next = strtok_r(NULL, "/", &save);
        int flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK;
        if (next != NULL) {
            flags |= O_DIRECTORY;
        }
        int child = openat(fd, component, flags);
        close(fd);
        fd = child;
        valid = fd >= 0 && fstat(fd, &st) == 0 && trusted_metadata(&st, next != NULL);
        component = next;
    }
    free(path);
    if (!valid) {
        if (fd >= 0) {
            close(fd);
        }
        log_message(LOG_AUTHPRIV | LOG_ERR, "macos-auth: helper and ancestors must be root-owned, non-writable, and not symlinks");
        return -1;
    }
    return fd;
}

static const char *pam_item_string(pam_handle_t *pamh, int item_type) {
    const void *value = NULL;
    if (pam_get_item(pamh, item_type, &value) != PAM_SUCCESS || value == NULL) {
        return NULL;
    }
    const char *string_value = (const char *)value;
    if (string_value[0] == '\0') {
        return NULL;
    }
    return string_value;
}

static int push_arg(char **exec_argv, size_t exec_argv_len, size_t *index, const char *arg) {
    if (*index + 1 >= exec_argv_len) {
        return -1;
    }
    exec_argv[*index] = (char *)arg;
    *index += 1;
    exec_argv[*index] = NULL;
    return 0;
}

static int push_optional_pair(
    char **exec_argv,
    size_t exec_argv_len,
    size_t *index,
    const char *name,
    const char *value
) {
    if (value == NULL || value[0] == '\0') {
        return 0;
    }
    if (push_arg(exec_argv, exec_argv_len, index, name) != 0) {
        return -1;
    }
    return push_arg(exec_argv, exec_argv_len, index, value);
}

static int monotonic_ms(unsigned long long *value) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return -1;
    }
    *value = ((unsigned long long)ts.tv_sec * 1000ULL) + ((unsigned long long)ts.tv_nsec / 1000000ULL);
    return 0;
}

static int close_inherited_fds(void) {
#ifdef __linux__
#if defined(SYS_close_range) && !defined(MACOS_AUTH_NO_CLOSE_RANGE)
    if (syscall(SYS_close_range, 4U, ~0U, 0U) == 0) {
        return 0;
    }
#endif
    /* Older kernels: use raw getdents64, avoiding allocation after fork. */
    int directory = open("/proc/self/fd", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (directory < 0) {
        return -1;
    }
    struct fd_entry {
        unsigned long long ino;
        long long offset;
        unsigned short reclen;
        unsigned char type;
        char name[];
    };
    char buffer[4096];
    for (;;) {
        long count = syscall(SYS_getdents64, directory, buffer, sizeof(buffer));
        if (count == 0) {
            break;
        }
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            close(directory);
            return -1;
        }
        for (long offset = 0; offset < count;) {
            struct fd_entry *entry = (struct fd_entry *)(buffer + offset);
            if (entry->reclen == 0) {
                close(directory);
                return -1;
            }
            int fd = 0;
            for (const char *digit = entry->name; *digit >= '0' && *digit <= '9'; digit++) {
                fd = fd * 10 + (*digit - '0');
            }
            if (fd >= 4 && fd != directory) {
                close(fd);
            }
            offset += entry->reclen;
        }
    }
    close(directory);
    return 0;
#else
    /* Development-only macOS build; fail closed if the list is incomplete. */
    struct proc_fdinfo descriptors[4096];
    int size = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, descriptors, sizeof(descriptors));
    if (size <= 0 || (size_t)size >= sizeof(descriptors)) {
        return -1;
    }
    for (size_t i = 0; i < (size_t)size / sizeof(descriptors[0]); i++) {
        if (descriptors[i].proc_fd >= 4) {
            close(descriptors[i].proc_fd);
        }
    }
    return 0;
#endif
}

static void kill_and_reap(pid_t pid) {
    kill(pid, SIGKILL);
    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {
    }
}

static int run_helper(int helper_fd, char *const exec_argv[], unsigned int timeout_ms) {
    unsigned long long start_ms;
    if (timeout_ms == 0 || monotonic_ms(&start_ms) != 0) {
        log_message(LOG_AUTHPRIV | LOG_ERR, "macos-auth: invalid timeout or monotonic clock failure");
        return 127;
    }
    pid_t pid = fork();
    if (pid < 0) {
        log_message(LOG_AUTHPRIV | LOG_ERR, "macos-auth: fork failed: %s", strerror(errno));
        return 127;
    }

    if (pid == 0) {
        static char *const envp[] = {
            "PATH=/usr/sbin:/usr/bin:/sbin:/bin",
            "LC_ALL=C",
            NULL,
        };

        if (helper_fd != 3 && dup2(helper_fd, 3) < 0) {
            _exit(127);
        }
        if (fcntl(3, F_SETFD, FD_CLOEXEC) != 0 || close_inherited_fds() != 0) {
            _exit(127);
        }
        MACOS_AUTH_EXECFD(3, exec_argv, envp);
        _exit(127);
    }

    int status = 0;
    for (;;) {
        pid_t waited = waitpid(pid, &status, WNOHANG);
        if (waited == pid) {
            break;
        }
        if (waited < 0) {
            if (errno == EINTR) {
                continue;
            }
            int wait_error = errno;
            log_message(LOG_AUTHPRIV | LOG_ERR, "macos-auth: waitpid failed: %s", strerror(wait_error));
            if (wait_error != ECHILD) {
                kill_and_reap(pid);
            }
            return 127;
        }

        unsigned long long now_ms;
        if (monotonic_ms(&now_ms) != 0 || now_ms < start_ms) {
            log_message(LOG_AUTHPRIV | LOG_ERR, "macos-auth: monotonic clock failure");
            kill_and_reap(pid);
            return 127;
        }
        if (now_ms - start_ms >= timeout_ms) {
            log_message(LOG_AUTHPRIV | LOG_ERR, "macos-auth: helper timed out after %u ms", timeout_ms);
            kill(pid, SIGTERM);
            for (int i = 0; i < 20; i++) {
                waited = waitpid(pid, &status, WNOHANG);
                if (waited == pid) {
                    return MACOS_AUTH_HELPER_TIMEOUT_EXIT;
                }
                if (waited < 0 && errno == ECHILD) {
                    return 127;
                }
                usleep(50000);
            }
            kill_and_reap(pid);
            return MACOS_AUTH_HELPER_TIMEOUT_EXIT;
        }

        usleep(10000);
    }

    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }

    if (WIFSIGNALED(status)) {
        log_message(LOG_AUTHPRIV | LOG_ERR, "macos-auth: helper terminated by signal %d", WTERMSIG(status));
        return 127;
    }

    return 127;
}

static int map_exit_to_pam(int exit_code) {
    switch (exit_code) {
        case MACOS_AUTH_EXIT_APPROVED:
            return PAM_SUCCESS;
        case MACOS_AUTH_EXIT_UNAVAILABLE:
        case MACOS_AUTH_EXIT_CANCELLED:
        case MACOS_AUTH_EXIT_FAILED:
            return PAM_AUTHINFO_UNAVAIL;
        case MACOS_AUTH_EXIT_DENIED:
        case MACOS_AUTH_EXIT_TAMPER:
        case MACOS_AUTH_EXIT_UNSAFE_CONFIG:
        case MACOS_AUTH_EXIT_PROTOCOL:
        default:
            return PAM_AUTH_ERR;
    }
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)flags;

    struct macos_auth_options options;
    parse_options(argc, argv, &options);

    const char *service = pam_item_string(pamh, PAM_SERVICE);
    const char *ruser = pam_item_string(pamh, PAM_RUSER);
    const char *rhost = pam_item_string(pamh, PAM_RHOST);
    const char *tty = pam_item_string(pamh, PAM_TTY);

    const char *user = NULL;
    int pam_result = pam_get_user(pamh, &user, NULL);
    if (pam_result != PAM_SUCCESS || user == NULL || user[0] == '\0') {
        log_message(LOG_AUTHPRIV | LOG_ERR, "macos-auth: failed to obtain PAM user");
        return PAM_AUTH_ERR;
    }

    char *exec_argv[24] = {0};
    size_t index = 0;

    if (push_arg(exec_argv, 24, &index, options.helper_path) != 0 ||
        push_arg(exec_argv, 24, &index, "request") != 0 ||
        push_arg(exec_argv, 24, &index, "--require-root-owned") != 0 ||
        push_arg(exec_argv, 24, &index, "--config") != 0 ||
        push_arg(exec_argv, 24, &index, options.config_path) != 0 ||
        push_arg(exec_argv, 24, &index, "--user") != 0 ||
        push_arg(exec_argv, 24, &index, user) != 0 ||
        push_optional_pair(exec_argv, 24, &index, "--service", service) != 0 ||
        push_optional_pair(exec_argv, 24, &index, "--ruser", ruser) != 0 ||
        push_optional_pair(exec_argv, 24, &index, "--rhost", rhost) != 0 ||
        push_optional_pair(exec_argv, 24, &index, "--tty", tty) != 0) {
        log_message(LOG_AUTHPRIV | LOG_ERR, "macos-auth: too many helper arguments");
        return PAM_AUTH_ERR;
    }

    if (options.debug) {
        log_message(LOG_AUTHPRIV | LOG_DEBUG, "macos-auth: invoking helper for service=%s user=%s ruser=%s tty=%s",
            service != NULL ? service : "",
            user,
            ruser != NULL ? ruser : "",
            tty != NULL ? tty : "");
    }

    int helper_fd = validate_helper_path(options.helper_path);
    if (helper_fd < 0) {
        return PAM_AUTH_ERR;
    }
    int helper_exit = run_helper(helper_fd, exec_argv, options.timeout_ms);
    close(helper_fd);
    int mapped = map_exit_to_pam(helper_exit);

    if (options.debug) {
        log_message(LOG_AUTHPRIV | LOG_DEBUG, "macos-auth: helper exit=%d mapped_pam=%d", helper_exit, mapped);
    }

    return mapped;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)pamh;
    (void)flags;
    (void)argc;
    (void)argv;
    return PAM_SUCCESS;
}

#ifdef PAM_MODULE_ENTRY
PAM_MODULE_ENTRY("pam_macos_auth");
#endif
