#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>

int main(void) {
    size_t n = 16 * 1024 * 1024;
    char *m = malloc(n);
    size_t i;
    if (!m) { perror("malloc"); return 1; }
    for (i = 0; i < n; i++) m[i] = (char)(i % 251);
    printf("PARENT: выделено %zu байт, addr=%p m[5]=%d\n", n, (void *)m, (int)m[5]);
    fflush(stdout);
    pid_t pid = fork();
    if (pid == 0) {
        printf("CHILD: addr=%p (тот же виртуальный адрес), изменяю m[5]\n", (void *)m);
        m[5] = 99;
        printf("CHILD: m[5]=%d\n", (int)m[5]);
        return 0;
    }
    sleep(1);
    printf("PARENT: после изменения потомком m[5]=%d (не изменилось — copy-on-write)\n", (int)m[5]);
    wait(NULL);
    free(m);
    return 0;
}