#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "использование: %s <программа> [аргументы...]\n", argv[0]);
        return 2;
    }
    pid_t pid = fork();
    if (pid == 0) {
        execvp(argv[1], &argv[1]);
        perror("execvp");
        _exit(127);
    }
    printf("myrun: запущен потомок pid=%d\n", (int)pid);
    fflush(stdout);
    int status;
    pid_t done = waitpid(pid, &status, 0);
    if (WIFEXITED(status))
        printf("myrun: pid=%d завершился нормально, код возврата=%d\n", (int)done, WEXITSTATUS(status));
    else if (WIFSIGNALED(status))
        printf("myrun: pid=%d завершён сигналом %d\n", (int)done, WTERMSIG(status));
    else
        printf("myrun: pid=%d завершился иным образом\n", (int)done);
    return 0;
}