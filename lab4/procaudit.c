#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <limits.h>

static char *read_all(const char *path) {
    FILE *f = fopen(path, "r");
    static char buf[4096];
    size_t n = 0;
    if (!f) return NULL;
    n = fread(buf, 1, sizeof(buf) - 1, f);
    buf[n] = '\0';
    fclose(f);
    return buf;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "использование: %s <PID>\n", argv[0]);
        return 2;
    }
    const char *pid = argv[1];
    char p[512];
    char *cmdline = NULL, *comm = NULL;
    char exe[PATH_MAX];

    snprintf(p, sizeof(p), "/proc/%s/comm", pid);
    comm = read_all(p);
    snprintf(p, sizeof(p), "/proc/%s/cmdline", pid);
    cmdline = read_all(p);
    snprintf(p, sizeof(p), "/proc/%s/exe", pid);
    if (readlink(p, exe, sizeof(exe)) < 0) {
        perror("readlink exe");
        exe[0] = '\0';
    }

    printf("PID   = %s\n", pid);
    printf("comm  = %s\n", comm ? comm : "(нет доступа)");
    printf("cmdline (argv, разделён \\0):\n");
    if (cmdline) {
        char *it = cmdline;
        int i = 0;
        while (*it) {
            printf("  argv[%d]=%s\n", i++, it);
            it += strlen(it) + 1;
        }
    } else {
        printf("  (нет доступа)\n");
    }
    printf("exe   = %s\n", exe[0] ? exe : "(нет доступа)");

    return 0;
}