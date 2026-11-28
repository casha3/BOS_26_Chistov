# 3. Сборка ядра: рекомендации ИСП РАН + mlx4

## Состав конфигурации

Ядро собирается из трёх фрагментов (см. `kernel/`):

1. `syzkaller.fragment` — минимум для фаззера:
   `KCOV`, `KCOV_INSTRUMENT_ALL`, `KCOV_ENABLE_COMPARISONS`, `DEBUG_FS`,
   `KASAN`, `DEBUG_INFO`, `KALLSYMS_ALL`, namespaces/cgroups,
   `CONFIGFS_FS`, `SECURITYFS`, fault injection.
2. `lvc.fragment` — дословный перенос списка `./scripts/config` со страницы
   <https://portal.linuxtesting.ru/LVCFuzzingKernelOptions.html>:
   `LOCKDEP`/`PROVE_LOCKING`/`DEBUG_ATOMIC_SLEEP`/`DEBUG_VM`, `DEBUG_KMEMLEAK`,
   `DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT`, `UNWINDER_ORC`, `UBSAN` (в объёме
   методики), отключение `DEVMEM`/`DEVKMEM`/`DEVPORT`/`UPROBE_EVENTS`,
   `CONFIG_CMDLINE` с `panic_on_warn=1` и т.д.
3. `mlx4.fragment` — цель:
   `CONFIG_MLX4_CORE=y`, `CONFIG_MLX4_EN=y`, `CONFIG_MLX4_INFINIBAND=n`,
   `CONFIG_E1000=y` (NIC syzkaller), `CONFIG_ATA_PIIX=y` (диск /dev/sda),
   devlink, ext4, devtmpfs.

## Почему так

* **Драйверы =y, не =m.** Иначе нужен initramfs с модулями; встроенные
  драйверы упрощают образ и гарантируют, что `eth1/eth2` появятся до userspace.
* **`CONFIG_CMDLINE` из методики** уже содержит `root=/dev/sda console=ttyS0
  net.ifnames=0 panic_on_warn=1` — совпадает с тем, как syzkaller грузит VM.
* **`DEBUG_INFO_BTF=n`** — критично для памяти: генерация BTF (`pahole`)
  съедает несколько ГБ и не нужна syzkaller.
* **`RANDOMIZE_BASE=n`** — иначе KCOV-адреса «плывут» относительно `vmlinux`.
* **`KASAN`** нужен, чтобы падения были воспроизводимыми и осмысленными
  (use-after-free/OOB), а не «повезло/не повезло».

## Проверки после слияния

Скрипт `02_build_kernel.sh` проверяет наличие ключевых символов и падает,
если `KCOV`, `KASAN`, `MLX4_CORE`, `MLX4_EN` не включились (бывает, если
фрагмент не применился из-за зависимостей).

## Сборка

```bash
bash 02_build_kernel.sh            # -j4 по умолчанию
JOBS=2 bash 02_build_kernel.sh     # для 4 ГБ RAM
```

Артефакты:

* `work/linux-<ver>/arch/x86/boot/bzImage` — то, что грузит QEMU;
* `work/linux-<ver>/vmlinux` — символизация и coverage (`kernel_obj`);
* `work/kernel.config` — итоговый .config;
* `work/logs/kernel_build.log` — журнал.

## Ожидаемое время и память

| vCPU | Время | Пик RAM |
|---|---|---|
| 4 | 60–100 мин | ~3 ГБ |
| 8 | 40–70 мин | ~5–6 ГБ при `-j4` |

Для повторных сборок полезен `ccache` (`CC="ccache gcc"`), но первая сборка
всё равно долгая.

## Известные отличия от методики

* Секция «отключение мусорных опций» на странице ИСП РАН не содержит
  машинно-читаемого списка (в тексте только обоснование), поэтому мы
  ограничились отключением DRM/SOUND и того, что перечислено в
  «Добавлении отладочных опций».
* `DEBUG_KMEMLEAK_MEM_POOL_SIZE` оставлен 16000 как в методике; при нехватке
  RAM можно уменьшить до 4000 (документировано в README).
