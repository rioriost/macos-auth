#define PAM_SM_AUTH

#include <errno.h>
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
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#ifndef PAM_AUTHINFO_UNAVAIL
#define PAM_AUTHINFO_UNAVAIL PAM_AUTH_ERR
#endif

#define MACOS_AUTH_DEFAULT_HELPER "/usr/local/bin/macos-auth-helper"
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

struct macos_auth_options {
    const char *helper_path;
    const char *config_path;
    bool debug;
    bool unsafe_allow_helper_permissions;
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
    if (errno != 0 || end == value || *end != '\0' || parsed > 600000UL) {
        return fallback;
    }
    return (unsigned int)parsed;
}

static void parse_options(int argc, const char **argv, struct macos_auth_options *options) {
    options->helper_path = MACOS_AUTH_DEFAULT_HELPER;
    options->config_path = MACOS_AUTH_DEFAULT_CONFIG;
    options->debug = false;
    options->unsafe_allow_helper_permissions = false;
    options->timeout_ms = MACOS_AUTH_DEFAULT_TIMEOUT_MS;

    for (int i = 0; i < argc; i++) {
        const char *arg = argv[i];
        if (strcmp(arg, "debug") == 0) {
            options->debug = true;
        } else if (strcmp(arg, "unsafe_allow_helper_permissions") == 0) {
            options->unsafe_allow_helper_permissions = true;
        } else if (starts_with(arg, "helper=")) {
            options->helper_path = arg + strlen("helper=");
        } else if (starts_with(arg, "conf=")) {
            options->config_path = arg + strlen("conf=");
        } else if (starts_with(arg, "timeout_ms=")) {
            options->timeout_ms = parse_uint_option(arg + strlen("timeout_ms="), MACOS_AUTH_DEFAULT_TIMEOUT_MS);
        }
    }
}

static int validate_helper_path(const char *helper_path, bool unsafe_allow_helper_permissions) {
    if (helper_path == NULL || helper_path[0] != '/') {
        log_message(LOG_AUTHPRIV | LOG_ERR, "macos-auth: helper path must be absolute");
        return -1;
    }

    struct stat st;
    if (stat(helper_path, &st) != 0) {
        log_message(LOG_AUTHPRIV | LOG_ERR, "macos-auth: failed to stat helper %s: %s", helper_path, strerror(errno));
        return -1;
    }

    if (!S_ISREG(st.st_mode)) {
        log_message(LOG_AUTHPRIV | LOG_ERR, "macos-auth: helper %s is not a regular file", helper_path);
        return -1;
    }

    if ((st.st_mode & S_IXUSR) == 0) {
        log_message(LOG_AUTHPRIV | LOG_ERR, "macos-auth: helper %s is not executable by owner", helper_path);
        return -1;
    }

    if (!unsafe_allow_helper_permissions && (st.st_mode & 0022) != 0) {
        log_message(LOG_AUTHPRIV | LOG_ERR, "macos-auth: helper %s must not be group/world writable", helper_path);
        return -1;
    }

    return 0;
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

static unsigned long monotonic_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return 0;
    }
    return ((unsigned long)ts.tv_sec * 1000UL) + ((unsigned long)ts.tv_nsec / 1000000UL);
}

static int run_helper(char *const exec_argv[], unsigned int timeout_ms) {
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

        for (int fd = 3; fd < 1024; fd++) {
            close(fd);
        }

        execve(exec_argv[0], exec_argv, envp);
        _exit(127);
    }

    int status = 0;
    unsigned long start_ms = monotonic_ms();
    for (;;) {
        pid_t waited = waitpid(pid, &status, WNOHANG);
        if (waited == pid) {
            break;
        }
        if (waited < 0) {
            if (errno == EINTR) {
                continue;
            }
            log_message(LOG_AUTHPRIV | LOG_ERR, "macos-auth: waitpid failed: %s", strerror(errno));
            return 127;
        }

        unsigned long now_ms = monotonic_ms();
        if (timeout_ms > 0 && start_ms > 0 && now_ms > start_ms && now_ms - start_ms > timeout_ms) {
            log_message(LOG_AUTHPRIV | LOG_ERR, "macos-auth: helper timed out after %u ms", timeout_ms);
            kill(pid, SIGTERM);
            for (int i = 0; i < 20; i++) {
                waited = waitpid(pid, &status, WNOHANG);
                if (waited == pid) {
                    return MACOS_AUTH_HELPER_TIMEOUT_EXIT;
                }
                usleep(50000);
            }
            kill(pid, SIGKILL);
            while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
            }
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

    if (validate_helper_path(options.helper_path, options.unsafe_allow_helper_permissions) != 0) {
        return PAM_AUTH_ERR;
    }

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

    int helper_exit = run_helper(exec_argv, options.timeout_ms);
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
