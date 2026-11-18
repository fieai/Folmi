#include "FolmiPTYSpawn.h"
#include <signal.h>
#include <unistd.h>
#include <util.h>

pid_t folmi_fork_pty(int *master, const char *cwd, char *const argv[],
                     char *const envp[], const struct winsize *size) {
    pid_t pid = forkpty(master, NULL, NULL, (struct winsize *)size);
    if (pid != 0) return pid;

    // The child may inherit locked Swift/Foundation state. Use only POSIX calls before exec.
    struct sigaction action = { .sa_handler = SIG_DFL };
    sigemptyset(&action.sa_mask);
    sigaction(SIGHUP, &action, NULL);
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGQUIT, &action, NULL);
    sigaction(SIGPIPE, &action, NULL);
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGCHLD, &action, NULL);
    sigset_t mask;
    sigemptyset(&mask);
    sigprocmask(SIG_SETMASK, &mask, NULL);
    if (chdir(cwd) == 0) execve(argv[0], argv, envp);
    static const char message[] = "Folmi: 终端程序无法启动\r\n";
    write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(127);
}

static volatile sig_atomic_t shutdown_requested;

static void request_shutdown(int signal) {
    shutdown_requested = 1;
}

void folmi_install_pty_shutdown_handler(void) {
    struct sigaction action = { .sa_handler = request_shutdown };
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL);
}

int folmi_pty_shutdown_requested(void) {
    return shutdown_requested;
}
