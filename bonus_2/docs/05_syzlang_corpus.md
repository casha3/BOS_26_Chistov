# 5. syzlang-описания и входной корпус

## Что добавлено

`sys/linux/dev_mlx4.txt` (устанавливается скриптом 05):

* `mlx4_devnames = "eth0", "eth1", "eth2"` — имена, которые получают порты
  mlx4 в зависимости от порядка PCI-устройств;
* `mlx4_ifreq_t[ELEM]` — `ifreq` с фиксированным списком имён;
* ioctl-обёртки:

| Вызов | Путь в драйвере |
|---|---|
| `ioctl$sock_SIOCETHTOOL_mlx4` | `mlx4_en_ethtool_ops` |
| `ioctl$sock_SIOCSIFMTU_mlx4` | `mlx4_en_change_mtu` |
| `ioctl$sock_SIOCSIFHWADDR_mlx4` | `mlx4_en_set_mac` |
| `ioctl$sock_SIOCSIFFLAGS_mlx4` | `mlx4_en_open`/`mlx4_en_close` |
| `ioctl$sock_SIOCADDMULTI_mlx4` / `SIOCDELMULTI_mlx4` | `mlx4_en_set_rx_mode` |
| `ioctl$sock_SIOCSIFTXQLEN_mlx4` | tx queue length |

Штатные описания syzkaller (`ioctl$sock_SIOCETHTOOL`, ethtool netlink,
devlink) продолжают работать — наши вызовы лишь гарантируют, что запрос
попадёт именно в mlx4-порт, а не в e1000/virtio.

## Входной корпус

`syzlang/seeds/*.prog` — 6 программ:

* `mlx4_ethtool.prog` — GDRVINFO/GLINK/COALESCE/RINGPARAM;
* `mlx4_mtu.prog` — граничные MTU;
* `mlx4_flags.prog` — open/stop;
* `mlx4_mac.prog` — смена MAC и multicast;
* `mlx4_mixed.prog` — комбинация;
* `generic_ethtool.prog` — контрольный вход через штатное описание.

Корпус упаковывается в `work/manager/corpus.db`:

```bash
bash 06_prepare_corpus.sh
```

`syz-db pack` одновременно является проверкой: если описание или seed
некорректны, он падает с указанием файла/строки. Это же можно использовать
как быстрый `make check` на macOS (Go + syz-db, без Linux).

## Как расширять

1. Добавьте вызов в `syzlang/dev_mlx4.txt` (типы из `socket.txt` доступны).
2. Пересоберите корпус: `bash 06_prepare_corpus.sh`.
3. Убедитесь, что новые вызовы видны менеджеру: дашборд → `corpus`.
4. Если нужен новый тип структуры — опишите его в этом же файле
   (уникальные имена, чтобы не конфликтовать со штатными).

## Ограничения

* `ethtool_cmd_u` покрывает legacy ioctl; netlink-ethtool и devlink идут
  через штатные описания syzkaller.
* Список имён — статический; если в вашей сборке mlx4 получил другое имя
  (например, `eth3`), добавьте его в `mlx4_devnames`.
