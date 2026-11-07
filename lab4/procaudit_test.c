#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv, char **envp) {
    char *fake = (argc > 1) ? argv[1] : "spoofed-name";
    char *prog = (argc > 2) ? argv[2] : "/bin/sleep";
    char *args[64];
    int n = 0, i;
    args[n++] = fake;
    if (argc > 3) {
        for (i = 3; argv[i] && n < 63; i++) args[n++] = argv[i];
    } else {
        args[n++] = "120";
    }
    args[n] = NULL;
    printf("procaudit_test: execve(%s), argv[0]=%s (подмена имени)\n", prog, fake);
    fflush(stdout);
    execve(prog, args, envp);
    perror("execve");
    return 127;
}