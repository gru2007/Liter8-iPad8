# iPad 8 (j171aap, iPadOS 26.7.1 / 23H30) — полная инструкция

От файла IPSW до загруженной системы, твиков и проверки магазина приложений.
Ветка: `claude/quirky-meitner-fjokhj` в `gru2007/Liter8-iPad8`.

> **Внимание.**
> - Шаг 6 (`restore-cfw`) **стирает iPad полностью**. Отката нет.
> - Загрузка привязанная (tethered): iPad стартует только с Mac через pwn DFU,
>   каждый раз.
> - `restore-cfw` получает APTicket у Apple во время восстановления. Если Apple
>   уже не подписывает 23H30 для iPad11,6, восстановление не пройдёт. Проверь
>   подпись (например, на ipsw.me) до начала.
> - Профиль экспериментальный: каждой команде `fw` нужен `--experimental`.

Обозначения ниже: `$B` = `.build/release/liter8`, `$W` = рабочая папка,
`$SRC` = распакованный IPSW внутри неё.

---

## Часть 1. Подготовка Mac (один раз)

### 1.1. Инструменты

macOS 14+, Xcode Command Line Tools со Swift 6, Homebrew.

```sh
brew install \
  sevenzip blacktop/tap/ipsw gnu-tar coreutils zstd ldid-procursus sshpass autoconf automake libtool pkg-config \
  libimobiledevice libimobiledevice-glue libirecovery libusbmuxd libplist libtatsu libzip curl
```

`irecovery` берётся из PATH (его ставит `libirecovery`); `--irecovery` нужен,
только чтобы указать другой бинарник.

### 1.2. iOS SDK

Вспомогательные бинарники для устройства собираются под iPhoneOS SDK. Если
стоит полный Xcode, ничего делать не нужно. Если только Command Line Tools,
нужен распакованный SDK (например, из Theos) и переменная:

```sh
export LITER8_IOS_SDK=/path/to/iPhoneOS.sdk
```

Держи её выставленной во всех следующих шагах (её читают `provision`,
`csprobe`, `personainfo`, `l8localauth`).

### 1.3. Сборка Liter8

```sh
git clone --recurse-submodules -b claude/quirky-meitner-fjokhj https://github.com/gru2007/Liter8-iPad8.git
cd Liter8-iPad8
make setup
make release
B=.build/release/liter8
$B preflight          # проверит, что все инструменты на месте и запускаются
```

Проверка, что новые планы ядра на месте:

```sh
$B 2>&1 | grep -A3 'kernel '
# должно быть: ... ppl-allow-invalid, vm-fault-cs-bypass, vm-map-protect, ... boot-jit ...
$B profiles | grep -A4 ios26-23H30-j171aap
# должна быть строка kernel-codesign-invalid
```

### 1.4. Железо

Твой транспорт usbliter8 для T8020 (`usbliter8ctl` вызывается автоматически,
когда iPad в pwn DFU).

---

## Часть 2. IPSW: распаковка (на Mac, без устройства)

```sh
export W="$PWD/.liter8-ipad8-23H30"
export WORK_DIR="$W"

$B fw prepare --experimental --file /path/to/iPad_10.2_2020_26.7.1_23H30_Restore.ipsw
```

`prepare` читает `BuildManifest.plist` (имя файла неважно), выбирает профиль
`ipad11,6-j171aap-23H30` и распаковывает IPSW в:

```sh
export SRC="$W/iPad11,6_26.7.1_23H30_Restore"
ls "$SRC"/kernelcache.*        # kernelcache.release.ipad11b
```

IPSW общий для Wi-Fi (j171aap) и Cellular (j172aap), но профиль есть только
для j171aap, поэтому `--board` не нужен. Можно указать явно: `--board j171aap`.

---

## Часть 3. Проверки до устройства

Патчи code signing перенесены из palera1n KPF для T8020. На стоковом
kernelcache 23H30 каждый находит ровно одно место, а `boot-jit` даёт 123 записи
(118 из `boot-public` плюс пять). При несовпадении паттерна ничего не
патчится (`no candidate`), но тогда `get-boot` остановится, пока это не
исправить.

### 3.1. Патчи ядра против твоего kernelcache

```sh
$B im4p extract "$SRC/kernelcache.release.ipad11b" kc.raw

$B resolve kernel ppl-allow-invalid  kc.raw
$B resolve kernel vm-fault-cs-bypass kc.raw
$B resolve kernel vm-map-protect     kc.raw
$B resolve kernel boot-jit           kc.raw     # boot-public + три патча выше
$B resolve kernel boot-public        kc.raw     # обычный план, должен давать 118 записей
```

Для каждого:
- **напечатались записи** — паттерн совпал;
- **`no candidate`** — этого варианта нет в ядре. Пришли мне окно
  дизассемблера (ниже), я добавлю нужный вариант;
- **`ambiguous candidate`** — совпадений несколько, пришли смещения.

Окно дизассемблера, если что-то не нашлось:

```sh
# например, для PPL: найти строки вокруг создания pmap и дизассемблировать рядом
$B inspect kc.raw strings pmap_create
$B inspect kc.raw dis <смещение> 80
```

Точные байты закреплены фикстурой
`fixtures/23H30/j171aap/kernel-boot-jit-j171aap-23H30.json` (рядом с
`kernel-boot-public`). Сверить свой kernelcache:

```sh
$B verify fixtures/23H30/j171aap/kernel-boot-jit-j171aap-23H30.json kc.raw
```

### 3.2. Место в заголовках демонов (иначе provisioning остановится)

Upstream при provisioning дописывает weak-load своих библиотек в `coreauthd`,
`lockdownd` и `remotepairingdeviced`. Для этого в заголовке Mach-O нужно
48–56 свободных байт. У launchd на 23H30 их было только 40 (поэтому хук стал
`/usr/lib/lhook`). Проверь заранее на образе системы:

```sh
ipsw mount fs /path/to/iPad_10.2_2020_26.7.1_23H30_Restore.ipsw
# запомни, куда смонтировалось, дальше это $SYS

P=device/launchdhook/patch_launchd.py
python3 $P "$SYS/System/Library/Frameworks/LocalAuthentication.framework/Support/coreauthd" --path /usr/lib/l8coreauth.dylib
python3 $P "$SYS/usr/libexec/lockdownd" --path /usr/lib/l8pair.dylib
python3 $P "$SYS/usr/libexec/remotepairingdeviced" --path /usr/lib/l8remotepairing.dylib
```

Это только отчёт, ничего не пишется. `[+] fits` — всё хорошо. Если где-то
`needs N bytes, only M available` — **пришли вывод до provisioning**, я
укорочу пути так же, как для lhook.

---

## Часть 4. CFW и восстановление (стирает iPad)

```sh
$B fw make-cfw --experimental
```

iPad в pwn DFU, затем:

```sh
$B fw restore-cfw --experimental
```

Проверяет CFW, поднимает локальный TSS-прокси, ловит APTicket
(`$W/apticket.im4m`) и восстанавливает. Ожидаемый финал: `Status: Restore Finished`.

---

## Часть 5. SSH ramdisk и provisioning

iPad снова в pwn DFU:

```sh
$B fw get-rd  --experimental
$B fw boot-rd --experimental
```

Когда iPad в SSHRD:

```sh
$B fw bootstrap      --experimental --check
$B fw bootstrap      --experimental
$B fw prepare-rootfs --experimental
$B fw provision      --experimental --check
$B fw provision      --experimental
$B fw unmount-rootfs --experimental
```

Provisioning ставит в том числе новый `lhook` (инъекция со sandbox-extension)
и модифицированный launchd. Preboot выбирается по APFS-роли (на iPad это
`disk1s5`, а не `disk1s6`).

---

## Часть 6. Обычная загрузка

iPad в pwn DFU:

```sh
$B fw get-boot --experimental
$B fw boot     --experimental
```

**Патчи code signing теперь включены автоматически** для профиля iPad:
`get-boot` сам строит ядро по плану `boot-jit` и пишет в консоль
`kernel plan boot-jit`. Флаг больше не нужен. Это отключает проверку
изменённого кода для всех процессов системы (PPL allow-invalid,
`vm_fault_enter`, `vm_map_protect`).

Два переключателя на случай проблем:
- `$B fw get-boot --experimental --no-tweaks` — ядро без патчей code signing
  (`boot-public`). Это путь восстановления, если с `boot-jit` система не
  грузится, и способ сделать первую «эталонную» загрузку.
- Если в части 3.1 какой-то резолвер дал `no candidate`, `get-boot` без
  `--no-tweaks` остановится с этой ошибкой и ничего не соберёт. Это защита:
  лучше остановиться, чем собрать ядро наполовину.

Совет: в самый первый раз можно загрузиться с `--no-tweaks`, убедиться, что
система стабильна (SSH, SpringBoard, приложения), и только потом пересобрать
без флага. Тогда, если что-то сломается, ты точно знаешь, что виновато ядро.

После загрузки:

```sh
$B fw finalize --experimental --check
$B fw finalize --experimental
$B fw finalize --experimental --check
```

---

## Часть 7. Тесты на устройстве

Дальше всё по SSH на iPad.

### 7.1. Какое ядро загружено

```sh
uname -a                 # должно содержать PATCHED_ARM64_T8020
```

На Mac в `$W/Ramdisk/liter8-boot.json` поле `"kernelPlan"` показывает
`boot-jit` или `boot-public`.

### 7.2. csprobe: работает ли изменение кода

`csprobe` делает ровно то, что делает хук C-функции: делает свою страницу
кода записываемой, переписывает инструкцию и выполняет её.

```sh
# на Mac
sh device/csprobe/build.sh
scp device/csprobe/csprobe root@IPAD:/var/jb/usr/bin/

# на Mac, во втором окне, пока идёт тест
idevicesyslog | grep -iE "CODE ?SIGNING|Invalid Page|cs_invalid|pmap"

# на iPad
/var/jb/usr/bin/csprobe
```

Как читать:
- `[csprobe] PASS` — изменённый код выполнился, ядро готово.
- `FAIL stage1` — `vm_map_protect` не дал RWX.
- `FAIL stage3` — не дал вернуть исполнение после записи.
- процесс убит после `stage1 ... ok` — не сработал `vm_fault_enter` и/или PPL
  allow-invalid. Строка в логе подскажет какой (`pmap` — PPL).

**Пришли вывод csprobe и строки из лога.**

### 7.3. Твики

1. Поставь ElleKit через Sileo (он даёт `/var/jb/usr/lib/TweakLoader.dylib`).
2. Включи инъекцию (lhook перечитывает это при каждом запуске процесса):

```sh
touch /var/jb/.lhook_enabled        # главный выключатель инъекции
touch /var/jb/.lhook_debug          # по желанию: лог инъекции
```

3. Сделай respring и проверь:

```sh
tail -50 /var/jb/tmp/lhook.log      # дошёл ли lhook до процесса
```

4. Проверь два твика: один только с ObjC-хуками, один с хуком C-функции. Если
второй раньше падал, а теперь работает — патчи code signing сделали своё.

Важно: code signing отключён ядром для всех процессов, но инъекция твиков
по-прежнему не идёт в жёстко запрещённые процессы (`launchd`, `amfid`,
`trustd`, `securityd`, `configd`, `notifyd`, `logd`, `opendirectoryd`,
`keybagd`, `watchdogd`, `dropbear`, `sshd`) и в список из
`/var/jb/etc/lhook.deny`. Это защита от незагружаемого устройства, её не
убираем.

### 7.4. Пароль (подтверждения в магазине и не только)

`l8localauth` переводит отказ ACM `-3` (без SEP пароль проверить нечем) в
«пароль не задан», и интерфейс идёт по ветке без пароля. Ставится как твик
ElleKit:

```sh
# на Mac
sh device/localauthfix/build.sh       # на Mac заодно прогонит self-test
scp device/localauthfix/l8localauth.dylib device/localauthfix/l8localauth.plist \
    root@IPAD:/var/jb/usr/lib/TweakInject/

# на iPad: включить (маркер должен принадлежать root; удалить = выключить)
touch /private/var/jb/.liter8-localauth
chmod 600 /private/var/jb/.liter8-localauth
```

Respring и проверь любой запрос пароля. Работает только при включённой
инъекции (7.3).

### 7.5. Магазин приложений

Попробуй установку. Если падает — сними лог на Mac:

```sh
idevicesyslog | grep -iE "LocalAuthentication|ACM|distribution|install|persona|usermanager"
```

Если ошибки пароля больше нет, а установка всё равно не идёт, упираемся в
persona (7.6).

### 7.6. Persona: установка из альтернативных магазинов

Без SEP usermanagerd не создаёт personal persona, поэтому разрешение persona
при установке падает, и installcoordinationd пишет `Client provided invalid
persona for <bundle> : <причина>`. `l8persona` — твик для `installd` и
`installcoordinationd`: если штатное разрешение упало и personal persona нет,
он берёт ветку, которую MobileInstallation использует на Shared iPad
(`CONTAINER_PERSONA_PRIMARY`). Это обход только для установки: «На iPad» в
«Файлах» он не чинит. 7 октября 2026 года на iPad11,6 / 23H30
подтверждена установка AltStore Marketplace после включения этого обхода,
`l8localauth` и изменения eligibility. Это проверка конкретной установки,
а не подтверждение совместимости всех приложений.

```sh
# на Mac (собирает personainfo и l8persona, заодно прогоняет self-test)
sh device/personafix/build.sh
scp device/personafix/l8persona.dylib device/personafix/l8persona.plist \
    root@IPAD:/var/jb/usr/lib/TweakInject/
scp device/personafix/personainfo root@IPAD:/var/jb/usr/bin/

# на iPad: включить (маркер должен принадлежать root; удалить = выключить)
touch /private/var/jb/.liter8-persona
chmod 600 /private/var/jb/.liter8-persona
killall -9 installd installcoordinationd 2>/dev/null   # launchd перезапустит их с твиком
```

Повтори установку и сними лог:

```sh
idevicesyslog | grep -iE "l8persona|persona|installcoordination|installd"
```

`l8persona: installed in pid N` — твик загрузился; `resolved ... to
com.apple.containermanager.primary-persona` — сработал обход.

Повторяемый сценарий для проверенной сборки:

```sh
# На Mac, из корня репозитория. iPad запущен, USB SSH доступен на localhost:2222.
export LITER8_IOS_SDK="$HOME/theos/sdks/iPhoneOS16.5.sdk"
python3 device/marketplacefix/repair.py apply
```

Сценарий собирает твики из исходников, сохраняет исходный eligibility и прежние
твики/маркеры, меняет семь проверенных ответов eligibility и перезапускает только
службы установки и Marketplace. В `l8persona` успешный обход также очищает
`NSError`: предыдущая ошибка не должна остаться после успешного разрешения.
После команды повтори установку с сайта и подтверди её в системном окне.

Подробности и откат: [Marketplace repair](../../device/marketplacefix/README.md).
`repair.py restore /var/jb/var/backups/marketplace-ДАТА-ВРЕМЯ` восстанавливает
состояние из каталога, напечатанного при применении. Перезагрузка не требуется.

Состояние persona (только читает):

```sh
/var/jb/usr/bin/personainfo
cat /var/logs/usermanagerd_init.log /var/logs/usermanagerd.log
ls -la /private/var/keybags/
```

Вывод этих трёх команд нужен для настоящего исправления persona в
usermanagerd.

---

## Часть 8. Откат

| Что выключить | Как |
| --- | --- |
| Патчи code signing | `fw get-boot --experimental --no-tweaks`, затем `fw boot` |
| Инъекцию твиков | `rm /var/jb/.lhook_enabled` |
| Фикс пароля | `rm /private/var/jb/.liter8-localauth` |
| Обход persona при установке | `rm /private/var/jb/.liter8-persona` |
| Лог инъекции | `rm /var/jb/.lhook_debug` |

---

## Что прислать мне

1. Вывод трёх проверок заголовков из части 3.2.
2. Вывод `csprobe` и строки `idevicesyslog` (часть 7.2).
3. Лог попытки установки магазина (часть 7.5).
4. Лог установки с `l8persona`, вывод `personainfo` и логи usermanagerd (часть 7.6).
