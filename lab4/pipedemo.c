#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>

int main(void) {
    int fds[2];
    char buf[512];
    ssize_t n;
    pid_t pid;
    if (pipe(fds) < 0) { perror("pipe"); return 1; }
    pid = fork();
    if (pid == 0) {
        close(fds[0]);
        dup2(fds[1], STDOUT_FILENO);
        close(fds[1]);
        printf("строка-1\nстрелка-2\nстрока-3\n");
        exit(0);
    }
    close(fds[1]);
    printf("РОДИТЕЛЬ: читаю из канала\n");
    while ((n = read(fds[0], buf, sizeof(buf))) > 0) {
        write(STDOUT_FILENO, buf, (size_t)n);
    }
    close(fds[0]);
    wait(NULL);
    printf("\nРОДИТЕЛЬ: поток данных закончился, потомок завершён\n");
    return 0;
}