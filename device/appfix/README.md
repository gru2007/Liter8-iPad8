# NewTerm / iCleaner launch compatibility on iPad11,6 23H30

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
kernel, so the original app process waits for its child instead.

- iCleaner: fixed original app path only, GUI launch only. The root child opens
  the existing iCleaner app; no cleanup is automatically requested. Root/CLI
  invocations pass straight through to the original binary.
- NewTerm: only the exact six-argument forced **mobile** login from the app's
  NewTermLoginHelper path uses persona. All other login commands pass through.
  Original login performs its normal PAM/account checks and starts the terminal
  as mobile; this does not turn the terminal into a root shell.

Both accepted /var/jb and /private/var/jb paths are handled for NewTerm.
Entitlements use the repo's existing AMFI-tested persona/spawn set; get-task-allow
is deliberately absent.

## Verified on 2026-10-07

- iCleaner root stage had uid/euid 0, and its original UIKit process stayed alive.
  No cleaning was performed. UI confirmation remains pending.
- NewTerm: original login spawned NewTermLoginHelper, which exec'd zsh; `ps`
  confirmed a live mobile `-zsh` attached to terminal s002. UI/input confirmation
  remains pending.
- The installed payloads were subsequently rebuilt with guards and EINTR-safe
  waits through `tools/app-launch apply`.

This is a compatibility adapter, not a universal fix for all setuid applications.
Tab termination, background lifecycle, and cleanup operations are not yet
verified. Restoring binaries takes effect on the next app/login launch.
