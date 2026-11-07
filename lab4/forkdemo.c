#include <stdio.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>

int main(void) {
    int x = 123;
    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        return 1;
    }
    if (pid == 0) {
        x = 777;
        printf("CHILD: pid=%d ppid=%d x=%d &x=%p\n",
               (int)getpid(), (int)getppid(), x, (void *)&x);
        return 0;
    }
    x = x + 1;
    printf("PARENT: pid=%d ppid=%d child=%d x=%d &x=%p\n",
           (int)getpid(), (int)getppid(), (int)pid, x, (void *)&x);
    wait(NULL);
    return 0;
}