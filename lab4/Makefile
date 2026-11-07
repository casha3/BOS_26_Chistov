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