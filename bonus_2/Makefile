LINUX_VERSION := $(shell . tools/versions.env 2>/dev/null && echo $$LINUX_VERSION)
QEMU_VERSION  := $(shell . tools/versions.env 2>/dev/null && echo $$QEMU_VERSION)

HELP_TARGETS := help deps sources kernel qemu image syzkaller corpus run report analyze check status clean void

.DEFAULT_GOAL := help
SHELL := /bin/bash

help:
	@echo "bonus_2: syzkaller + эмуляция Mellanox ConnectX-3 (mlx4)"
	@echo
	@echo "Фазы (запускайте по очереди):"
	@echo "  make deps       # 00: зависимости (brew / dnf)"
	@echo "  make sources    # 01: скачать linux-$(LINUX_VERSION), qemu-$(QEMU_VERSION), syzkaller"
	@echo "  make kernel     # 02: собрать ядро (только Linux)"
	@echo "  make qemu       # 03: собрать QEMU с устройством mlx4"
	@echo "  make image      # 04: rootfs + SSH-ключ (только Linux)"
	@echo "  make syzkaller  # 05: собрать syzkaller + syzlang"
	@echo "  make corpus     # 06: seeds -> corpus.db (проверка описаний)"
	@echo "  make run        # 07: syz-manager + дашборд :56741 (только Linux)"
	@echo "  make report     # 08: данные прогона -> results/runs/<id>/"
	@echo "  make analyze    # 09: пересобрать CSV/JSON из готового прогона"
	@echo
	@echo "  make check      # быстрая проверка без Linux: QEMU-устройство + syzlang"
	@echo "  make void       # всё одной командой на Void Linux (run_void_linux.sh all)"
	@echo "  make status     # что уже собрано"
	@echo "  make clean      # удалить work/ (исходники и результаты сборки)"

deps:
	bash 00_install_deps.sh

sources:
	bash 01_fetch_sources.sh

kernel:
	bash 02_build_kernel.sh

qemu:
	bash 03_build_qemu_mlx4.sh

image:
	bash 04_build_image.sh

syzkaller:
	bash 05_build_syzkaller.sh

corpus:
	bash 06_prepare_corpus.sh

run:
	bash 07_run_manager.sh

report:
	bash 08_collect_report.sh

analyze:
	bash 09_analyze.sh

check:
	bash tools/check_device.sh
	bash 06_prepare_corpus.sh

status: tools/status.sh
	bash tools/status.sh

void:
	./run_void_linux.sh all

clean:
	rm -rf work
	@echo "work/ удалён"

# Короткие алиасы: make 0 ... make 8
0:
	bash 00_install_deps.sh
1:
	bash 01_fetch_sources.sh
2:
	bash 02_build_kernel.sh
3:
	bash 03_build_qemu_mlx4.sh
4:
	bash 04_build_image.sh
5:
	bash 05_build_syzkaller.sh
6:
	bash 06_prepare_corpus.sh
7:
	bash 07_run_manager.sh
8:
	bash 08_collect_report.sh
9:
	bash 09_analyze.sh

.PHONY: $(HELP_TARGETS) 0 1 2 3 4 5 6 7 8 9
