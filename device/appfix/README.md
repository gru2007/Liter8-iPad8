# NewTerm and Sileo compatibility on iPad11,6 / 23H30

`tweaks.list` builds the NewTerm adapters into `/var/jb/usr/libexec/liter8`.
`liter8 fw tweaks`, while the `apps` switch is on, installs them over NewTerm's
login path, re-signs and registers rootless Sileo, and removes the failed
iCleaner proxy. It repeats only what a package upgrade has undone, so it is safe
after every boot. `python3 device/liter8_tweaks.py restore-apps` reinstates the
original backups and turns the switch off. No kernel write is involved.

## NewTerm

Data is mounted nosuid, so ordinary login did not gain root. Its PAM session
accounting failed with `Unable to write the utmp record`. The adapter accepts only
NewTerm's exact forced mobile login invocation, spawns through existing persona
99 with uid/gid 0, normalizes the stage's credentials, then runs original login
as root at the device owner's request. Other login invocations pass through.
Original binaries remain as `.liter8-real` backups.

NewTermLoginHelper then establishes its controlling tty and explicitly sets the
actual root home `/var/root`, ZDOTDIR and CFFIXED_USER_HOME to that same path,
root USER/LOGNAME, the rootless `/var/jb` PATH, SHELL and TMPDIR. It loads the
existing zsh setup in `/var/root`. `/var/jb/var/root` was empty and gave the owner
an unfamiliar environment in the earlier version. The root account's global
passwd entry is unchanged. htop 3.3.0 was also installed on the device; it was
previously absent. Root shell process and rootless command paths were verified.

## Sileo

The installed signature had get-task-allow and many unsupported task/launchd
privileges. Spawn failed with code 153. Apply preserves the original Keychain
access groups and signs with the repo's tested six-entitlement persona/spawn
set, then registers only Sileo.app. Subsequent launch succeeded and stayed alive.
The binary it replaced is kept as Sileo.liter8-before; package data is unchanged.
A Sileo upgrade restores its shipped signature, and the next `fw tweaks` signs
the new version the same way rather than reinstalling the old backup.

## iCleaner: native launch replaces the failed proxy

The former parent/child launch adapter did not present the real application's
window. A parent wait caused a 20-second launch watchdog kill; giving that parent
UIApplicationMain prevented the kill but showed an empty black window. Owner
confirmed the failure. Process survival was insufficient UI verification.

Apply now restores iCleaner's original binary when the `.liter8-real` backup
exists; it no longer installs that failed adapter. The source is retained solely
as evidence of the failed attempt and is excluded from build.sh. Its original
setuid path alone still fails under nosuid. Attempts to remount Data with suid did not
remove nosuid; the original nodev,nosuid flags were restored.

The separate `device/rootappfix` tweak now launches the actual app as root
through RunningBoard, preserving its scene identity. The owner approved the
required runningboardd restart; native uid 0 launch was verified without a reboot
or change of SpringBoard PID. Visible UI confirmation is still pending. See
that tweak's README and its `rootapps` switch for deployment and rollback.
