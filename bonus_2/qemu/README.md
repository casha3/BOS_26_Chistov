# Модель Mellanox ConnectX-3 для QEMU

В этом каталоге — исходник собственной модели PCI-устройства:

* `hw/net/mlx4.c` — QOM-устройство `mlx4` (vendor `15b3`, device `1003`),
  реализующее HCR-интерфейс прошивки, BAR0 (DCS), BAR2 (UAR), EQ/EQE,
  INTx и опционально MSI-X.

## Как модель попадает в QEMU

Апстрим-патча не существует, поэтому `03_build_qemu_mlx4.sh`:

1. копирует `hw/net/mlx4.c` в дерево `work/qemu-<ver>/hw/net/`;
2. добавляет строку в `hw/net/meson.build`:
   `system_ss.add(when: 'CONFIG_MLX4_PCI', if_true: files('mlx4.c'))`;
3. добавляет `config MLX4_PCI` в `hw/net/Kconfig`.

Проверено на QEMU 11.1.3. Для другой версии достаточно, чтобы структура
`hw/net/meson.build`/`Kconfig` была такой же (в 10.x/11.x она одинаковая).

Если вы ведёте QEMU как git-репозиторий, патч можно получить так:

```bash
cd work/qemu-11.1.3
git add -N hw/net/mlx4.c
git diff > ../../qemu-mlx4.patch
```

## Запуск

```bash
qemu-system-x86_64 -M q35 -device mlx4,ports=2,verbose=on ...
```

Свойства: `ports`, `mac`, `msix`, `evil`, `verbose` (см. `docs/04_qemu_emulation.md`).
