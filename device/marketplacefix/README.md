# iPad 8 live Marketplace repair

On 2026-10-07 the user confirmed that AltStore Marketplace installed on
**iPad11,6 / iPadOS 26.7.1, build 23H30** after this combination:

- Integrated Liter8 `lhook` consumes read and executable sandbox extensions and
  loads ElleKit in the target process; no SpawnBridge is used.
- `l8localauth` translates the specific SEP-less ACM failure to the existing
  no-passcode path. The installation still needs the user's explicit approval.
- `l8persona` runs in `installd` and `installcoordinationd`, falling back to
  `CONTAINER_PERSONA_PRIMARY` after native persona resolution fails. Its successful
  fallback clears the caller's `NSError`.
- The current eligibility plist has answer **4**, source **2**, for HYDROGEN,
  HELIUM, LITHIUM, CARBON, ARGON, POTASSIUM and SEARCH_MARKETPLACES. Other entries
  and each domain's status/context are preserved.

## How it is installed

All of it is part of the normal Liter8 flow now; there is no separate repair
script. `tweaks.list` names the two tweaks, their switches and the two helpers
built here (`eligibility`, `eligibility-persist`), so:

- `liter8 fw provision` builds them and installs them under `/var/jb` from SSHRD,
  with the `localauth`, `persona` and `marketplace` switches on.
- `liter8 fw tweaks`, after each boot, enables injection, restarts the install
  jobs (`installcoordinationd`, `installd`, `managedappdistributiond`,
  `appstorecomponentsd`) so the tweaks load, and writes the seven answers again
  whenever eligibilityd has regenerated them. Each write saves the plist it
  replaced in a fresh `/var/jb/var/backups/marketplace-DATE-TIME`.

The `eligibility` helper refuses other device models and builds. Retry
Marketplace installation from Safari and approve the system prompt. Observe the
log separately, specifying the iPad's UDID if more than one device is connected:

```sh
idevicesyslog --no-colors | grep -iE 'l8persona|l8localauth|managedappdistribution|installcoordination|installd'
```

## Restore

```sh
python3 device/liter8_tweaks.py eligibility restore /var/jb/var/backups/marketplace-20261007-181500
```

This writes the saved plist back and turns the `marketplace` switch off, so the
next `fw tweaks` leaves the answers alone. `disable persona` and
`disable localauth` turn the two tweaks off for future launches.

## Validation and limits

```sh
python3 device/marketplacefix/test.py
```

`build.sh` runs it on a Mac. The host test exercises the actual plist writer
against temporary fixtures: seven-domain changes, preservation of other data and
file permissions, refusal to overwrite a backup, restore, and rejection of
incomplete input. Production builds retain the device/build guard; the host test
bypass exists only when explicitly compiled for that test.

This is an installation workaround. It does not create a real personal persona,
supply SEP-backed authentication or enable kernel text hooks. On the tested boot
the corrected `csprobe` still failed at stage 1 (`RW|COPY`, protection failure).
It does not force eligibility decisions made in daemon memory. Other Marketplace
stores and builds remain unverified.

Only source and instructions belong in Git. Apple binaries, device plists,
account data, logs and backups stay outside the repository's tracked files.

## Optional cache lock (iPad11,6 / 23H30 only)

The per-boot rewrite covers regenerated answers at the next `fw tweaks`. The
lock is for the time in between: it saves the pre-edit plist and the original
file/directory flags in a fresh device backup, writes the same seven answers,
then adds `UF_IMMUTABLE` to the file AND its directory. Directory protection
also blocks creating temporary replacements and changing directory entries.
Other cached feature eligibility answers also stop refreshing while this
complete cache is locked. It neither stops eligibilityd nor modifies unrelated
domain answers.

```sh
python3 device/liter8_tweaks.py eligibility lock
python3 device/liter8_tweaks.py eligibility status
# Remove protection while keeping the current answers:
python3 device/liter8_tweaks.py eligibility unlock
# Remove protection and restore the pre-edit plist:
python3 device/liter8_tweaks.py eligibility restore
```

The active lock backup is remembered on the device, so unlock and restore
without a path use it; an explicit older backup path is also accepted. Repeated
lock leaves the existing rollback state alone. `fw tweaks` reports, and does not
touch, a cache that is locked with other answers.

Live validation on 2026-10-07: both flags read back as 2; root append-open and
file creation in the directory failed with `Operation not permitted`. Unlock
and relock were exercised successfully. After restarting eligibilityd and the
two Marketplace services, the daemon stayed running and the plist hash and
seven 4/2 answers remained unchanged. This verifies disk protection; continued
Marketplace behavior still requires testing per flow. At 18:53, the captured
installation log confirmed successful completion of an AltStore update while
locked (`coordinatorDidCompleteSuccessfully` with the AltStore app record).
This does not establish successful downloads of other apps inside AltStore or
long-term behavior after a reboot.
