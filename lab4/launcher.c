#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>

int main(int argc, char **argv) {
    char *envp[] = { "MYTESTVAR=from-launcher", "PWD=scriptdir", NULL };
    char *args[] = { "./childinfo", "arg1", "arg2", NULL };
    if (argc > 1) {
        char *a[] = { argv[1], "arg1", NULL };
        printf("LAUNCHER pid=%d, заменяю образ на %s\n", (int)getpid(), argv[1]);
        execve(argv[1], a, envp);
        perror("execve");
        return 1;
    }
    printf("LAUNCHER pid=%d, заменяю образ на childinfo\n", (int)getpid());
    execve("./childinfo", args, envp);
    perror("execve");
    return 1;
}