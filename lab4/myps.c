#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <unistd.h>
#include <ctype.h>

static int is_digits(const char *s) {
    if (!*s) return 0;
    for (; *s; s++)
        if (!isdigit((unsigned char)*s)) return 0;
    return 1;
}

static char *read_field(const char *path, const char *key) {
    FILE *f = fopen(path, "r");
    static char buf[4096];
    if (!f) return strdup("");
    while (fgets(buf, sizeof(buf), f)) {
        if (strncmp(buf, key, strlen(key)) == 0) {
            char *v = strchr(buf, ':');
            if (v) {
                v++;
                while (*v == '\t' || *v == ' ') v++;
                fclose(f);
                char *r = strdup(v);
                r[strcspn(r, "\n")] = '\0';
                return r;
            }
        }
    }
    fclose(f);
    return strdup("");
}

static char *read_comm(const char *pid) {
    char path[512];
    snprintf(path, sizeof(path), "/proc/%s/comm", pid);
    FILE *f = fopen(path, "r");
    static char buf[512];
    if (!f) return strdup("???");
    if (!fgets(buf, sizeof(buf), f)) snprintf(buf, sizeof(buf), "?");
    buf[strcspn(buf, "\n")] = '\0';
    fclose(f);
    return strdup(buf);
}

int main(void) {
    DIR *d = opendir("/proc");
    struct dirent *e;
    uid_t myuid = getuid();
    char uidstr[32];
    snprintf(uidstr, sizeof(uidstr), "%d", (int)myuid);
    printf("%-7s %-7s %-4s %-5s %s\n", "PID", "PPID", "UID", "STAT", "CMD");
    if (!d) { perror("opendir"); return 1; }
    while ((e = readdir(d))) {
        if (!is_digits(e->d_name)) continue;
        char p[256];
        snprintf(p, sizeof(p), "/proc/%s/status", e->d_name);
        char *uid = read_field(p, "Uid");
        if (strncmp(uid, uidstr, strlen(uidstr)) != 0) { free(uid); continue; }
        char *ppid = read_field(p, "PPid");
        char *state = read_field(p, "State");
        char *comm = read_comm(e->d_name);
        printf("%-7s %-7s %-4s %-5.16s %s\n", e->d_name, ppid, uidstr, state, comm);
        free(uid); free(ppid); free(state); free(comm);
    }
    closedir(d);
    return 0;
}