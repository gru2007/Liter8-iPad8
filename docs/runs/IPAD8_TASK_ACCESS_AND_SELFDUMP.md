# T8020 / 23H30 task access and self-process dump

## Observed on 2026-10-08

After signing into the account that owns the App Store download, Telegram
(`ph.telegra.Telegraph`) launches normally. The scoped `l8selfdump` ElleKit
payload loaded into it and dumped six encrypted images: Telegram plus
MtProtoKitFramework, TelegramCoreFramework, TelegramUIFramework,
SwiftSignalKitFramework and PostboxFramework.

All six executables were checked on the host: original cryptid 1, output
cryptid 0, identical file size, encrypted range replaced with different bytes
from the running process, and every byte outside that range and the cryptid
field unchanged. Original app files are never modified. The marker
was removed after the test, so future launches do not repeat the dump.

This is self-process decryption, not an execution of the stock TrollDecryptor.
Only loaded images are handled. Unloaded extensions may remain encrypted;
this output is not a complete, verified decrypted IPA.

## Repeat the scoped test

From the repository root, with SSH available through `tools/sshdev`:

```sh
export LITER8_IOS_SDK="$HOME/theos/sdks/iPhoneOS16.5.sdk"
sh device/taskprobe/selfdump.sh install
sh device/taskprobe/selfdump.sh enable
```

Close and reopen Telegram. Wait for `l8selfdump: finished` in the device log.
The files are in Telegram's own `Documents/Liter8Decrypted/Telegram.app`.
Disable the test afterwards:

```sh
sh device/taskprobe/selfdump.sh disable
```

The filter and constructor both restrict this diagnostic to Telegram. It
supports thin 64-bit Mach-O images, does not obtain foreign task ports, and
copies executable images only. It does not copy account or application data.

## Kernel task-access plan

The old boot kernel rejects `task_for_pid` for both root and mobile when
targeting an otherwise cooperative child process. `device/taskprobe` checks
the actual task port, reads a child-owned witness and writes it back, then
has the child verify the change. Merely opening a decryptor UI is not a pass.

`kernel task-access` adds fourteen guarded patch records for the matched
23H30 T8020 kernel: AMFI get-task policy, Sandbox expose/get/debug callbacks,
and two task conversion paths. The latter strategy follows PongoOS's
`checkra1n/kpf/mach_port.c`; it retains the surrounding object validation.
The resolver rejects unknown kernels and damaged candidate instructions.
It is included in `boot-jit` for this opt-in profile and also available as a
standalone diagnostic plan. After the failed boot, automatic inclusion was
briefly reverted and then restored at the operator's request for a controlled
comparison with tweak injection disabled. The cause of the boot failure
remains unisolated.
POSIX credential checks and the kernel_task exclusion are not removed.

Standalone fixture: 14 records. Full boot-jit fixture: 137 records.
The task-access boot failed to reach the interface: launch messages appeared,
but this is not a successful hardware validation. The cause is not yet isolated.
The task-access set has been reselected in `.liter8-ipad8-23H30/Ramdisk` at
the operator's request. The original backup remains
`Ramdisk.before-task-access-20261008`. Do not treat task access as working
until hardware tests pass. Next comparison: same task-access kernel, but remove
`/var/jb/.lhook_enabled` before boot to disable ElleKit propagation and loading.
With the Data volume mounted at `/mnt2` in SSHRD, the corresponding marker is
`/mnt2/jb/.lhook_enabled`. Preserve it by renaming instead of deleting.
`[lhook] loaded into pid` is an unconditional constructor message and does
not prove that TweakLoader or an individual tweak loaded. The photograph also
contains APFS class-1 protection failures and a persona lookup failure; it
does not identify the failing executable. Capture the complete boot log for
the comparison before attributing the failure to either the kernel or loader.
The separate launch rejection of binaries carrying `task_for_pid-allow`
must also be retested; these patches are not yet evidence that it is fixed.

Prepare the normal boot set (no device reboot during this command):

```sh
swift build
.build/debug/liter8 fw get-boot --experimental --tweaks \
  --work-dir "$PWD/.liter8-ipad8-23H30" \
  --ticket "$PWD/.liter8-ipad8-23H30/apticket.im4m"
```

With the iPad in pwn DFU, boot that set through the existing Liter8 transport:

```sh
.build/debug/liter8 fw boot --experimental \
  --work-dir "$PWD/.liter8-ipad8-23H30"
```

Then install and run the access test:

```sh
sh device/taskprobe/build.sh
COPYFILE_DISABLE=1 tar -cf - -C device/taskprobe taskprobe | \
  tools/sshdev 'tar -xof - -C /var/jb/usr/bin'
tools/sshdev '/var/jb/usr/bin/taskprobe; /var/jb/usr/bin/taskprobe --mobile'
```

Both runs must print PASS before calling foreign-task decryption supported.
Swift XCTest requires an Xcode XCTest runtime on this host; command-line
fixture and rejection checks can run with the installed Command Line Tools.
