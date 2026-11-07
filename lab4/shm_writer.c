#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <string.h>

int main(void) {
    key_t key;
    int shmid;
    char *addr;
    key = getuid();
    shmid = shmget(key, 256, IPC_CREAT | 0600);
    if (shmid < 0) { perror("shmget"); return 1; }
    addr = shmat(shmid, NULL, 0);
    if (addr == (char *)-1) { perror("shmat"); return 1; }
    strcpy(addr, "привет из разделяемой памяти");
    printf("shm-writer: shmid=%d addr=%p\n", shmid, (void *)addr);
    shmdt(addr);
    printf("shm-writer: завершился, id сегмента %d — передайте читателю\n", shmid);
    return 0;
}