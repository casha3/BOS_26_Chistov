#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>

static int allowed(const char *name) {
    const char *ok[] = { "./childinfo", "./pinfo", "./myrun", "./signalwatch", "./fifo_reader" };
    size_t i;
    for (i = 0; i < sizeof(ok) / sizeof(ok[0]); i++)
        if (strcmp(name, ok[i]) == 0) return 1;
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "использование: %s <разрешённая_программа> [аргументы...]\n", argv[0]);
        return 2;
    }
    const char *prog = argv[1];
    if (!allowed(prog)) {
        fprintf(stderr, "safe-launch: программа %s не в списке разрешённых\n", prog);
        return 1;
    }
    int devnull = open("/dev/null", O_RDWR);
    if (devnull >= 0) {
        dup2(devnull, 0);
        for (int fd = 3; fd < 64; fd++) close(fd);
        close(devnull);
    }
    char *envp[] = { "PATH=/usr/bin:/bin", "PWD=default", NULL };
    char *args[64];
    int i;
    for (i = 0; argv[i] && i < 63; i++) args[i] = argv[i];
    args[i] = NULL;
    execve(prog, args, envp);
    perror("execve");
    return 126;
}