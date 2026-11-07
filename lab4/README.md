# Лабораторная работа № 4

Работа выполняется на виртуальной машине с Linux (Rocky Linux). Задания выполняются
через командную оболочку Bash и посредством программ на языке C.

## Сборка

Все программы на C собираются одной командой:

```sh
make
```

При необходимости полной пересборки с чистого листа:

```sh
make clean && make
```

## Запуск

Bash-скрипты запускаются интерпретатором:

```sh
bash 2.1_process_monitoring.sh
bash 2.2_jobs_signals_priority.sh
bash 2.3_fds_pipes.sh
```

Программы:

```sh
./pinfo
./forkdemo
./fork3              # без аргумента — обычные коды завершения
./fork3 kill         # второй потомок завершается по сигналу
./launcher           # заменяет образ на childinfo
./launcher ./childinfo
./childinfo arg1 arg2
./signalwatch        # принять SIGUSR1 (kill -USR1 <pid>) и SIGTERM
./pipedemo
./myrun ./childinfo hello
./myrun /bin/false
./myrun /no/such/prog
./mytimeout 3 sleep 5
./safelaunch ./childinfo hi
./mypmap $$          # карта памяти оболочки; фильтр: ./mypmap <pid> rwx
./procaudit <pid>
./procaudit_test falicious /bin/sleep 120
```

Программы FIFO и разделяемой памяти работают в паре:

```sh
mkfifo myfifo && chmod 600 myfifo
./fifo_writer &      # запишет строки в myfifo
./fifo_reader        # прочитает их
./shm_writer         # создаст сегмент и выведет shmid
./shm_reader <shmid> # прочитает строку и удалит сегмент (shmctl IPC_RMID)
```

Программа с потоками (Pthreads) собирается с флагом `-pthread`:

```sh
./threads
```

## Листинги

### 2.1–2.3. Bash-скрипты

#### 2.1_process_monitoring.sh

```sh
#!/bin/bash
set -u

section() {
    printf '\n======== %s ========\n' "$1"
}

cmd() {
    printf '\n$ %s\n' "$*"
    "$@"
}

section "2.1.1 PID/PPID/UID оболочки и управляющий терминал"
printf 'SHELL PID=%s PPID=%s\n' "$$" "$PPID"
printf 'UID пользователя: '
id -u
printf 'Имя управляющего терминала: '
ps -o tty= -p $$
printf '\nСопоставление с ps (текущая командная оболочка):\n'
cmd ps -o pid,ppid,tty,stat,cmd -p $$

section "2.1.2 ps в стандартном и BSD формате"
cmd ps
printf '\nBSD-формат:\n'
cmd ps aux
printf '\nТри выбранных процесса (PID,PPID,пользователь,состояние,команда):\n'
for p in 1 "$$" "$(pgrep -u "$(id -un)" -f bash | head -1)"; do
    if [ -n "$p" ]; then
        cmd ps -o pid,ppid,user,stat,command -p "$p"
    fi
done

section "2.1.3 Дерево процессов, PID 1 и текущая оболочка"
cmd pstree -p
printf '\nPID 1: '
cmd ps -o pid,ppid,user,comm -p 1
printf '\nЦепочка родителей от оболочки:\n'
p="$$"
while [ -n "$p" ] && [ "$p" != "0" ]; do
    line=$(ps -o pid=,ppid=,comm= -p "$p" 2>/dev/null) || break
    printf '%s\n' "$line"
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
done

section "2.1.4 sleep 120, pgrep и ppid"
sleep 120 &
SLEEP_PID=$!
sleep 1
printf '\npgrep -f sleep:\n'
cmd pgrep -af "sleep 120"
printf '\nПодтверждение ps:\n'
cmd ps -o pid,ppid,user,stat,cmd -p "$SLEEP_PID"
printf '\nРодитель (PPID): '
ps -o ppid= -p "$SLEEP_PID"
kill "$SLEEP_PID" 2>/dev/null

section "2.1.5 top (мгновенный снимок) и ps"
sleep 120 &
SLEEP_PID=$!
sleep 1
cmd top -b -n 1 -p "$SLEEP_PID"
printf '\nРазовый снимок ps:\n'
cmd ps -o pid,stat,%cpu,%mem,cmd -p "$SLEEP_PID"
cmd kill "$SLEEP_PID"

section "2.1.6 /proc/<PID>/status и cmdline"
sleep 120 &
SLEEP_PID=$!
sleep 1
printf '\n/proc/%s/status:\n' "$SLEEP_PID"
cmd grep -E "^(Name|Pid|PPid|State|Uid|Threads):" "/proc/$SLEEP_PID/status"
printf '\n/proc/%s/cmline:\n' "$SLEEP_PID"
cmd cat "/proc/$SLEEP_PID/cmdline"
printf '\nАргументы cmdline разделены NUL; разделим по строкам:\n'
cmd tr '\0' '\n' < "/proc/$SLEEP_PID/cmdline"
cmd kill "$SLEEP_PID"

section "2.1.7 /proc/self vs /proc/$$ через внешнюю команду"
printf 'Без каталога /proc/self в текущей оболочке:\n'
cmd ls -l /proc/self
printf '\n/proc/self из внешней команды bash -c (должен указывать на дочерний bash):\n'
cmd bash -c 'ls -l /proc/self'
printf '\n/proc/$$ (должен указывать на текущую оболочку):\n'
cmd bash -c 'ls -l /proc/$$'

section "2.1.8 /proc/<PID>/exe и cwd"
cmd ls -l /proc/$$/exe
cmd readlink /proc/$$/exe
cmd ls -l /proc/$$/cwd
printf '\nСравнение с ps:\n'
cmd ps -o pid,comm,cmd -p $$

section "2.1.9 Потоки процесса, PID vs TID"
sleep 120 &
SLEEP_PID=$!
sleep 1
printf 'Потоки через ps -L:\n'
cmd ps -T -p "$SLEEP_PID"
printf '\nЧисло потоков из /proc/%s/status:\n' "$SLEEP_PID"
cmd grep -E "^(Pid|Tgid|Threads):" "/proc/$SLEEP_PID/status"
printf '\nКаталог /proc/%s/task:\n' "$SLEEP_PID"
cmd ls -1 "/proc/$SLEEP_PID/task"
cmd kill "$SLEEP_PID"

section "2.1.10 /proc/<PID>/maps, VmSize, VmRSS"
sleep 120 &
SLEEP_PID=$!
sleep 1
printf 'Карта памяти командой sleep:\n'
cmd cat "/proc/$SLEEP_PID/maps"
printf '\nПараметры памяти из status:\n'
cmd grep -E "^(VmSize|VmRSS)" "/proc/$SLEEP_PID/status"
printf '\nСобственная карта для изучения кода/библиотек/кучи/стека (запустим временный shell):\n'
sh -c 'sleep 2 & p=$!; sleep 0.2; echo PID=$p; awk "/r-xp|rw-p/{print \$0}" /proc/$p/maps | head -30; kill $p'
cmd kill "$SLEEP_PID"

section "2.1.11 Потоки ядра Linux"
printf 'Потоки ядра (команда в квадратных скобках, PPID=0):\n'
cmd ps -eo pid,ppid,user,stat,comm | awk '$5 ~ /^\[/ {print}'
printf '\nПример нескольких потоков ядра:\n'
for p in $(ps -eo pid,ppid,comm | awk '$2==0 && $3~/^\[/ {print $1}'); do
    cmd ps -o pid,ppid,user,stat,comm -p "$p"
    printf '  exe: '; readlink "/proc/$p/exe" 2>&1
    printf '  cmdline: '; cat "/proc/$p/cmdline" 2>&1; printf '\n'
    printf '  maps доступность: '
    if [ -r "/proc/$p/maps" ]; then echo 'доступен'; else echo 'нет доступа'; fi
done | head -40
```

#### 2.2_jobs_signals_priority.sh

```sh
#!/bin/bash
set -u

section() {
    printf '\n======== %s ========\n' "$1"
}

cmd() {
    printf '\n$ %s\n' "$*"
    "$@"
}

section "2.2.1 Приостановка sleep (Ctrl+Z на unprotected run)"
printf 'Запускаем sleep 30 в фоне, приостанавливаем SIGSTOP и показываем jobs:\n'
sleep 30 &
J1=$!
sleep 1
cmd kill -STOP "$J1"
sleep 0.2
cmd jobs -l
printf '\nСостояние процесса по ps:\n'
cmd ps -o pid,ppid,stat,cmd -p "$J1"
cmd kill -CONT "$J1"
cmd kill "$J1" 2>/dev/null

section "2.2.2 Перевод задания в основной режим и завершение с клавиатуры"
printf 'Запускаем sleep 30 в фоне, даём команды stop/cont/pause:\n'
sleep 30 &
J2=$!
sleep 1
kill -STOP "$J2"
printf '\nПосле SIGSTOP:\n'
cmd jobs -l
cmd ps -o pid,stat,cmd -p "$J2"
kill -CONT "$J2"
printf '\nПосле SIGCONT (задание продолжилось в фоне):\n'
cmd ps -o pid,stat,cmd -p "$J2"
printf '\nЗавершаем задание (аналог Ctrl+C / kill SIGINT):\n'
cmd kill -INT "$J2"
sleep 0.2
wait "$J2" 2>/dev/null
printf 'Задание завершено, больше нет в списке jobs (внешний список):\n'
cmd jobs -p

section "2.2.3 Два фоновых задания в общий файл"
F=test_ab.log
rm -f "$F"
(while :; do echo "A $$" >> "$F"; sleep 1; done) &
A=$!
(while :; do echo "B $$" >> "$F"; sleep 1; done) &
B=$!
sleep 3
printf '\nСодержимое %s за 3 сек:\n' "$F"
cmd cat "$F"
printf '\nPID заданий:\n'
cmd ps -o pid,ppid,stat,cmd -p "$A" "$B"

section "2.2.4 SIGSTOP одному из фоновых заданий"
cmd kill -STOP "$A"
sleep 2
printf '\nПрекратило ли задание A дописывать данные (меток A больше нет):\n'
cmd tail -5 "$F"
printf '\nСостояния обоих процессов:\n'
cmd ps -o pid,stat,cmd -p "$A" "$B"
printf '\nСравнение состояния (A остановлен, B работает):\n'
cmd ps -o pid,stat,wchan:20,cmd -p "$A" "$B"

section "2.2.5 SIGCONT, затем SIGTERM обоим"
cmd kill -CONT "$A"
sleep 2
printf '\nПосле SIGCONT метки A снова появились:\n'
cmd tail -3 "$F"
cmd kill -TERM "$A"
cmd kill -TERM "$B"
sleep 1
printf '\nПроверка, что процессы исчезли (wait):\n'
wait "$A" 2>/dev/null; wait "$B" 2>/dev/null
cmd jobs -p
printf '\nПроверка в списке процессов:\n'
cmd ps -p "$A" 2>/dev/null || echo "A ($A) не найден — завершён"
cmd ps -p "$B" 2>/dev/null || echo "B ($B) не найден — завершён"
rm -f "$F"

section "2.2.6 SIGINT из другого терминала и сочетание Ctrl+C"
printf 'Запускаем тестовый процесс sleep 60, прерываем SIGINT:\n'
sleep 60 &
J6=$!
sleep 1
cmd kill -INT "$J6"
sleep 0.3
if kill -0 "$J6" 2>/dev/null; then
    echo "Процесс жив (SIGINT не прервал?)"; kill -KILL "$J6"
else
    echo "Процесс завершён по SIGINT"
fi
printf '\nCtrl+C в управляющем терминале обычно завершает передний план; здесь эмулируем kill -INT той группе.\n'

section "2.2.7 Сценарий с обработчиками SIGINT/SIGTERM/EXIT"
printf 'Создаём временный сценарий-обработчик:\n'
H=$(mktemp /tmp/handler.XXXXXX)
cat > "$H" <<'EOF'
#!/bin/bash
trap 'echo SIGINT-получен; exit 0' INT
trap 'echo SIGTERM-получен; exit 0' TERM
trap 'echo EXIT-обработчик; exit 0' EXIT
i=0
while :; do echo "log-$i" >> /tmp/handler.log; sleep 0.5; i=$((i+1)); done
EOF
chmod +x "$H"
rm -f /tmp/handler.log
"$H" &
HP=$!
sleep 1
printf '\nОпределены обработчики (INT, TERM, EXIT). Передаём SIGINT:\n'
cmd kill -INT "$HP"
sleep 0.3
printf 'Вывод журнала и обработчиков (EXIT выполнился при выходе):\n'
cmd cat /tmp/handler.log
printf '\nПовторяем с TERM:\n'
"$H" &
HP=$!
sleep 1
cmd kill -TERM "$HP"
sleep 0.3
cmd cat /tmp/handler.log
printf '\nSIGKILL нельзя перехватить:\n'
"$H" &
HP=$!
sleep 1
cmd kill -KILL "$HP"
sleep 0.3
if kill -0 "$HP" 2>/dev/null; then echo "жив"; else echo "убит — SIGKILL не перехватывается, EXIT не выполнился"; fi
cmd cat /tmp/handler.log
rm -f "$H" /tmp/handler.log

section "2.2.8 nice и 2.2.9 renice"
printf 'Запускаем два процесса с разным nice:\n'
nice -n 5 sleep 60 &
N1=$!
nice -n 15 sleep 60 &
N2=$!
sleep 1
printf 'Значения NI:\n'
cmd ps -o pid,ni,stat,cmd -p "$N1" "$N2"
printf '\nrenice в сторону меньшего приоритета (больше nice):\n'
cmd renice 10 "$N1"
cmd ps -o pid,ni,cmd -p "$N1"
printf '\nПопытка вернуть прежнее (меньшее) значение без прав администратора:\n'
cmd renice -n 5 "$N1"
cmd ps -o pid,ni,cmd -p "$N1"
cmd kill "$N1" "$N2" 2>/dev/null

section "2.2.10 Вложенная оболочка и exec"
bash -c 'echo "PID вложенной оболочки до exec: $$"; exec /bin/sleep 5; echo "эта строка не выполнится"'
printf '\nPID до и после exec одинаков (образ заменён, процесс остался).\n'
```

#### 2.3_fds_pipes.sh

```sh
#!/bin/bash
set -u

section() {
    printf '\n======== %s ========\n' "$1"
}

cmd() {
    printf '\n$ %s\n' "$*"
    "$@"
}

section "2.3.1 /proc/\$\$/fd текущей оболочки и /dev/stdin|stdout|stderr"
printf 'Дескрипторы текущей оболочки:\n'
cmd ls -l /proc/$$/fd
printf '\nСимволические ссылки:\n'
cmd ls -l /dev/stdin /dev/stdout /dev/stderr

section "2.3.2 Разделение stdout и stderr"
printf 'Команда с обычным выводом и ошибкой.\n'
printf 'stdout -> out.txt, stderr -> err.txt:\n'
cmd bash -c 'echo "обычный вывод"; echo "сообщение об ошибке" >&2' > out.txt 2> err.txt
printf 'out.txt: '; cmd cat out.txt
printf 'err.txt: '; cmd cat err.txt
printf '\nОбъединение потоков в один файл (2>&1):\n'
cmd bash -c 'echo "обычный вывод"; echo "сообщение об ошибке" >&2' > both.txt 2>&1
cmd cat both.txt
rm -f out.txt err.txt both.txt

section "2.3.3 Дескрипторы 3 (запись) и 4 (чтение) с fdinfo"
F=fd_test.txt
exec 3> "$F"
printf 'строка-записи-через-fd3\n' >&3
exec 4< "$F"
cmd cat <&4
printf '\nЗаписи в /proc/$$/fd и /proc/$$/fdinfo:\n'
cmd ls -l /proc/$$/fd/3 /proc/$$/fd/4
printf '\nПозиция файла (pos) в fdinfo:\n'
cmd cat /proc/$$/fdinfo/3
cmd cat /proc/$$/fdinfo/4
printf '\nДописываем и снова читаем, следим за позицией:\n'
printf 'вторая-строка\n' >&3
cmd cat /proc/$$/fdinfo/3
exec 4<&-
exec 3>&-

section "2.3.4 Удаление имени файла без закрытия дескрипторов"
exec 3> "$F"
printf 'данные-через-дескриптор\n' >&3
cmd rm -f "$F"
printf '\nЧтение по имени файла (пусто/нет):\n'
cmd cat "$F"
printf '\nЧтение через открытый дескриптор (дескриптор 4 открыт на чтение после записи):\n'
exec 4< "$F"
cmd cat <&4
printf '\nДескрипторы всё ещё в /proc/$$/fd:\n'
cmd ls -l /proc/$$/fd/3 /proc/$$/fd/4
exec 4<&-
exec 3>&-
printf '\nПосле закрытия они исчезли:\n'
cmd ls -l /proc/$$/fd | grep -E "/(3|4)" || echo "дескрипторы 3 и 4 закрыты"
rm -f "$F"

section "2.3.5 Неименованный канал между двумя процессами"
printf 'Конвейер: первая команда шлёт строки, вторая преобразует (пример принудительно завершим):\n'
(printf 'hello\nworld\nfoo\n'; sleep 60) | tr a-z A-Z | head -3 &
PIPE_JOB=$!
sleep 1
printf '\nПроцессы конвейера и их fd (ищем пары, соединённые каналом):\n'
pids=$(jobs -p)
cmd ps -o pid,ppid,stat,cmd >/tmp/pspipe
cmd cat /tmp/pspipe
for p in $pids; do
    printf '\nfds процесса %s:\n' "$p"
    cmd ls -l "/proc/$p/fd"
done
kill "${PIPE_JOB}" 2>/dev/null
pkill -f "sleep 60" 2>/dev/null
rm -f /tmp/pspipe

section "2.3.6 Создание FIFO, тип, владелец, права"
FIFO=myfifo
rm -f "$FIFO"
cmd mkfifo "$FIFO"
cmd ls -l "$FIFO"
cmd stat "$FIFO"
printf '\nvs обычный файл:\n'
echo test > plain.txt
cmd ls -l plain.txt
rm -f plain.txt

section "2.3.7 Обмен строками через FIFO между процессами"
rm -f "$FIFO"; mkfifo "$FIFO"
printf 'Читатель подключается первым (блокируется, пока нет писателя), запускаем в фоне:\n'
( cat "$FIFO" > fifo_copy.txt ) &
READ=$!
sleep 1
printf 'Писатель пишет строки:\n'
(cat <<'EOF'
строка-1
строка-2
строка-3
EOF
) > "$FIFO"
wait "$READ"
printf 'Прочитанные данные:\n'
cmd cat fifo_copy.txt
printf '\nОткрытие на чтение без писателя блокирует; проверяем поведение (в фоне, с таймаутом):\n'
(timeout 2 cat "$FIFO") & T=$!
sleep 0.3
(pkill -f "timeout 2 cat $FIFO") 2>/dev/null
printf 'Читатель завершился по таймауту, так как писатель не появлялся.\n'
rm -f "$FIFO" fifo_copy.txt

section "2.3.8 Два читателя и один писатель (общий поток)"
rm -f "$FIFO"; mkfifo "$FIFO"
( cat "$FIFO" | head -20 > reader1.txt ) &
R1=$!
( cat "$FIFO" | head -20 > reader2.txt ) &
R2=$!
sleep 1
printf 'Писатель направляет 6 строк:\n'
for i in $(seq 1 6); do echo "строка-$i" > "$FIFO"; done
exec 9>"$FIFO"
exec 9>&-
sleep 1
printf 'reader1.txt:\n'; cmd cat reader1.txt
printf 'reader2.txt:\n'; cmd cat reader2.txt
printf '\nСтроки распределяются между читателями как единый поток (не дублируются).\n'
wait "$R1" "$R2" 2>/dev/null
rm -f "$FIFO" reader1.txt reader2.txt

section "2.3.9 Права на FIFO только для владельца"
rm -f "$FIFO"; mkfifo -m 600 "$FIFO"
cmd ls -l "$FIFO"
printf '\nПроверка прав:\n'
cmd stat -c "mode=%a owner=%U group=%G" "$FIFO"
printf 'Только владелец может читать/писать. Удаляем FIFO:\n'
cmd rm -f "$FIFO"
```

### 2.4. Программное управление процессами

#### 2.4.1 pinfo.c

```c
#include <stdio.h>
#include <unistd.h>

int main(void) {
    printf("PID    = %d\n", (int)getpid());
    printf("PPID   = %d\n", (int)getppid());
    printf("real UID   = %d\n", (int)getuid());
    printf("effect UID = %d\n", (int)geteuid());
    return 0;
}
```

#### 2.4.2 forkdemo.c

```c
#include <stdio.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>

int main(void) {
    int x = 123;
    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        return 1;
    }
    if (pid == 0) {
        x = 777;
        printf("CHILD: pid=%d ppid=%d x=%d &x=%p\n",
               (int)getpid(), (int)getppid(), x, (void *)&x);
        return 0;
    }
    x = x + 1;
    printf("PARENT: pid=%d ppid=%d child=%d x=%d &x=%p\n",
           (int)getpid(), (int)getppid(), (int)pid, x, (void *)&x);
    wait(NULL);
    return 0;
}
```

#### 2.4.3 fork3.c

```c
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>

int main(int argc, char **argv) {
    int i;
    int killmode = (argc > 1 && argv[1][0] == 'k');
    for (i = 0; i < 3; i++) {
        pid_t pid = fork();
        if (pid == 0) {
            if (killmode && i == 1) {
                raise(SIGTERM);
            }
            printf("CHILD %d: pid=%d ppid=%d\n", i, (int)getpid(), (int)getppid());
            return 10 + i;
        }
    }
    for (i = 0; i < 3; i++) {
        int status;
        pid_t done = waitpid(-1, &status, 0);
        if (WIFSIGNALED(status))
            printf("PARENT: pid=%d terminated by signal %d\n", (int)done, WTERMSIG(status));
        else if (WIFEXITED(status))
            printf("PARENT: pid=%d exited with code %d\n", (int)done, WEXITSTATUS(status));
    }
    return 0;
}
```

#### 2.4.4 launcher.c

```c
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>

int main(int argc, char **argv) {
    char *envp[] = { "MYTESTVAR=from-launcher", "PWD=scriptdir", NULL };
    char *args[] = { "./childinfo", "arg1", "arg2", NULL };
    if (argc > 1) {
        char *a[] = { argv[1], "arg1", NULL };
        printf("LAUNCHER pid=%d, заменяю образ на %s\n", (int)getpid(), argv[1]);
        execve(argv[1], a, envp);
        perror("execve");
        return 1;
    }
    printf("LAUNCHER pid=%d, заменяю образ на childinfo\n", (int)getpid());
    execve("./childinfo", args, envp);
    perror("execve");
    return 1;
}
```

#### 2.4.4 childinfo.c

```c
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

extern char **environ;

int main(int argc, char **argv) {
    int i;
    printf("CHILDINFO pid=%d ppid=%d\n", (int)getpid(), (int)getppid());
    printf("argc=%d\n", argc);
    for (i = 0; i < argc; i++)
        printf("argv[%d] = %s\n", i, argv[i]);
    printf("env MYTESTVAR=%s\n", getenv("MYTESTVAR") ? getenv("MYTESTVAR") : "(нет)");
    printf("env PWD=%s\n", getenv("PWD") ? getenv("PWD") : "(нет)");
    return 0;
}
```

#### 2.4.5 signalwatch.c

```c
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
```

#### 2.4.6 pipedemo.c

```c
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>

int main(void) {
    int fds[2];
    char buf[512];
    ssize_t n;
    pid_t pid;
    if (pipe(fds) < 0) { perror("pipe"); return 1; }
    pid = fork();
    if (pid == 0) {
        close(fds[0]);
        dup2(fds[1], STDOUT_FILENO);
        close(fds[1]);
        printf("строка-1\nстрелка-2\nстрока-3\n");
        exit(0);
    }
    close(fds[1]);
    printf("РОДИТЕЛЬ: читаю из канала\n");
    while ((n = read(fds[0], buf, sizeof(buf))) > 0) {
        write(STDOUT_FILENO, buf, (size_t)n);
    }
    close(fds[0]);
    wait(NULL);
    printf("\nРОДИТЕЛЬ: поток данных закончился, потомок завершён\n");
    return 0;
}
```

#### 2.4.7 fifo_writer.c

```c
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
```

#### 2.4.7 fifo_reader.c

```c
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
```

#### 2.4.8 shm_writer.c

```c
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
```

#### 2.4.8 shm_reader.c

```c
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
```

#### 2.4.9 cow.c

```c
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
```

#### 2.4.10 zombie.c

```c
#include <stdio.h>
#include <unistd.h>

int main(void) {
    pid_t pid = fork();
    if (pid == 0) _exit(0);
    printf("PARENT: pid=%d, потомок %d завершён сразу; родитель работает 15 сек, НЕ вызывая wait()\n",
           (int)getpid(), (int)pid);
    sleep(15);
    printf("PARENT: 15 секунд прошло, потомок (%d) остался зомби, т.к. не выполнен wait()\n", (int)pid);
    return 0;
}
```

#### 2.4.11 orphan.c

```c
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>

int main(void) {
    pid_t pid = fork();
    if (pid == 0) {
        printf("CHILD: pid=%d ppid до завершения родителя=%d\n", (int)getpid(), (int)getppid());
        sleep(3);
        printf("CHILD: pid=%d ppid после завершения родителя=%d (стал потомком init/reparenter)\n",
               (int)getpid(), (int)getppid());
        _exit(0);
    }
    printf("PARENT: pid=%d, завершаюсь раньше потомка\n", (int)getpid());
    fflush(stdout);
    exit(0);
}
```

#### 2.4.12 threads.c

```c
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
```

### 2.5. Реализация системных утилит

#### 2.5.1 myps.c

```c
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
    static char buf[256];
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
        char p[512];
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
```

#### 2.5.2 myrun.c

```c
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "использование: %s <программа> [аргументы...]\n", argv[0]);
        return 2;
    }
    pid_t pid = fork();
    if (pid == 0) {
        execvp(argv[1], &argv[1]);
        perror("execvp");
        _exit(127);
    }
    printf("myrun: запущен потомок pid=%d\n", (int)pid);
    fflush(stdout);
    int status;
    pid_t done = waitpid(pid, &status, 0);
    if (WIFEXITED(status))
        printf("myrun: pid=%d завершился нормально, код возврата=%d\n", (int)done, WEXITSTATUS(status));
    else if (WIFSIGNALED(status))
        printf("myrun: pid=%d завершён сигналом %d\n", (int)done, WTERMSIG(status));
    else
        printf("myrun: pid=%d завершился иным образом\n", (int)done);
    return 0;
}
```

#### 2.5.3 mytimeout.c

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <sys/types.h>
#include <sys/wait.h>

static struct timespec now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t;
}

static double span(const struct timespec *a, const struct timespec *b) {
    return (b->tv_sec - a->tv_sec) + (b->tv_nsec - a->tv_nsec) / 1e9;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "использование: %s <секунды> <программа> [аргументы...]\n", argv[0]);
        return 2;
    }
    int limit = atoi(argv[1]);
    if (limit < 0) limit = 0;
    pid_t pid = fork();
    if (pid == 0) {
        execvp(argv[2], &argv[2]);
        perror("execvp");
        _exit(127);
    }
    struct timespec start = now_ms();
    int status = 0;
    int timed_out = 0;
    for (;;) {
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid) break;
        if (r < 0) { perror("waitpid"); return 1; }
        struct timespec now = now_ms();
        if (span(&start, &now) >= (double)limit) {
            timed_out = 1;
            kill(pid, SIGTERM);
            for (int i = 0; i < 20; i++) {
                r = waitpid(pid, &status, WNOHANG);
                if (r == pid) break;
                usleep(100000);
            }
            if (r != pid) {
                printf("mytimeout: SIGTERM не помог, применяю SIGKILL\n");
                kill(pid, SIGKILL);
                waitpid(pid, &status, 0);
            }
            break;
        }
        usleep(20000);
    }
    struct timespec endt = now_ms();
    double elapsed = span(&start, &endt);
    if (timed_out) {
        printf("mytimeout: ПРЕВЫШЕНО время %d с (протекло %.2f с); потомок убит\n", limit, elapsed);
        if (WIFEXITED(status))
            printf("mytimeout: потомок pid=%d код=%d\n", (int)pid, WEXITSTATUS(status));
        else if (WIFSIGNALED(status))
            printf("mytimeout: потомок pid=%d сигнал=%d\n", (int)pid, WTERMSIG(status));
    } else {
        if (WIFEXITED(status))
            printf("mytimeout: штатное завершение pid=%d код=%d за %.2f с\n",
                   (int)pid, WEXITSTATUS(status), elapsed);
        else if (WIFSIGNALED(status))
            printf("mytimeout: pid=%d завершён сигналом %d за %.2f с\n",
                   (int)pid, WTERMSIG(status), elapsed);
    }
    return 0;
}
```

#### 2.5.4 safelaunch.c

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>

static int allowed(const char *name) {
    const char *ok[] = { "./childinfo", "./pinfo", "./myrun", "./signalwatch", "./fifo_reader" };
    size_t i;
    for (i = 0; i < sizeof(ok) / sizeof(ok[0]); i++)
        if (strcmp(name, ok[i]) == 0) return 1;
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "использование: %s <разрешённая_программа> [аргументы...]\n", argv[0]);
        return 2;
    }
    const char *prog = argv[1];
    if (!allowed(prog)) {
        fprintf(stderr, "safe-launch: программа %s не в списке разрешённых\n", prog);
        return 1;
    }
    int devnull = open("/dev/null", O_RDWR);
    if (devnull >= 0) {
        dup2(devnull, 0);
        for (int fd = 3; fd < 64; fd++) close(fd);
        close(devnull);
    }
    char *envp[] = { "PATH=/usr/bin:/bin", "PWD=default", NULL };
    char *args[64];
    int i;
    for (i = 0; argv[i] && i < 63; i++) args[i] = argv[i];
    args[i] = NULL;
    execve(prog, args, envp);
    perror("execve");
    return 126;
}
```

#### 2.5.5 mypmap.c

```c
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
```

#### 2.5.6 procaudit.c

```c
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
```

#### 2.5.6 procaudit_test.c

```c
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv, char **envp) {
    char *fake = (argc > 1) ? argv[1] : "spoofed-name";
    char *prog = (argc > 2) ? argv[2] : "/bin/sleep";
    char *args[64];
    int n = 0, i;
    args[n++] = fake;
    if (argc > 3) {
        for (i = 3; argv[i] && n < 63; i++) args[n++] = argv[i];
    } else {
        args[n++] = "120";
    }
    args[n] = NULL;
    printf("procaudit_test: execve(%s), argv[0]=%s (подмена имени)\n", prog, fake);
    fflush(stdout);
    execve(prog, args, envp);
    perror("execve");
    return 127;
}
```

### Makefile

```make
CC?=gcc
CFLAGS?=-O2 -Wall

PROGS = pinfo forkdemo fork3 launcher childinfo signalwatch pipedemo \
        fifo_writer fifo_reader shm_writer shm_reader cow zombie orphan \
        threads myps myrun mytimeout safelaunch mypmap procaudit procaudit_test

all: $(PROGS)

%: %.c
	$(CC) $(CFLAGS) -o $@ $<

threads: threads.c
	$(CC) $(CFLAGS) -o $@ threads.c -pthread

clean:
	rm -f $(PROGS)
```