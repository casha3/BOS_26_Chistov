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