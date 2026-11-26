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

PoC-запуск: `.\run-poc.ps1` створює AVD у `C:\mulka-poc\avd` для локальної копії образу в `C:\mulka-poc\sdk` (лише для тестів, не розповсюджувати), запускає наш `emulator.exe` з WHPX і чекає `sys.boot_completed` через `adb`.

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
- [x] Запуск образу API 34 через WHPX (`run-poc.ps1`: Android 14 `google_apis` x86_64, холодне завантаження 72 с, `qemu-system-x86_64` ~3,5 ГБ RAM при `hw.ramSize=2048`, мережа з гостя працює)
- [x] Перевірити `-http-proxy` і `-dns-server` з локальним шлюзом — див. нижче: TCP і DNS ідуть через шлюз, **UDP і ICMP — ні**
- [x] Два інстанси одночасно, кожен через свій шлюз (`two-instances.ps1`) — див. «Два інстанси»
- [x] Те саме з двома реальними upstream-проксі: інстанси показують різні IP (критерій приймання фази 0)

## Перевірка мережі (2026-11-25)

`poc-gateway.py` (тимчасовий шлюз на stdlib: HTTP CONNECT на `127.0.0.1:18080`, DNS на `127.0.1.1:53`, адресація з ADR-0004 для N=0) + `.\run-poc.ps1 -HttpProxy http://127.0.0.1:18080 -DnsServer 127.0.1.1`. За ~4 хв роботи образу: 470 CONNECT, 7 plain-HTTP GET, 294 DNS-запити — увесь системний трафік (connectivity check, Play-сервіси, реклама в застосунках) пройшов через шлюз.

| Трафік гостя | Шлях | Висновок |
| --- | --- | --- |
| TCP будь-який порт | `CONNECT host:port` на проксі (порт 80 — `GET http://…`) | ✅ контрольований |
| DNS (UDP 53 на 10.0.2.3) | `qemu` пересилає на `-dns-server` | ✅ контрольований |
| Інший UDP (QUIC, NTP, WebRTC) | NAT `qemu` напряму з IP хоста — датаграма з гостя дійшла до сокета на LAN-адресі хоста, шлюз її не бачив | ❌ **витік** |
| ICMP (`ping 8.8.8.8`) | напряму з хоста, 0% втрат | ❌ **витік** |

Наслідки для форку і шлюзу:

1. **Патч емулятора:** коли задано проксі, slirp має відкидати UDP (крім DNS на 10.0.2.3) і ICMP — або віддавати UDP у шлюз (SOCKS5 UDP ASSOCIATE). Без цього QUIC/WebRTC показують реальну IP хоста.
2. **Шлюз має відмовляти в CONNECT на loopback/приватні адреси:** гість сам спробував `CONNECT 127.0.1.1:853` і `10.0.2.3:853` (Android Private DNS у режимі opportunistic) — без фільтра проксі відкриває гостю сервіси хоста.
3. **IPv6:** гість отримує AAAA і спершу пробує `CONNECT [v6]:443` (320 відмов `WSAENETUNREACH` на хості без IPv6), потім іде на IPv4. Шлюз має швидко відмовляти або фільтрувати AAAA за політикою вихідного вузла.
4. Порт 53 на `0.0.0.0` займає служба Windows SharedAccess (ICS), але bind на `127.0.1.1:53` працює без прав адміністратора — схема ADR-0004 підтверджена.

### Патч slirp: fail-closed egress (2026-11-25)

Коли задано `-http-proxy`, slirp більше не відкриває прямих з'єднань з адреси хоста: UDP і TCP, який проксі не взяв, дозволені лише на loopback хоста (10.0.2.2, loopback `-dns-server`) і на DNS-сервер гостя (10.0.2.3+, порт 53); ICMP echo назовні відкидається. UDP отримує ICMP unreachable — QUIC одразу падає на TCP; відхилений TCP — RST.

- `patches/external-qemu/0002-slirp-fail-closed-egress-with-proxy.patch` — `external/qemu/slirp` (мережа `eth0`, вбудована в `qemu-system-*`).
- `patches/external-libslirp/0001-fail-closed-egress-with-proxy.patch` — `external/libslirp`, та сама логіка. **Зараз не діє:** libslirp використовує лише netsim, а `netsimd.exe` береться готовим з `prebuilts/android-emulator-build/common/netsim` (`-- Using prebuilt netsim binaries`). Патч лишається на випадок збірки netsim з вихідників.

**Wi-Fi.** В образі API 34 типовий маршрут іде через `wlan0` (virtio-wifi), а його трафік обробляє окремий процес `netsimd.exe` зі своїм slirp і своїм HTTP-проксі — TCP і DNS там ідуть через шлюз, але UDP виходить напряму, і наш патч на це не впливає. Тому інстанси Mulka запускаються з `-feature -VirtioWifi` (`run-poc.ps1 -NoWifi`): гість бачить лише `eth0` (мобільна мережа, VALIDATED), увесь трафік проходить через пропатчений slirp. Відкрите питання — зібрати netsim з вихідників або лишити гостя без Wi-Fi.

`.\leak-test.ps1` (типово без Wi-Fi) — автоматична перевірка, код виходу = кількість провалів:

| Перевірка | Wi-Fi через netsim (`-WithWifi`), з патчем чи без | З патчем, лише `eth0` |
| --- | --- | --- |
| TCP через шлюз (CONNECT) | PASS | PASS |
| UDP не виходить напряму | **FAIL** | PASS |
| ICMP не виходить напряму | **FAIL** | PASS |
| DNS через шлюз | PASS | PASS |
| HTTP через шлюз | PASS | PASS |

Контроль: той самий `eth0` без `-http-proxy` — UDP від гостя доходить до сокета на LAN-адресі хоста, тобто блокує саме патч. ICMP через вбудований slirp на Windows не пересилається взагалі (сокет `IPPROTO_ICMP` недоступний), назовні його пропускав лише netsim.

## Два інстанси (2026-11-26)

`.\two-instances.ps1 [-Proxy0 http://[user:pass@]host:port] [-Proxy1 ...]` запускає `poc-gateway.py --instance 0/1` і два AVD (`poc34-0` на 5554, `poc34-1` на 5556, `hw.ramSize=1536`, без вікна й без Wi-Fi). Потім кожен гість запитує `http://api.ipify.org/?mulka=N` і має отримати IP свого проксі; мітка `mulka=N` має з'явитися лише в лозі шлюзу N. `poc-gateway.py --upstream-proxy` пускає весь TCP шлюзу через HTTP-проксі (CONNECT, Basic-авторизація). Код виходу дорівнює кількості провалів.

Прогін без upstream-проксі (обидва шлюзи виходять напряму): 7/7 PASS. Завантаження зайняло 41 с і 57 с, обидва гості бачать IP хоста, трафік кожного йде лише через свій шлюз. Перевірку різних IP пропущено, бо для неї потрібні два реальні проксі.

Прогін із двома upstream-проксі (HTTP, Basic-авторизація): 6/8 PASS. Інстанс 1 показав IP свого проксі (`64.137.96.74`). Перевірки для інстансу 0 провалилися: до його проксі (`45.38.107.97:6014`) не встановлюється TCP-з'єднання навіть із хоста (curl чекав 20 с і впав за таймаутом), тож проблема в проксі, а не в емуляторі. Ізоляція спрацювала правильно: при мертвому upstream інстанс 0 лишився без мережі й не перейшов ні на прямий вихід, ні на чужий шлюз.

Повторний прогін із робочою парою (`198.23.243.226:6361` і `64.137.96.74:6641`): **8/8 PASS, критерій приймання фази 0 виконано.** Інстанс 0 показує `198.23.243.226`, інстанс 1 — `64.137.96.74`; завантаження зайняло 35 с і 57 с, і трафік кожного гостя йде лише через свій шлюз.

Під час першого прогону на щойно створеному AVD `poc34-1` гість за 2 хв після `sys.boot_completed` не надіслав у шлюз жодного запиту. Окремо і в парі з `poc34-0` цей AVD потім працював нормально, тому зараз скрипт чекає мережу до 240 с, а якщо не дочекався, ставить FAIL і виводить `ip addr`/`dumpsys connectivity` гостя. Відкрите питання: чи відтворюється це на першому завантаженні при нестачі RAM (на хості було вільно ~6 ГБ із 12).
