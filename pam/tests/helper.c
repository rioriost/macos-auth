#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 2) {
        return 99;
    }
    if (strcmp(argv[1], "sleep") == 0 || strcmp(argv[1], "ignore-term") == 0) {
        if (strcmp(argv[1], "ignore-term") == 0) {
            signal(SIGTERM, SIG_IGN);
        }
        for (;;) {
            pause();
        }
    }
    if (strcmp(argv[1], "check-fds") == 0) {
        for (int fd = 3; fd < 8192; fd++) {
            errno = 0;
            if (fcntl(fd, F_GETFD) != -1 || errno != EBADF) {
                return 98;
            }
        }
        if (getenv("MACOS_AUTH_TEST_SECRET") != NULL ||
            strcmp(getenv("LC_ALL") ? getenv("LC_ALL") : "", "C") != 0 ||
            strcmp(getenv("PATH") ? getenv("PATH") : "", "/usr/sbin:/usr/bin:/sbin:/bin") != 0) {
            return 97;
        }
        return 0;
    }
    if (strcmp(argv[1], "signal") == 0) {
        raise(SIGTERM);
        return 96;
    }
    return atoi(argv[1]);
}
