#include <stdio.h>
#include <unistd.h>

int main(void) {
    pid_t pid = fork();
    if (pid == 0) _exit(0);
    printf("PARENT: pid=%d, потомок %d завершён сразу; родитель работает 15 сек, НЕ вызывая wait()\n",
           (int)getpid(), (int)pid);
    sleep(15);
    printf("PARENT: 15 секунд прошло, потомок (%d) остался зомби, т.к. не выполнен wait()\n", (int)pid);
    return 0;
}