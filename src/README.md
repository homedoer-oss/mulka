# src — .NET-компоненти

Рішення: `Mulka.slnx` у корені репозиторію. Ціль — .NET 10 LTS (ТЗ, розділ 5.1).

| Проєкт | Що це | Розділ ТЗ |
| --- | --- | --- |
| `Mulka.Contracts` | Спільні моделі і gRPC-контракти даємона | 5 |
| `Mulka.Daemon` | Instance Daemon: служба Windows, реєстр SQLite, порти, Job Objects | 5, 5.2 |
| `Mulka.Manager` | UI менеджера (WPF, MVVM) | 4, 5.1 |
| `Mulka.Cli` | CLI `droidctl` (збирається як `droidctl.exe`) | 3.5 |

UI і CLI — лише клієнти даємона; вони не запускають емулятор напряму.
