# NewTerm / iCleaner / Sileo launch compatibility on iPad11,6 23H30

Apply: `tools/app-launch apply`
Inspect: `tools/app-launch status`
Restore: `tools/app-launch restore`

No reboot, respring, kernel credential write or daemon is used. Original signed
binaries remain beside each adapter as `.liter8-real`, with their original mode
and ownership. Reapplying does not overwrite these backups. Package upgrades
may replace the adapters; remove/refresh the backups before applying to a new
package version. These adapters were tested with NewTerm 3 beta1 and iCleaner
Pro 7.10.0 only, on the experimental Liter8 build above.

## Cause and launch path

App launches arrive with uid/euid 501. The installed setuid binaries do not gain
root automatically on this boot. iCleaner therefore exits at its real
`setuid(0)`/uid checks. NewTerm's login fails in PAM session accounting with
`Unable to write the utmp record` followed by `pam_open_session(): System error`.
Making PAM modules optional did not fix this, and those experimental PAM edits
were restored. Authentication configuration is unchanged.

Both adapters use existing kernel persona 99, with uid/gid 0 and override flag
1. A separate spawned stage normalizes real credentials before executing the
original binary. Persona plus POSIX_SPAWN_SETEXEC returned ENOTSUP on this
kernel, so a separate stage is spawned. iCleaner's parent must enter UIApplicationMain
and complete application launch while a watcher waits for the child. The earlier
blocking wait in main caused a process-launch watchdog kill after 20 seconds.

- iCleaner: fixed original app path only, GUI launch only. The root child opens
  the existing iCleaner app; no cleanup is automatically requested. Root/CLI
  invocations pass straight through to the original binary.
- NewTerm: only the exact six-argument forced **mobile** login from the app's
  NewTermLoginHelper path uses persona. All other login commands pass through.
  By the owner's explicit request, the stage now changes the login user to root
  and the initial directory to /var/jb/var/root. Original login starts a root
  terminal. Other invocations of login still pass through unchanged.

Both accepted /var/jb and /private/var/jb paths are handled for NewTerm.
Entitlements use the repo's existing AMFI-tested persona/spawn set; get-task-allow
is deliberately absent.

## Verified on 2026-10-07

- iCleaner root stage had uid/euid 0. Both its parent and original UIKit child
  stayed alive past the former 20-second watchdog limit (over two minutes),
  without a new crash report. No cleaning was performed. UI confirmation remains
  pending.
- NewTerm: original login spawned NewTermLoginHelper, which exec'd zsh; `ps`
  confirmed a live root `-zsh` attached to terminal s002. UI/input confirmation
  remains pending.
- The installed payloads were subsequently rebuilt with guards and EINTR-safe
  waits through `tools/app-launch apply`.

## Sileo signature and registration

Sileo launch failed with launchd spawn error 153. Its installed signature claimed
get-task-allow and dozens of kernel/task/launchd privileges unsupported on this
experimental build. Apply backs up Sileo as Sileo.liter8-before and signs it with
the same tested six-entitlement set used by the launch adapters, preserving its
original Keychain access groups. Then uicache registers only Sileo.app. The next
launch succeeded and Sileo remained alive. Icon appearance and app UI still need
owner confirmation. Restore reinstates Sileo's original signature and registers
it again. No repository list or package data is deleted.

This is a compatibility adapter, not a universal fix for all setuid applications.
Tab termination, background lifecycle, and cleanup operations are not yet
verified. Restoring binaries takes effect on the next app/login launch.
