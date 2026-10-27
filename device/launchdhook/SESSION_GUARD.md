# Injection session guard

The old `/var/jb/.lhook_enabled` empty file persisted across reboots and enabled
propagation as soon as Data appeared, before userspace setup had completed.
That is a confirmed behavior of the previous code; it is not yet a proven
cause of the observed boot failure.

The new hook requires the file to contain the current `kern.bootsessionuuid`.
Old empty files and previous-session UUIDs fail closed. Nothing enables it at
early boot. The automatic enable, on by default, keeps to that: while
`/var/jb/.lhook_autoenable` exists (created by `fw finalize`; root-owned, not
group or other writable), `l8boot` (run by `jbboot.sh`) waits until SpringBoard
has been up for 20 s, then writes the session flag exactly as `lhookctl enable`
does and restarts SpringBoard once. On the iPad 8 profile, `liter8 fw tweaks`
on the Mac also enables it after the interface is up and restarts the daemons
whose tweaks need it (see `device/liter8_tweaks.py`). For manual control, or
without that file, after the interface is usable, root runs:

```sh
/var/jb/usr/bin/lhookctl status
/var/jb/usr/bin/lhookctl enable
```

Relaunch the specific app or daemon to load its tweaks. Enabling does not
retroactively inject already running processes. Disable for future launches:

```sh
/var/jb/usr/bin/lhookctl disable
```

Already loaded dylibs are not unloaded by disable. Do not enable while still
in SSHRD: it has a different boot session from the normal operating system.
Do not use `touch .lhook_enabled` with this hook; it no longer grants permission.

Build and install from the Mac with mounted, writable SSHRD System `/mnt1`
and Data `/mnt2`:

```sh
export LITER8_IOS_SDK="$HOME/theos/sdks/iPhoneOS16.5.sdk"
sh device/launchdhook/install-sshrd.sh
```

The installer backs up `/usr/lib/lhook` as `lhook.before-session-guard`, verifies
staged bytes before replacement, and does not modify launchd or the kernel.
If the System mount is read-only, use the existing SSHRD remount procedure
before installing. Regular `fetch_payloads.sh injection` and provisioning also
include the controller.

`lhook` is the small propagation shim, not an individual tweak. It still needs
to reach `xpcproxy` to pass state into applications. PID 1 and xpcproxy never
dlopen TweakLoader, and hard-denied processes are excluded. ElleKit handles
individual tweak filters after the loader runs. This change does not restrict
injection to a fixed list of applications or remove daemon tweak support.

Constructor messages remain in `lhook.log`; console output now requires
`.lhook_debug`. A load message alone does not prove a tweak was selected.

Validation on the host: both iOS architecture slices built and signed; shared
gate/controller regression tests reject absent, empty, malformed and foreign
session flags, and accept only the current session. Device installation,
normal boot and sandboxed-app behavior still require hardware verification.

### Rootless application icons

The icon service can predate manual injection enabling. On 2026-10-08, white
icons persisted after rootless bundle registration. A scoped ElleKit payload
(`l8icons.plist`, only `iconservicesagent`) now reuses `systemhook_icon.c` to
consume the per-boot read token. The service confirmed
`consume OK, /var/jb verified readable`; bundles were registered again after
that confirmation, followed by a SpringBoard restart. Visual confirmation is
still required; the grant result alone does not prove rendered icons.

This was measured on iPad 8 (`j171aap`, 23H30), where the scoped helper is
installed as `l8icons` from `tweaks.list` by `liter8 fw tweaks` (or the opt-in
`sshrd_provision.sh fixes` step). lhook also inserts `systemhook.dylib`
directly wherever it is installed (see `lhook.c`, `kIcons`), which is how n104
gets the grant; that insert postdates the iPad measurement, so on iPad both
paths now consume the token and the combination is unmeasured there.
`liter8 fw tweaks`, after each boot, enables lhook, refreshes the token, restarts
only the icon service, waits for the verified grant, registers rootless apps and
then restarts SpringBoard. No rootfs changes or kernel reboot are required.
