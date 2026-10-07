# Device preferences (iPad11,6, 23H30 only)

`tools/device-preferences apply` backs up the current MobileGestalt and sharingd
plists under `/var/jb/var/backups/deviceprefs-TIMESTAMP`, then applies the same
keys used in Nugget's `src/tweaks/tweak_loader.py`:

- `CacheExtra.XYlJKKkj2hztRP1NWWnhlw = 1`: Security Research Device UI flag.
  This is a cosmetic flag, not actual SRD provisioning. Existing SpringBoard
  state can remain cached; no SpringBoard restart or reboot is performed.
- `/var/Managed Preferences/mobile/com.apple.sharingd.plist`:
  `OverrideTimeLimitEveryoneMode = true`.
- CFPreferences for mobile sharingd: `DiscoverableMode = Everyone` and the
  timeout override. Only sharingd is restarted, which can interrupt an active
  AirDrop transfer.

MobileGestaltCache is protected by System Policy even from the SSH root shell.
The writer claims only the storage entitlement and system group found on this
build's Apple MobileGestaltHelper. It writes the cache atomically, keeping
mobile ownership and mode 0644. No general filesystem protection is disabled.

`tools/device-preferences status` reads back the three stored settings.
The apply command succeeded on 2026-10-07; fresh mobile CFPreferences read-back still returned Everyone and override=1
after more than 10 minutes. AirDrop transfer and the visible SRD banner still
require UI verification.

Restore the original files from the reported backup when needed. Use the signed
writer (`/var/tmp/l8-deviceprefs mg-write`, input
`/var/tmp/l8-mobilegestalt-new.plist`) for the MobileGestalt cache; an ordinary
root copy into this protected system group can be denied. Restore/delete the
managed sharingd file according to its `.absent` marker, and restore sharingd
preferences through CFPreferences to avoid overwriting its live cache.
