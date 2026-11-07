#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <sys/types.h>
#include <sys/wait.h>

static struct timespec now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t;
}

static double span(const struct timespec *a, const struct timespec *b) {
    return (b->tv_sec - a->tv_sec) + (b->tv_nsec - a->tv_nsec) / 1e9;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "использование: %s <секунды> <программа> [аргументы...]\n", argv[0]);
        return 2;
    }
    int limit = atoi(argv[1]);
    if (limit < 0) limit = 0;
    pid_t pid = fork();
    if (pid == 0) {
        execvp(argv[2], &argv[2]);
        perror("execvp");
        _exit(127);
    }
    struct timespec start = now_ms();
    int status = 0;
    int timed_out = 0;
    for (;;) {
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid) break;
        if (r < 0) { perror("waitpid"); return 1; }
        struct timespec now = now_ms();
        if (span(&start, &now) >= (double)limit) {
            timed_out = 1;
            kill(pid, SIGTERM);
            for (int i = 0; i < 20; i++) {
                r = waitpid(pid, &status, WNOHANG);
                if (r == pid) break;
                usleep(100000);
            }
            if (r != pid) {
                printf("mytimeout: SIGTERM не помог, применяю SIGKILL\n");
                kill(pid, SIGKILL);
                waitpid(pid, &status, 0);
            }
            break;
        }
        usleep(20000);
    }
    struct timespec endt = now_ms();
    double elapsed = span(&start, &endt);
    if (timed_out) {
        printf("mytimeout: ПРЕВЫШЕНО время %d с (протекло %.2f с); потомок убит\n", limit, elapsed);
        if (WIFEXITED(status))
            printf("mytimeout: потомок pid=%d код=%d\n", (int)pid, WEXITSTATUS(status));
        else if (WIFSIGNALED(status))
            printf("mytimeout: потомок pid=%d сигнал=%d\n", (int)pid, WTERMSIG(status));
    } else {
        if (WIFEXITED(status))
            printf("mytimeout: штатное завершение pid=%d код=%d за %.2f с\n",
                   (int)pid, WEXITSTATUS(status), elapsed);
        else if (WIFSIGNALED(status))
            printf("mytimeout: pid=%d завершён сигналом %d за %.2f с\n",
                   (int)pid, WTERMSIG(status), elapsed);
    }
    return 0;
}