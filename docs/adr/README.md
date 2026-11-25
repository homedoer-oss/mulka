# Architecture Decision Records

Кожне архітектурне рішення — окремий файл `NNNN-коротка-назва.md` за шаблоном [0000-template.md](0000-template.md). Прийняте рішення не редагують, а замінюють новим ADR зі статусом «Замінює ADR-NNNN».

| ADR | Рішення | Статус |
| --- | --- | --- |
| [0001](0001-base-on-android-emulator-fork.md) | Основа — форк Android Emulator (QEMU) + власні AOSP-образи | Прийнято |
| [0002](0002-technology-stack.md) | Стек: .NET 10 (даємон, UI, CLI), Rust (шлюз), Kotlin (агент) | Прийнято |
| [0003](0003-net-gateway-engine.md) | Рушій Net Gateway: власний на Rust чи sing-box | Запропоновано |
| [0004](0004-gateway-addressing.md) | Адреси і порти Net Gateway | Прийнято |
