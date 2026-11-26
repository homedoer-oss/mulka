# images — AOSP-образи

Збірка системних образів AOSP у Docker на Linux-білд-сервері (ТЗ, розділи 2 і 7, фаза 1).

- Цілі: `sdk_phone64_x86_64` або еквівалент для старших гілок; тип збірки `userdebug`; без GMS.
- Версії: API 28, 30, 32, 33, 34, 35, 36.
- Офіційні образи Google не розповсюджуються (ліцензія Android SDK).

Фаза 0: один образ API 34, зібраний вручну (`build-aosp.sh`). CI-конвеєр — фаза 1.

## Фаза 0: образ API 34

| Параметр | Значення |
| --- | --- |
| Тег AOSP | `android-14.0.0_r75` — останній тег Android 14 (QPR3) станом на 2026-11-26 |
| `lunch` | `sdk_phone64_x86_64-ap2a-userdebug` (з QPR2 `lunch` вимагає release config; у r75 це `ap2a`) |
| Продукт | `device/generic/goldfish/64bitonly/product/sdk_phone64_x86_64.mk`, `PRODUCT_DEVICE=emu64x` |
| Артефакт | `m emu_img_zip` → `out/target/product/emu64x/sdk-repo-linux-system-images.zip` |
| Результат скрипта | `images/out/mulka-aosp-34-x86_64-android-14.0.0_r75.zip` + `.sha256` + `build.prop`, лог збірки |
| Фіксація дерева | `images/manifests/android-14.0.0_r75.pinned.xml` (комітиться) |

### Вимоги до машини (один образ)

| | Мінімум | Рекомендовано | Чому |
| --- | --- | --- | --- |
| ОС | Linux x86_64 з Docker Engine або Ubuntu 22.04 без Docker | Ubuntu 22.04/24.04 | AOSP збирається лише на Linux; Docker дає однакове середовище і готує фазу 1 |
| CPU | 8 потоків | 16+ потоків | Час першої збірки приблизно обернено пропорційний кількості ядер |
| RAM | 32 ГБ разом зі swap | 64 ГБ | Лінкування і Soong/Metalava забирають до ~2 ГБ на потік; скрипт сам обмежує `-j` до RAM/2 |
| Диск | 300 ГБ вільно, SSD | 400 ГБ NVMe | Дерево `--depth=1` ~100–150 ГБ + `out/` ~150–200 ГБ; на HDD збірка в рази повільніша |
| ФС | ext4/xfs | ext4 | Потрібна чутлива до регістру ФС: NTFS і `/mnt/c` у WSL не підходять |
| Мережа | ~100 ГБ завантаження з `android.googlesource.com` | канал ≥ 100 Мбіт/с | Перший `repo sync` |

Цифри обсягу і часу взято з [вимог AOSP](https://source.android.com/docs/setup/start/requirements) і досвіду збірок, на наших машинах їх ще не заміряли: після першої збірки треба внести фактичні значення сюди. Орієнтовно на 16 потоках і 64 ГБ RAM перша збірка займає 2–4 год плюс синхронізація; повторна, без `out/clean`, займає десятки хвилин.

Поточний робочий ноутбук (i5-8250U, 12 ГБ RAM) не підходить ні за RAM, ні за диском. Варіанти:

- **Хмарна VM на кілька годин:** 16 vCPU, 64 ГБ RAM, 500 ГБ SSD, Ubuntu 22.04. Після збірки лишаємо диск (знімок), щоб повторні збірки були інкрементальними, а VM видаляємо.
- **Власна машина або сервер:** той самий профіль. Згодом стане білд-сервером фази 1, для якого потрібно ≥ 32 ядра, 128 ГБ RAM і 2 ТБ NVMe під 7 образів і ccache.
- **WSL2 на іншій Windows-машині:** працює, якщо в `.wslconfig` виділено ≥ 32 ГБ пам'яті, а дерево лежить на ext4-диску WSL, а не в `/mnt/c`.

### Порядок дій

```bash
# на Linux-машині, з клону репозиторію
cd images
./build-aosp.sh --check                      # лише перевірка машини, нічого не змінює
sudo mkdir -p /srv/aosp && sudo chown "$USER" /srv/aosp
./build-aosp.sh                              # Docker; або --no-docker на Ubuntu 22.04 з пакетами з docker/Dockerfile
```

Потім скопіювати `out/mulka-aosp-34-x86_64-android-14.0.0_r75.zip` і `.sha256` на Windows і виконати:

```powershell
.\images\install-image.ps1 -Zip <шлях до zip>       # перевіряє SHA-256, ставить у C:\mulka-poc\sdk\...\android-34\aosp\x86_64
.\emulator\run-poc.ps1 -Tag aosp -Name aosp34 -NoWifi
```

Після цього треба повторити на образі `aosp` обидва скрипти: `emulator\leak-test.ps1 -Tag aosp` і `emulator\two-instances.ps1 -Tag aosp -Proxy0 … -Proxy1 …`. Для кожного образу вони створюють окремі AVD (`poc34-aosp…`), тож userdata від `google_apis` не підхоплюється.

Скрипт перезапускається безпечно: наявний `.repo` не ініціалізується заново, `repo sync` докачує лише зміни, а збірка інкрементальна. Інші параметри: `--jobs`, `--sync-jobs`, `--src`, `--tag`, `--release`, `--variant` (див. `./build-aosp.sh --help`).

### Що перевірити на першому образі

- Емулятор `emu-main-dev` (37.3.10) завантажує образ Android 14 AOSP. Ризик — несумісність goldfish/ranchu: модулі ядра з `kernel/prebuilts` і `vendor.img`.
- Холодний старт без GMS швидший, ніж на `google_apis` (там 35–57 с, ціль NFR-02 — ≤ 40 с).
- Розмір образу і RAM процесу `qemu-system` при `hw.ramSize=2048` (на `google_apis` це ~3,5 ГБ).
- Без Play-сервісів connectivity check іде на `connectivitycheck.gstatic.com`, як і раніше. Для приватності (NFR-08) його URL потім треба буде замінити оверлеєм.
