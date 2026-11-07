#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/ipc.h>
#include <sys/shm.h>

int main(int argc, char **argv) {
    int shmid;
    char *addr;
    if (argc < 2) { fprintf(stderr, "использование: %s <shmid>\n", argv[0]); return 1; }
    shmid = atoi(argv[1]);
    addr = shmat(shmid, NULL, 0);
    if (addr == (char *)-1) { perror("shmat"); return 1; }
    printf("shm-reader: shmid=%d прочитано: %s\n", shmid, addr);
    shmdt(addr);
    if (shmctl(shmid, IPC_RMID, NULL) < 0) perror("shmctl");
    else printf("shm-reader: сегмент %d удалён\n", shmid);
    return 0;
}