# emulator — форк Android Emulator

Збірка Android Emulator (AOSP `platform/external/qemu`) з вихідників під Windows. Рішення — [ADR-0001](../docs/adr/0001-base-on-android-emulator-fork.md).

Вихідники upstream у репозиторії не зберігаються: `fetch.ps1` викачує їх через `repo` у `C:\e`, а точні коміти фіксуються у `manifest.pinned.xml` (комітиться сюди). Власний форк `external/qemu` з'явиться з першою нашою зміною; до того збираємо upstream як є.

## Порядок дій

| Крок | Команда | Права | Що робить |
| --- | --- | --- | --- |
| 1 | `.\check-prereqs.ps1` | звичайні | Лише перевіряє середовище, нічого не змінює |
| 2 | `.\setup-machine.ps1` | **адміністратор**, один раз | Developer Mode, long paths, компоненти VS (ATL, ATL/MFC, CMake), Windows ADK Deployment Tools, Windows Hypervisor Platform |
| 3 | `.\fetch.ps1` | звичайні | Ставить `repo` у `%LOCALAPPDATA%\mulka-tools`, синхронізує `emu-main-dev` у `C:\e`, пише `manifest.pinned.xml` |
| 4 | `.\build.ps1` | звичайні | `android\rebuild.cmd`, лог у `emulator\out\` |

Відтворити зафіксоване дерево: `.\fetch.ps1 -Pinned`. Синхронізацію можна почати ще до встановлення VS: `.\fetch.ps1 -SkipPrereqCheck`.

Допоміжні файли:

- `local_manifest.xml` — проєкти, які збірці під Windows не потрібні; `fetch.ps1` копіює його в `.repo\local_manifests\`. Зараз там лише `prebuilts/android-emulator-build/system-images`: ~40 ГБ тестових образів Google APIs, на які збірка не посилається і які не можна розповсюджувати.
- `complete-pin.py` — дописує в `manifest.pinned.xml` проєкти, які `repo manifest -r` пропускає (група `notdefault`: prebuilts clang, cmake, ninja, python, bazel для Windows).

## Виміряно (2026-11-25, i5-8250U, 12 ГБ RAM)

| Що | Значення |
| --- | --- |
| Проєктів у дереві (Windows, без `system-images`) | 61 |
| Дерево на диску, `--depth=1` | ~46 ГБ (разом із `system-images` було ~87 ГБ) |
| Найбільші проєкти (git-об'єкти) | `system-images` 21 ГБ (виключено), `common` 3,3 ГБ, `qt` 3,1 ГБ, `clang/host/windows-x86` 1,5 ГБ |
| `repo sync -j4` | процес зупинено через нестачу RAM, але всі проєкти встигли розгорнутися; на 12 ГБ RAM краще `-Jobs 2` |

Скрипти не змінюють глобальний git-конфіг (налаштування `core.symlinks`, `core.longpaths`, `core.autocrlf` передаються лише процесу `repo` через `GIT_CONFIG_*`), TEMP і виключення Defender, і нічого не завантажують зі сторонніх хостів, крім офіційного `repo` від Google.

## Джерела

- [WINDOWS-DEV.md, гілка emu-main-dev](https://android.googlesource.com/platform/external/qemu/+/refs/heads/emu-main-dev/android/docs/WINDOWS-DEV.md) — вимоги і команди збірки
- [android/rebuild.cmd](https://android.googlesource.com/platform/external/qemu/+/refs/heads/emu-main-dev/android/rebuild.cmd) — викликає `python android\build\python\cmake.py --ccache auto`

## Відкриті питання

- ~~Чи знаходить збірка upstream VS Build Tools~~ — ні: `aemu/process/environment.py` викликає `vswhere` без `-products *` і вимагає workload `NativeDesktop`, якого в Build Tools немає. Виправлено патчем `patches/external-qemu/0001-accept-vs-build-tools.patch` (приймає також `VCTools`); `build.ps1` накладає патчі з `patches\` перед збіркою.
- ~~Чи потрібен Windows ADK~~ — так: CMake без `dismapi` лише попереджає, але `emulator-check` (на ньому тримається `emulator -accel-check`) не компілюється без `dismapi.h`. `setup-machine.ps1` ставить ADK Deployment Tools через winget.
- ~~Тривалість збірки~~ — повна збірка з тестами ~1 год 05 хв (11 602 кроки ninja, 923 тести). `build.ps1` за замовчуванням не видаляє `objs\` (upstream-задача `Clean`), тож повторні збірки інкрементальні; `-Clean` — повна, `-SkipTests` — без ctest.
- Тести upstream, що падають на цій машині (2026-11-25), на збірку не впливають:
  - `aemu-gl-init_unittests` (`EmuglConfig.initWithEmuglConfigInit*`) — чекає апаратний GPU-рендерер, отримує `swiftshader`;
  - `tink_test_internal_rsa_util_test` (`RsaUtilTest.FailsOnLargeE`) — поведінка BoringSSL, не наш код;
  - `android-emu-base_unittests` — нестабільний, проходить при повторі.

## Завдання фази 0

- [x] Скрипти перевірки, налаштування, отримання і збірки
- [x] Налаштувати машину (`setup-machine.ps1`)
- [x] Перша синхронізація і `manifest.pinned.xml` (`external/qemu` @ `538bcdea`)
- [x] Успішна збірка `emulator.exe` (37.3.10.0, `objs\distribution\emulator\`, 136 МБ)
- [ ] Запуск образу API 34 через WHPX
- [ ] Перевірити `-http-proxy` і `-dns-server` з локальним шлюзом
