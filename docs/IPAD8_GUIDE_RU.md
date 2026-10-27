# iPad 8 (A12, `j171aap`) — запуск и все функции

Полная инструкция для iPad 8 Wi-Fi (`iPad11,6`, A12 / T8020) на iPadOS 26.7.1
`23H30`: от IPSW до загруженной системы, твиков и диагностики. Описывает ветку
после слияния с upstream (`claude/wizardly-thompson-nc3q8d`).

> **Прочитай до начала**
> - `fw restore-cfw` **полностью стирает iPad**. Отката нет.
> - Загрузка привязанная (tethered): iPad стартует только с Mac через pwn DFU,
>   **каждый раз**.
> - `restore-cfw` получает APTicket у Apple во время восстановления. Если Apple
>   уже не подписывает 23H30 для iPad11,6, восстановление не пройдёт. Проверь
>   подпись (например, на ipsw.me) до начала.
> - Профиль экспериментальный: каждой команде `fw` нужен `--experimental`.
> - Поддерживается только Wi-Fi-модель (`j171aap`, `iPad11,6`). Для Cellular
>   (`j172aap`, `iPad11,7`) есть профиль ядра, но нет профиля устройства:
>   `prepare` его не выберет.

Обозначения: `$B` = `.build/release/liter8`, `$W` = рабочая папка.

---

## 0. Что изменилось после слияния с upstream

Слитая сборка на iPad ещё не загружалась. Ветка `claude/quirky-meitner-fjokhj`
проверена на устройстве; ниже — чем слитая версия от неё отличается и за чем
следить при первом прогоне.

| Что | Было в iPad-ветке | Стало |
| --- | --- | --- |
| План ядра нормальной загрузки | `boot-jit` по умолчанию для iPad, `--tweaks` / `--no-tweaks` | `boot-jit` всегда (upstream), `--tweaks` удалён, `--no-tweaks` остался |
| Состав `boot-jit` на iPad | boot-public + code signing + task-access, метка `TASKAC2` | то же самое; патч ядра exception-port (новый в upstream) для iPad **исключён** профилем |
| Отсутствующая прошивка | всё, кроме RestoreLogo/SEP/trust cache, по наличию | профиль явно разрешает отсутствие SPTM, PMP, WCH; остальное обязательно |
| Шаг provisioning `cellular` (новый в upstream) | не было | на iPad **пропускается автоматически** (у Wi-Fi-модели нет модема) |
| ElleKit | ставился вручную из Sileo | ставится provisioning (`tweaks`) и `fw finalize` из закреплённого `.deb`, если `ellekit.space` доступен |
| `l8localauth`, `l8persona` | из `tweaks.list` | из общего шага `tweaks` (общий код с iPhone); переключатели — по-прежнему из `tweaks.list` |
| Остальные iPad-фиксы (`tweaks.list`) | ставились provisioning'ом | ставит `fw tweaks` после загрузки (или opt-in шаг `fixes` из SSHRD) |
| Включение инъекции | только `fw tweaks` | ещё и автоматически при каждой загрузке (`l8boot`, после `fw finalize`) |
| Иконки rootless-приложений | `l8icons` (твик ElleKit) | `l8icons` **и** `systemhook.dylib`, который `lhook` теперь вставляет сам |
| `restored_external` при восстановлении | 1 запись FDR + 4 записи «нет модема» | только запись FDR (у Wi-Fi iPad модема и так нет) |

Что смотреть при первом прогоне — в разделе 12.

---

## 1. Как выбирается устройство

Отдельного переключателя «iPhone / iPad» нет, и он не нужен:

- `fw prepare` читает `BuildManifest.plist` из IPSW (имя файла не важно) и
  выбирает профиль по точному совпадению версии, сборки, модели, chip ID и
  board ID. IPSW iPad 8 23H30 → профиль `ipad11,6-j171aap-23H30`.
- Этот профиль экспериментальный, поэтому без `--experimental` любая команда
  `fw` откажется работать. Профили iPhone 11 работают без флага.
- IPSW общий для Wi-Fi и Cellular, но профиль есть только для `j171aap`, так
  что `--board` не нужен. Можно указать явно: `--board j171aap`.
- Профиль ядра (`ios26-23H30-j171aap`) выбирается отдельно, по строке XNU
  внутри kernelcache (`xnu-12377.162.13.700.38~2/RELEASE_ARM64_T8020`).

Что профиль iPad делает иначе, чем iPhone:

| | iPhone 11 (`n104ap`) | iPad 8 (`j171aap`) |
| --- | --- | --- |
| SoC / ОС | A13 T8030 / iOS 27 | A12 T8020 / iPadOS 26.7.1 |
| SPTM / TXM / PMP / WCH | есть | нет (разрешено профилем) |
| Сжатие пропатченных IM4P | без сжатия | исходное (LZFSE 0x891 / LZSS) |
| Trust cache нормальной загрузки | RestoreTrustCache | StaticTrustCache |
| Обход инициализации дисплея в iBSS | да | нет |
| Патчи PPL trust cache и code signing | нет | да (opt-in профиля ядра) |
| Патчи task-access, метка `TASKAC2` | нет | да |
| Патч ядра exception-port | да | нет (вместо него твик `l8excport`) |
| Valeria | да | нет (нет каверны на этом ядре) |
| Шаг provisioning `cellular` | да | нет |
| Preboot | `disk1s6` | `disk1s5` (выбирается по APFS-роли) |

---

## 2. Подготовка Mac (один раз)

### 2.1. Инструменты

macOS 14+, Xcode Command Line Tools со Swift 6, Homebrew.

```sh
brew install \
  sevenzip blacktop/tap/ipsw gnu-tar coreutils zstd ldid-procursus sshpass autoconf automake libtool pkg-config \
  libimobiledevice libimobiledevice-glue libirecovery libusbmuxd libplist libtatsu libzip curl
```

`irecovery` берётся из PATH; `--irecovery` нужен, только чтобы указать другой
бинарник. Транспорт usbliter8 для T8020 (`tools/usbliter8ctl`) вызывается
автоматически, когда iPad в pwn DFU.

### 2.2. iOS SDK

Вспомогательные бинарники для устройства собираются под iPhoneOS SDK. С
полным Xcode ничего делать не нужно. С одними Command Line Tools нужен
распакованный SDK (например, из Theos):

```sh
export LITER8_IOS_SDK=/path/to/iPhoneOS.sdk
```

Держи переменную выставленной во всех шагах: её читают `provision`, `tweaks` и
сборка фиксов. Без неё сборка ищет Xcode, затем `~/theos/sdks/iPhoneOS16.5.sdk`.

### 2.3. Сборка Liter8

```sh
git clone --recurse-submodules -b claude/wizardly-thompson-nc3q8d https://github.com/gru2007/Liter8-iPad8.git
cd Liter8-iPad8
make setup        # сабмодули, внешние инструменты, Python venv (нужна сеть)
make release
B=.build/release/liter8
$B preflight      # все ли инструменты на месте и запускаются
$B --version
```

Проверка, что iPad на месте:

```sh
$B profiles | grep -A12 ios26-23H30-j171aap
# ожидаются kernel-ppl-trust-cache, kernel-credential-manager,
# kernel-codesign-invalid, kernel-task-access
```

Желательно прогнать тесты (macOS, Swift):

```sh
make test          # быстрые Swift-тесты
make integration   # CLI, Python-workflow, твики
# с приватными бинарниками 23H30 (см. раздел 3.3):
LITER8_FIXTURE_ROOT=/path/to/private make test-fixtures
```

---

## 3. IPSW и проверки до устройства (без iPad)

### 3.1. Распаковка

```sh
export W="$PWD/.liter8-ipad8-23H30"
export WORK_DIR="$W"

$B fw prepare --experimental --file /path/to/iPad_10.2_2020_26.7.1_23H30_Restore.ipsw
export SRC="$W/iPad11,6_26.7.1_23H30_Restore"
ls "$SRC"/kernelcache.*        # kernelcache.release.ipad11b
```

### 3.2. Патчи ядра против своего kernelcache

```sh
$B im4p extract "$SRC/kernelcache.release.ipad11b" kc.raw
$B profile kc.raw                          # должен назвать ios26-23H30-j171aap

$B resolve kernel ppl-allow-invalid  kc.raw
$B resolve kernel vm-fault-cs-bypass kc.raw
$B resolve kernel vm-map-protect     kc.raw
$B resolve kernel task-access        kc.raw   # 15 записей
$B resolve kernel boot-public        kc.raw   # 118 записей
$B resolve kernel boot-jit           kc.raw   # 138 записей, это то, что грузится
```

- **напечатались записи** — паттерн совпал;
- **`no candidate`** — варианта нет в ядре, `get-boot` остановится;
- **`ambiguous candidate`** — совпадений несколько.

Общий обзор всех планов по распакованной прошивке:

```sh
$B survey "$SRC"
```

Планы, которые профиль iPad не использует (exception-port, Valeria),
отмечаются как `skipped, not used by ios26-23H30-j171aap`, а не как ошибка.

### 3.3. Сверка с фикстурами (самое важное после слияния)

Фикстуры фиксируют точные байты и итоговый хеш. Upstream менял общие
резолверы ядра после переноса iPad-работы, поэтому **это первое, что нужно
проверить**:

```sh
for f in fixtures/23H30/j171aap/kernel-*.json; do
  echo "== $f"; $B verify "$f" kc.raw
done
```

`kernel-boot-jit` и `kernel-boot-public` должны сойтись по количеству записей
и хешу. Если не сошлось — не загружай, пришли вывод.

### 3.4. Место в заголовках демонов

Provisioning дописывает weak-load библиотек в `coreauthd`, `lockdownd` и
`remotepairingdeviced`. Проверь заранее (только отчёт, ничего не пишется):

```sh
ipsw mount fs /path/to/iPad_10.2_2020_26.7.1_23H30_Restore.ipsw   # путь монтирования = $SYS
P=device/launchdhook/patch_launchd.py
python3 $P "$SYS/System/Library/Frameworks/LocalAuthentication.framework/Support/coreauthd" --path /usr/lib/l8coreauth.dylib
python3 $P "$SYS/usr/libexec/lockdownd" --path /usr/lib/l8pair.dylib
python3 $P "$SYS/usr/libexec/remotepairingdeviced" --path /usr/lib/l8remotepairing.dylib
```

`[+] fits` — хорошо. `needs N bytes, only M available` — остановись.

---

## 4. CFW и восстановление (стирает iPad)

```sh
$B fw make-cfw   --experimental
$B fw verify-cfw --experimental     # необязательно, повторная проверка
```

iPad в pwn DFU:

```sh
$B fw restore-cfw --experimental
```

Проверяет CFW, поднимает локальный TSS-прокси, ловит APTicket
(`$W/apticket.im4m`) и восстанавливает. Финал: `Status: Restore Finished`.

`--serial` (у `make-cfw`, `get-rd`, `get-boot`) добавляет `serial=3` в
boot-args: консоль ядра уходит на UART, экран перестаёт показывать лог. Нужен
только для отладки ранней загрузки; задаётся отдельно для каждого артефакта.

---

## 5. SSH ramdisk и provisioning

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

`provision` собирает payload'ы на Mac (`fetch_payloads.sh`), ставит Dropbear и
проходит шаги `sshrd_provision.sh`:

| Шаг | Что делает |
| --- | --- |
| `mounts` | System rw, Data, Preboot (по APFS-роли) |
| `ticket` | извлекает APTicket этого восстановления из Preboot |
| `setup` | патчит Setup.app, чтобы пропустить недоступные экраны (58 методов на 23H30) |
| `userland` | `coreauthd`, `mobileactivationd`, `ctkd` (+ `l8coreauth`) |
| `pairing` | `lockdownd`, `remotepairingdeviced`, `l8pair`, `l8remotepairing` |
| `cellular` | **на iPad пропускается**: профиль без модема |
| `screentime` | быстрый отказ ScreenTime в Setup |
| `injection` | хуковый launchd (`/usr/lib/lhook`), `systemhook.dylib`, `sbextissue`, `lhookctl`; инъекция выключена до первой загрузки |
| `tweaks` | загрузчик ElleKit, `l8localauth`, `l8persona` (выключены до маркеров); пропускается без сети |
| `cache` | кэш launchd: Dropbear, `com.jbboot`, DDI, смягчение watchdogd |
| `jbtools` | помощники загрузки (`l8boot`, `ddiwatch`, `uicache` для iOS 27) |
| `sileo` | Sileo |
| `resolv` | `/private/etc/resolv.conf` |
| `apps` | системные приложения в `/Applications` |
| `verify` | проверка итога; при ошибке «INCOMPLETE, Do not boot» |

Отдельные шаги можно запускать вручную из `device/`, например
`./sshrd_provision.sh resolv apps`. Шаг `cellular` на iPad откажется
запускаться с сообщением «this firmware profile has no baseband».

Opt-in: iPad-фиксы из `tweaks.list` ещё из SSHRD (обычно не нужно, их ставит
`fw tweaks`):

```sh
cd device && ./fetch_payloads.sh fixes && ./sshrd_provision.sh fixes
```

---

## 6. Нормальная загрузка

iPad в pwn DFU:

```sh
$B fw get-boot --experimental
$B fw boot     --experimental
```

`get-boot` печатает `kernel plan boot-jit`. На iPad это boot-public + патчи
code signing (PPL allow-invalid, `vm_fault_enter`, `vm_map_protect`) +
task-access, а версия ядра помечается как `TASKAC2_ARM64_T8020`. TXM на iPad
нет, поэтому плана TXM нет. Перед подписью `get-boot` проверяет, что все
записи task-access и метка `TASKAC2` действительно в наборе: иначе он
останавливается и просит пересобрать CLI.

Аварийный выход, если система с `boot-jit` не грузится:

```sh
$B fw get-boot --experimental --no-tweaks   # ядро boot-public, без code signing и task-access
$B fw boot     --experimental
```

`$W/Ramdisk/liter8-boot.json` записывает, какой план собран (`kernelPlan`).

Совет: можно сделать первую загрузку с `--no-tweaks`, убедиться, что система
стабильна (SSH, SpringBoard, приложения), и затем пересобрать без флага.

---

## 7. Завершение после первой загрузки

Когда iPad загрузился и доступен по SSH:

```sh
$B fw finalize --experimental --check
$B fw finalize --experimental
$B fw finalize --experimental --check
```

`finalize` ставит Procursus bootstrap, профиль root shell, пакет ElleKit
(из `payload/tweaks/ellekit.deb`, если provisioning его скачал), dpkg-хук
`tweaksign` (переподписывает ad-hoc твики из репозиториев после каждого
`dpkg`), создаёт `/var/jb/.lhook_autoenable` (инъекция включается сама при
каждой загрузке, когда SpringBoard поднялся), регистрирует системные
приложения и проверяет задание `com.jbboot`.

SSH: `iproxy 2222:22`, затем `ssh -p 2222 root@localhost` (пароль `alpine`).
`fw finalize` и `fw tweaks` поднимают `iproxy` сами. Для ручных команд есть
`tools/sshdev 'команда'`.

Дополнительно (не проверено на iPad после слияния):

```sh
$B fw setup-shell    --experimental   # удобная оболочка SSH
$B fw setup-debugger --experimental   # debugserver + помощник TrollStore Lite; нужен интернет на устройстве
```

---

## 8. Твики iPad после каждой загрузки: `fw tweaks`

**После каждой загрузки**, когда появился интерфейс:

```sh
$B fw tweaks --experimental --check   # что активно, ничего не меняет
$B fw tweaks --experimental
```

Только для iPad11,6 / 23H30 или 23H128: на любом другом устройстве команда
остановится. На 23H128 фиксы ещё не запускались на железе.

Что делает:

1. Пересобирает фиксы из исходников (`device/build_tweaks.sh` → `payload/fixes`)
   и докатывает изменённые файлы на Data-том по SSH (SSHRD не нужен).
2. При первой активации создаёт переключатели по умолчанию.
3. Включает инъекцию на эту загрузку (`lhookctl enable`), если `l8boot` ещё не
   включил.
4. По переключателям: токен Karing, ответы eligibility для Marketplace,
   настройки устройства, адаптеры NewTerm/Sileo/TrollDecrypt.
5. Перезапускает только нужные демоны (иконки, FileProvider, службы установки,
   `runningboardd` при `rootapps`) и делает respring.

Повторный запуск в ту же загрузку безопасен и почти ничего не делает.

### Переключатели

Файлы-маркеры root, 0600, в `/var/jb`. Меняются с Mac:

```sh
python3 device/liter8_tweaks.py status
python3 device/liter8_tweaks.py disable files
python3 device/liter8_tweaks.py enable rootapps
```

| Переключатель | Фикс | По умолчанию |
| --- | --- | --- |
| — | `l8excport`: приложения со своим crash reporter (Facebook и др.) не падают на EXC_GUARD | всегда |
| — | `l8icons`: иконки rootless-приложений | всегда |
| `localauth` | `l8localauth`: подтверждения паролем без SEP | вкл |
| `persona` | `l8persona`: persona при установке приложений | вкл |
| `files` | `l8files`: «На iPad» в «Файлах» (при падениях fileproviderd выключается сам) | вкл |
| `vpn` | `l8vpn` + токен Karing на каждую загрузку | вкл |
| `marketplace` | ответы eligibility для Marketplace (AltStore) | вкл |
| `deviceprefs` | баннер SRD, AirDrop «Для всех» без лимита | вкл |
| `apps` | адаптеры NewTerm (root), подпись rootless Sileo, откат прокси iCleaner, подпись TrollDecrypt | вкл |
| `rootapps` | `l8rootapps`: iCleaner от root (перезапуск `runningboardd`) | выкл |

Другие команды `device/liter8_tweaks.py`:

| Команда | Что делает |
| --- | --- |
| `activate [--check] [--no-build]` | то же, что `fw tweaks` |
| `status` | отчёт как `activate --check` |
| `enable ИМЯ` / `disable ИМЯ` | переключатель |
| `restore-apps` | вернуть NewTerm и Sileo как были, выключить `apps` |
| `eligibility status` | текущие ответы eligibility |
| `eligibility lock` / `unlock` | заморозить / разморозить кэш eligibility |
| `eligibility restore ПАПКА` | вернуть исходный plist из `/var/jb/var/backups/marketplace-…` и выключить `marketplace` |

Подробности по каждому фиксу: README в `device/excportfix`, `filesfix`,
`vpnfix`, `rootappfix`, `marketplacefix`, `deviceprefs`, `appfix`,
`trolldecryptfix`, и `device/launchdhook/SESSION_GUARD.md`.

---

## 9. Проверки на устройстве

### 9.1. Какое ядро загружено

```sh
uname -a     # TASKAC2_ARM64_T8020 = boot-jit с task-access; PATCHED_ARM64_T8020 = --no-tweaks
```

### 9.2. `csprobe`: работает ли изменение кода

Делает то же, что хук C-функции: делает свою страницу кода записываемой,
переписывает инструкцию и выполняет её. Ставится `fw tweaks`.

```sh
idevicesyslog | grep -iE "CODE ?SIGNING|Invalid Page|cs_invalid|pmap"   # на Mac
/var/jb/usr/bin/csprobe                                                  # на iPad
```

- `[csprobe] PASS` — изменённый код выполнился;
- `FAIL stage1` — `vm_map_protect` не дал RWX;
- `FAIL stage3` — не вернулось исполнение после записи;
- процесс убит после `stage1 ... ok` — не сработал `vm_fault_enter` или PPL
  allow-invalid (`pmap` в логе — PPL).

### 9.3. Инъекция твиков

```sh
/var/jb/usr/bin/lhookctl status          # enabled for this boot?
touch /var/jb/.lhook_debug               # лог инъекции
tail -50 /var/jb/tmp/lhook.log
cat /var/mobile/jbboot.log               # что сделал l8boot при загрузке
```

Инъекция никогда не идёт в `launchd`, `amfid`, `trustd`, `securityd`,
`configd`, `notifyd`, `logd`, `opendirectoryd`, `keybagd`, `watchdogd`,
`dropbear`, `sshd` и в список `/var/jb/etc/lhook.deny`. Это защита от
незагружаемого устройства.

### 9.4. Пароль, магазин, persona

- `l8localauth` переводит отказ ACM `-3` в «пароль не задан». Проверь любой
  запрос пароля.
- `l8persona` + `l8localauth` + ответы eligibility — комбинация, на которой
  7 октября 2026 года установился AltStore Marketplace на iPad11,6 / 23H30.

```sh
idevicesyslog | grep -iE "LocalAuthentication|ACM|l8persona|persona|installcoordination|installd"
/var/jb/usr/bin/personainfo
```

`l8persona: installed in pid N` — твик загрузился; `resolved ... to
com.apple.containermanager.primary-persona` — сработал обход.

### 9.5. Доступ к task port (task-access)

```sh
sh device/taskprobe/build.sh
COPYFILE_DISABLE=1 tar -cf - -C device/taskprobe taskprobe | \
  tools/sshdev 'tar -xof - -C /var/jb/usr/bin'
tools/sshdev '/var/jb/usr/bin/taskprobe; /var/jb/usr/bin/taskprobe --mobile'
```

Оба запуска должны напечатать PASS. На iPad-ветке это подтверждено 8 октября
2026 года для root и mobile.

### 9.6. Расшифровка Telegram (диагностика, opt-in)

```sh
sh device/taskprobe/selfdump.sh install
sh device/taskprobe/selfdump.sh enable    # затем закрыть и открыть Telegram
sh device/taskprobe/selfdump.sh disable
sh device/taskprobe/selfdump.sh remove
```

Результат — в `Documents/Liter8Decrypted/Telegram.app` самого Telegram.

---

## 10. Откат

| Что выключить | Как |
| --- | --- |
| Патчи code signing и task-access | `fw get-boot --experimental --no-tweaks`, затем `fw boot` |
| Автовключение инъекции | `rm /var/jb/.lhook_autoenable` на iPad |
| Инъекцию на эту загрузку | `/var/jb/usr/bin/lhookctl disable` |
| Любой фикс из раздела 8 | `python3 device/liter8_tweaks.py disable ИМЯ` |
| Ответы eligibility | `python3 device/liter8_tweaks.py eligibility restore /var/jb/var/backups/marketplace-ДАТА-ВРЕМЯ` |
| NewTerm и подпись Sileo | `python3 device/liter8_tweaks.py restore-apps` |
| Лог инъекции | `rm /var/jb/.lhook_debug` |
| Fallback pairing / RemoteXPC | удалить маркеры `/mnt2/root/Library/Lockdown/.liter8-pairing-fallback` и `/mnt1/usr/lib/.liter8-remotepairing-fallback` из SSHRD |

Заменённые системные файлы на System-томе сохраняются рядом как `.orig`.

---

## 11. Справочник команд

### `liter8 fw` (все с `--experimental` для iPad)

Общие опции: `--work-dir ПАПКА` (или `WORK_DIR`), `--board`, `--experimental`,
`--python`, `--resource-dir`.

| Команда | Назначение | Опции |
| --- | --- | --- |
| `fw actions` | список имён действий | |
| `fw prepare` | распаковать IPSW | `--file` (или `IPSW_FILE`) |
| `fw make-cfw` | собрать CFW | `--serial` |
| `fw verify-cfw` | перепроверить CFW | |
| `fw restore-cfw` | стирающее восстановление | `--idevicerestore` |
| `fw capture-ticket` | поймать APTicket во время восстановления | |
| `fw get-rd` | собрать SSH ramdisk | `--ticket`, `--sshrd-payload`, `--serial` |
| `fw boot-rd` | загрузить SSH ramdisk | `--irecovery` |
| `fw bootstrap` | распаковать rootless Procursus bootstrap | `--check` |
| `fw prepare-rootfs` / `fw unmount-rootfs` | смонтировать / отмонтировать rootfs | |
| `fw provision` | provisioning из SSHRD | `--check`, `--rootfs` |
| `fw get-boot` | собрать нормальную загрузку | `--ticket`, `--no-tweaks`, `--serial`, `--demote-ap` (исследовательский, **не грузится**) |
| `fw boot` | нормальная загрузка | `--irecovery` |
| `fw finalize` | завершение после первой загрузки | `--check` |
| `fw setup-shell` | удобная оболочка SSH | `--check` |
| `fw tweaks` | iPad-фиксы после каждой загрузки | `--check` |
| `fw setup-debugger` | debugserver и TrollStore Lite | `--check` |

### Инструменты без устройства

| Команда | Назначение |
| --- | --- |
| `liter8 resolve <компонент> <план> <файл>` | найти места патча, ничего не меняя (`--json`) |
| `liter8 apply <компонент> <план> <вход> <выход>` | пропатчить (`--records-out`, `--preserve-compression`) |
| `liter8 verify <фикстура.json> <файл>` | сверка с фикстурой |
| `liter8 fixture ...` | создать фикстуру |
| `liter8 inspect <файл> <режим>` | строки, дизассемблер и т.д. (только чтение) |
| `liter8 survey <папка>` | прогнать все планы по распакованной прошивке |
| `liter8 profile <kernelcache>` / `liter8 profiles` | какой профиль ядра / все профили |
| `liter8 acm-probe ...` | насколько совпадают сигнатуры AppleCredentialManager |
| `liter8 im4p info / extract / repack` | работа с IM4P |
| `liter8 img4 create / extract-manifest` | IMG4 и APTicket |
| `liter8 preflight` | проверка инструментов хоста |
| `liter8 setup` | пути ресурсов и Python |

Планы ядра для iPad: `ppl-trust-cache`, `credential-manager`,
`sandbox-public`, `ppl-allow-invalid`, `vm-fault-cs-bypass`, `vm-map-protect`,
`task-access`, `boot-public`, `boot-jit`, `restore`, `diagnostic`. `liter8
--help` показывает полный список для всех компонентов.

---

## 12. Что не проверено после слияния и за чем следить

1. **Фикстуры ядра 23H30** (раздел 3.3). Если `boot-jit` не даёт 138 записей
   и прежний хеш, upstream-изменения общих резолверов задели iPad.
2. **Восстановление** без четырёх патчей «нет модема» в `restored_external`.
   Ожидается `Status: Restore Finished`; если восстановление падает на шаге
   baseband — пришли лог `idevicerestore`.
3. **`launchctl`**: бинарник переподписан без `task_for_pid-allow` (из
   iPad-ветки). На iPad проверено, на iPhone — нет.
4. **Иконки**: теперь их обслуживают и `l8icons`, и `systemhook.dylib`
   одновременно. Если иконки rootless-приложений белые или
   `iconservicesagent` падает — пришли `idevicesyslog | grep -i icon`.
5. **Автовключение инъекции** при каждой загрузке (`l8boot`). Если после
   загрузки SpringBoard зацикливается — удалить `/var/jb/.lhook_autoenable`
   по SSH и перезагрузить.
6. **`l8localauth` / `l8persona`**: версии из upstream (те же исправления,
   плюс проверки). Повтор установки AltStore Marketplace покажет, всё ли в
   порядке.
7. **Повторный provisioning** выключает маркеры `localauth` и `persona`
   (политика upstream). `fw tweaks` их сам не вернёт, потому что уже
   инициализировал переключатели: `python3 device/liter8_tweaks.py enable
   localauth` и `enable persona`. По той же причине `fw provision --check`
   после `fw tweaks` пишет `ENABLED` для них и `INCOMPLETE` — это ожидаемо.

## Что прислать при проблеме

1. Вывод `$B verify` по фикстурам `kernel-boot-jit` и `kernel-boot-public`.
2. Финальный блок `fw provision --check` и `fw finalize --check`.
3. `uname -a`, вывод `csprobe` и строки `idevicesyslog` (раздел 9.2).
4. `fw tweaks --experimental --check`.
5. Для установки приложений — лог из раздела 9.4.
