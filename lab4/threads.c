#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <unistd.h>
#include <sys/types.h>

static int counter = 0;
static pthread_mutex_t mtx = PTHREAD_MUTEX_INITIALIZER;

static void *worker(void *arg) {
    int id = *((int *)arg);
    int i;
    for (i = 0; i < 1000; i++) {
        pthread_mutex_lock(&mtx);
        counter++;
        pthread_mutex_unlock(&mtx);
    }
    printf("t%d: process-PID=%d TID=%lu counter=%d\n", id, (int)getpid(),
           (unsigned long)pthread_self(), counter);
    return NULL;
}

int main(void) {
    pthread_t t[3];
    int ids[3] = {1, 2, 3};
    int i;
    printf("PTHREADS: main process-PID=%d PID==TID для main\n", (int)getpid());
    for (i = 0; i < 3; i++)
        pthread_create(&t[i], NULL, worker, &ids[i]);
    for (i = 0; i < 3; i++)
        pthread_join(t[i], NULL);
    printf("Каталог /proc/%d/task: во время работы здесь было 4 записи (1 процесс + 3 потока).\n",
           (int)getpid());
    return 0;
}