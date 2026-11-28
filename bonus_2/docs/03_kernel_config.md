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

## Сверка с методикой ИСП РАН и особенностями 7.3.6

Список `./scripts/config` со страницы перенесён полностью, но часть опций в
7.x уже отсутствует. Чтобы не создавать иллюзию применения, они заменены или
явно отмечены комментариями в `kernel/lvc.fragment`:

| Опция методики | Что в 7.3.6 |
|---|---|
| `DEVKMEM` | удалена из ядра |
| `DEBUG_INFO_COMPRESSED` | choice → `CONFIG_DEBUG_INFO_COMPRESSED_NONE=y` |
| `UBSAN_SANITIZE_ALL` | удалена; проверки включаются потиповыми опциями |
| `UBSAN_MISC` | удалена |
| `UBSAN_OBJECT_SIZE` | удалена |
| `UBSAN_SIGNED_OVERFLOW` / `UBSAN_UNSIGNED_OVERFLOW` | заменены на `UBSAN_INTEGER_WRAP`, который `depends on BROKEN` |

Остальные опции (KASAN/KCOV/LOCKDEP/PROVE_*/DEBUG_VM/KMEMLEAK/DEBUG_INFO/
UBSAN_BOUNDS/UBSAN_SHIFT, отключения DEVMEM/DEVPORT/UPROBE_EVENTS и т.д.)
применяются как в методике.

### Базовая конфигурация

Методика рекомендует брать за основу production-конфиг. Поддерживается:

```bash
BASE_CONFIG=/boot/config-$(uname -r) bash 02_build_kernel.sh
```

Без `BASE_CONFIG` используется `make defconfig` + `kvm_guest.config`
(воспроизводимо, но это не production-конфиг дистрибутива).

### Дополнительные опции для mlx4

`kernel/mlx4.fragment` дополнен:

* `CONFIG_NETDEVICES=y`, `CONFIG_ETHERNET=y` — без них `MLX4_EN` не виден
  (зависимость `PCI && NETDEVICES && ETHERNET && INET`);
* `CONFIG_IPV6=y` вместо ошибочного `CONFIG_INET6`;
* `CONFIG_DCB=y`, `CONFIG_MLX4_EN_DCB=y` — DCB-путь mlx4_en
  (rtnetlink/ethtool) как дополнительная поверхность;
* `CONFIG_MLX4_DEBUG=y` — в 7.x это `default y`, prompt только при
  `EXPERT`; вывод активен лишь при `debug_level>0`.

## Проверки после слияния

Скрипт `02_build_kernel.sh`:

* падает, если не применились критичные символы (`KCOV`, `KASAN`,
  `DEBUG_INFO`, `MLX4_CORE/EN`, `NETDEVICES`, `ETHERNET`, `IPV6`, `DCB`,
  `MLX4_EN_DCB`, ...);
* сверяет **все** символы из трёх фрагментов с итоговым `.config` и печатает
  список неприменившихся (нет в ядре, скрыты зависимостями) в
  `work/logs/fragment_symbols.txt`.

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
