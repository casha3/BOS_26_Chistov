#include <stdio.h>
#include <signal.h>
#include <unistd.h>

static volatile sig_atomic_t got_usr1 = 0;
static volatile sig_atomic_t finish = 0;

static void on_usr1(int sig) { got_usr1 = 1; }
static void on_term(int sig) { finish = 1; }

int main(void) {
    struct sigaction sa;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sa.sa_handler = on_usr1;
    sigaction(SIGUSR1, &sa, NULL);
    sa.sa_handler = on_term;
    sigaction(SIGTERM, &sa, NULL);
    printf("signalwatch pid=%d: жду SIGUSR1/SIGTERM...\n", (int)getpid());
    while (!finish) {
        if (got_usr1) {
            got_usr1 = 0;
            printf("получен SIGUSR1, продолжаю работу\n");
            fflush(stdout);
        }
        sleep(1);
    }
    printf("получен SIGTERM, завершаюсь корректно\n");
    return 0;
}