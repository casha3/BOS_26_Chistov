#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

static const char *perm_str(int x) {
    static char p[4];
    p[0] = (x & 4) ? 'r' : '-';
    p[1] = (x & 2) ? 'w' : '-';
    p[2] = (x & 1) ? 'x' : '-';
    p[3] = '\0';
    return p;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "использование: %s <PID> [фильтр=rwx]\n", argv[0]);
        return 2;
    }
    char path[256];
    snprintf(path, sizeof(path), "/proc/%s/maps", argv[1]);
    FILE *f = fopen(path, "r");
    if (!f) {
        perror(argv[1]);
        fprintf(stderr, "нет PID или нет доступа или процесс завершился\n");
        return 1;
    }
    int want_r = 0, want_w = 0, want_x = 0;
    if (argc > 2) {
        want_r = !!strchr(argv[2], 'r');
        want_w = !!strchr(argv[2], 'w');
        want_x = !!strchr(argv[2], 'x');
    }
    char line[1024];
    unsigned long total = 0;
    char fltr = argc > 2 ? 1 : 0;
    printf("%-14s %-10s %-4s %-5s %s\n", "start-end", "size(KB)", "perm", "flags", "file");
    while (fgets(line, sizeof(line), f)) {
unsigned long start, end, offset, devmaj, devmin, inode;
    char perms[8], pathm[256] = "";
        if (sscanf(line, "%lx-%lx %4s %lx %02lx:%02lx %lu %255s",
                   &start, &end, perms, &offset, &devmaj, &devmin, &inode, pathm) < 7) continue;
        if (strlen(pathm) == 0 && sscanf(line, "%lx-%lx %4s %lx %02lx:%02lx %lu",
                                         &start, &end, perms, &offset, &devmaj, &devmin, &inode) < 7) continue;
        int r = perms[0] == 'r', w = perms[1] == 'w', x = perms[2] == 'x';
        if (fltr && (r != want_r || w != want_w || x != want_x)) continue;
        unsigned long size = (end - start) / 1024;
        total += size;
        char perms4[5];
        snprintf(perms4, sizeof(perms4), "%s%c",
                 perm_str((r << 2) | (w << 1) | x), perms[3]);
        printf("%014lx-%014lx %-10lu %-4s %s\n", start, end, size, perms4, pathm);
    }
    fclose(f);
    printf("ИТОГО обнаруженный размер: %lu KB\n", total);
    return 0;
}