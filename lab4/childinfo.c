#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

extern char **environ;

int main(int argc, char **argv) {
    int i;
    printf("CHILDINFO pid=%d ppid=%d\n", (int)getpid(), (int)getppid());
    printf("argc=%d\n", argc);
    for (i = 0; i < argc; i++)
        printf("argv[%d] = %s\n", i, argv[i]);
    printf("env MYTESTVAR=%s\n", getenv("MYTESTVAR") ? getenv("MYTESTVAR") : "(нет)");
    printf("env PWD=%s\n", getenv("PWD") ? getenv("PWD") : "(нет)");
    return 0;
}