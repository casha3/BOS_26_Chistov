#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>

int main(void) {
    const char *fifo = "myfifo";
    int fd = open(fifo, O_WRONLY);
    if (fd < 0) { perror("open write"); return 1; }
    printf("fifo-writer pid=%d открыл %s на запись\n", (int)getpid(), fifo);
    fflush(stdout);
    sleep(1);
    const char *msg[] = { "привет-1", "привет-2", "привет-3" };
    int i;
    for (i = 0; i < 3; i++) {
        if (write(fd, msg[i], strlen(msg[i])) < 0) { perror("write"); break; }
        if (write(fd, "\n", 1) < 0) break;
        printf("fifo-writer: записал %s\n", msg[i]);
        fflush(stdout);
    }
    close(fd);
    printf("fifo-writer: канал закрыт, завершаюсь\n");
    return 0;
}