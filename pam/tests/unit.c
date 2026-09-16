#define _GNU_SOURCE
#include <assert.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

#ifdef __APPLE__
/* Test-only native adapter. Linux tests exercise real fexecve instead. */
static int test_execfd(int fd, char *const argv[], char *const envp[]) {
    char path[PATH_MAX];
    if (fcntl(fd, F_GETPATH, path) < 0) {
        return -1;
    }
    close(fd);
    return execve(path, argv, envp);
}
#define MACOS_AUTH_EXECFD(fd, argv, envp) test_execfd(fd, argv, envp)
#endif

static int clock_calls;
static int clock_fail_at;
static int test_clock_gettime(clockid_t clock, struct timespec *time) {
    if (clock_fail_at > 0 && ++clock_calls >= clock_fail_at) {
        return -1;
    }
    return clock_gettime(clock, time);
}

#define clock_gettime test_clock_gettime
#include "../pam_macos_auth.c"
#undef clock_gettime

int pam_get_item(const pam_handle_t *pamh, int item, const void **value) {
    (void)pamh;
    (void)item;
    *value = NULL;
    return PAM_SUCCESS;
}

int pam_get_user(pam_handle_t *pamh, const char **user, const char *prompt) {
    (void)pamh;
    (void)prompt;
    *user = "test-user";
    return PAM_SUCCESS;
}

static void test_mapping(void) {
    assert(map_exit_to_pam(0) == PAM_SUCCESS);
    for (int exit = 10; exit <= 12; exit++) {
        assert(map_exit_to_pam(exit) == PAM_AUTHINFO_UNAVAIL);
    }
    const int hard_fail[] = {1, 20, 30, 31, 32, 127, 255, -1};
    for (size_t i = 0; i < sizeof(hard_fail) / sizeof(hard_fail[0]); i++) {
        assert(map_exit_to_pam(hard_fail[i]) == PAM_AUTH_ERR);
    }
}

static void test_validation(void) {
    struct stat st = {0};
    st.st_uid = 0;
    st.st_mode = S_IFREG | 0755;
    assert(trusted_metadata(&st, false));
    st.st_uid = 12345;
    assert(!trusted_metadata(&st, false));
    st.st_uid = 0;
    st.st_mode |= 0020;
    assert(!trusted_metadata(&st, false));
    st.st_mode = S_IFREG | 0644;
    assert(!trusted_metadata(&st, false));
    st.st_mode = S_IFDIR | 0755;
    assert(trusted_metadata(&st, true));
    st.st_mode |= 0002;
    assert(!trusted_metadata(&st, true));

    assert(validate_helper_path("relative") == -1);
    assert(validate_helper_path("/usr/bin/../bin/true") == -1);
    assert(validate_helper_path("/usr/bin") == -1);
    assert(validate_helper_path("/") == -1);
    assert(validate_helper_path("/does-not-exist") == -1);
    int fd = validate_helper_path("/usr/bin/true");
    assert(fd >= 0);
    close(fd);

    char cwd[PATH_MAX];
    assert(getcwd(cwd, sizeof(cwd)) != NULL);
    char path[PATH_MAX];
    assert(snprintf(path, sizeof(path), "%s/tests/helper-fixture", cwd) < (int)sizeof(path));
    if (geteuid() != 0) {
        assert(validate_helper_path(path) == -1);
    }
    assert(symlink("/usr/bin/true", "tests/helper-link") == 0);
    assert(snprintf(path, sizeof(path), "%s/tests/helper-link", cwd) < (int)sizeof(path));
    assert(validate_helper_path(path) == -1);
    assert(unlink("tests/helper-link") == 0);
}

static void test_execution(void) {
    int fd = open("tests/helper-fixture", O_RDONLY | O_CLOEXEC);
    assert(fd >= 0);
    /* argv[0] deliberately points nowhere: execution must use the fd. */
    char *args[] = {"/no-such-helper-path", "20", NULL};
    assert(run_helper(fd, args, 2000) == 20);
    args[1] = "signal";
    assert(run_helper(fd, args, 2000) == 127);
    args[1] = "sleep";
    unsigned long long start, end;
    assert(monotonic_ms(&start) == 0);
    assert(run_helper(fd, args, 60) == 10);
    assert(monotonic_ms(&end) == 0 && end - start < 2000);
    args[1] = "ignore-term";
    assert(run_helper(fd, args, 60) == 10);
    assert(waitpid(-1, NULL, WNOHANG) == -1 && errno == ECHILD);

    clock_calls = 0;
    clock_fail_at = 1;
    assert(run_helper(fd, args, 2000) == 127);
    clock_calls = 0;
    clock_fail_at = 2;
    assert(run_helper(fd, args, 2000) == 127);
    clock_fail_at = 0;
    assert(waitpid(-1, NULL, WNOHANG) == -1 && errno == ECHILD);
    assert(run_helper(fd, args, 0) == 127);

    struct rlimit limit;
    assert(getrlimit(RLIMIT_NOFILE, &limit) == 0);
    if (limit.rlim_cur < 4096 && limit.rlim_max >= 4096) {
        limit.rlim_cur = 4096;
        assert(setrlimit(RLIMIT_NOFILE, &limit) == 0);
    }
    int high_fd = fcntl(fd, F_DUPFD, 2048);
    assert(high_fd >= 2048);
    assert(setenv("MACOS_AUTH_TEST_SECRET", "not-a-real-secret", 1) == 0);
    args[1] = "check-fds";
    assert(run_helper(fd, args, 2000) == 0);
    close(high_fd);

    int invalid = open("tests/unit.c", O_RDONLY | O_CLOEXEC);
    assert(invalid >= 0);
    assert(run_helper(invalid, args, 2000) == 127);
    close(invalid);
    close(fd);
}

int main(void) {
    test_mapping();
    test_validation();
    test_execution();
    struct macos_auth_options options;
    const char *args[] = {"timeout_ms=0", "unsafe_allow_helper_permissions"};
    parse_options(2, args, &options);
    assert(options.timeout_ms == MACOS_AUTH_DEFAULT_TIMEOUT_MS);
    assert(strcmp(options.helper_path, "/usr/bin/macos-auth-helper") == 0);
    puts("PAM unit tests passed (no live PAM configuration)");
    return 0;
}
