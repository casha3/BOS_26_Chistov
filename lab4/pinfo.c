#include <stdio.h>
#include <unistd.h>

int main(void) {
    printf("PID    = %d\n", (int)getpid());
    printf("PPID   = %d\n", (int)getppid());
    printf("real UID   = %d\n", (int)getuid());
    printf("effect UID = %d\n", (int)geteuid());
    return 0;
}