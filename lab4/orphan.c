#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>

int main(void) {
    pid_t pid = fork();
    if (pid == 0) {
        printf("CHILD: pid=%d ppid до завершения родителя=%d\n", (int)getpid(), (int)getppid());
        sleep(3);
        printf("CHILD: pid=%d ppid после завершения родителя=%d (стал потомком init/reparenter)\n",
               (int)getpid(), (int)getppid());
        _exit(0);
    }
    printf("PARENT: pid=%d, завершаюсь раньше потомка\n", (int)getpid());
    fflush(stdout);
    exit(0);
}