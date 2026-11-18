#include <sys/types.h>
#include <sys/ioctl.h>

pid_t folmi_fork_pty(int *master, const char *cwd, char *const argv[],
                     char *const envp[], const struct winsize *size);

void folmi_install_pty_shutdown_handler(void);
int folmi_pty_shutdown_requested(void);
