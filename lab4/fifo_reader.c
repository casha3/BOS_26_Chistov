#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>

int main(void) {
    const char *fifo = "myfifo";
    int fd = open(fifo, O_RDONLY);
    if (fd < 0) { perror("open read"); return 1; }
    printf("fifo-reader pid=%d открыл %s на чтение\n", (int)getpid(), fifo);
    char buf[512];
    ssize_t n;
    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        write(STDOUT_FILENO, buf, (size_t)n);
    }
    if (n < 0) { perror("read"); close(fd); return 1; }
    close(fd);
    printf("fifo-reader: поток закончился (EOF), читатель завершён\n");
    return 0;
}