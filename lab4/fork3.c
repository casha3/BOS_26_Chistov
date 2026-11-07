#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>

int main(int argc, char **argv) {
    int i;
    int killmode = (argc > 1 && argv[1][0] == 'k');
    for (i = 0; i < 3; i++) {
        pid_t pid = fork();
        if (pid == 0) {
            if (killmode && i == 1) {
                raise(SIGTERM);
            }
            printf("CHILD %d: pid=%d ppid=%d\n", i, (int)getpid(), (int)getppid());
            return 10 + i;
        }
    }
    for (i = 0; i < 3; i++) {
        int status;
        pid_t done = waitpid(-1, &status, 0);
        if (WIFSIGNALED(status))
            printf("PARENT: pid=%d terminated by signal %d\n", (int)done, WTERMSIG(status));
        else if (WIFEXITED(status))
            printf("PARENT: pid=%d exited with code %d\n", (int)done, WEXITSTATUS(status));
    }
    return 0;
}