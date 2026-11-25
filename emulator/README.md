# emulator — форк Android Emulator

Збірка форку AOSP `platform/external/qemu` під Windows (clang-cl). Рішення — [ADR-0001](../docs/adr/0001-base-on-android-emulator-fork.md).

Вихідний код upstream не зберігається в цьому репозиторії: його викачують скрипти в `emulator/src/` (у `.gitignore`), коміт upstream фіксується в цьому каталозі.

Завдання фази 0:

- [ ] Зафіксувати коміт upstream і задокументувати кроки отримання коду
- [ ] Відтворювана збірка під Windows (скрипт + перелік залежностей)
- [ ] Запуск образу API 34 через WHPX
- [ ] Перевірити `-http-proxy` і `-dns-server` з локальним шлюзом
