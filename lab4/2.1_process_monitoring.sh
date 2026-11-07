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