# TrollDecrypt launch repair on iPad8 / TASKAC2

On 2026-10-08, TrollDecrypt 1.2.4 was reinstalled and regained the
`task_for_pid-allow` entitlement in both executable slices. Its launch helper
returned `open=0`. Removing only that entitlement and signing the executable
again returned `open=1`; TrollDecrypt remained running as mobile (PID 601).
Readback matched the repaired executable. This is a launch repair, not proof
that a complete GUI decryption operation succeeds.

The TASKAC2 kernel separately passed foreign-child task-port, PID, memory-read
and memory-write checks as both root and mobile. The repair relies on those
kernel patches instead of this entitlement. Do not apply it to stock iOS.

`liter8 fw tweaks`, while the `apps` switch is on, checks an installed
TrollDecrypt after every boot and repairs it when needed. The writer is built
here and installed as `/var/jb/usr/libexec/liter8/trolldecrypt-writer`.

The step requires the verified TASKAC2 kernel, checks the bundle ID, saves
an original executable on the Mac under
`payload/.work/trolldecrypt-backups/` in the provisioning work directory, checks matching
entitlements in all slices, removes only `task_for_pid-allow`, signs, and
atomically replaces the executable using the scoped AppBundles writer. It
preserves ownership/mode and verifies the installed bytes. It does not reboot
or change the kernel. Close and reopen the app yourself. Reinstalling the app
may restore the incompatible entitlement; the next `fw tweaks` repairs it again.

Set `LITER8_IOS_SDK` when no Xcode iPhoneOS SDK is installed. The step needs
Xcode command-line tools and ldid on the Mac. Keep the executable backup for rollback; no
third-party executable is committed to Git.

Validation: device launch and continued process presence, byte-for-byte
readback; utility no-op on the repaired device; Python syntax check; writer
compiled with arm64 iOS SDK and warnings treated as errors. The utility's
replacement path itself has not yet been exercised end-to-end: this device
was repaired with the previous equivalent writer before the utility existed.
