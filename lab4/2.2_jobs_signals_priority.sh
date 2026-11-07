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