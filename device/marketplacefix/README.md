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

## Apply

Prerequisites: a running experimental Liter8 boot, the integrated `lhook`,
`/var/jb/.lhook_enabled`, ElleKit/TweakLoader, Python 3, an iOS SDK and USB SSH
at `root@localhost:2222` with the current default password. This script does not
replace System-volume files or the kernel.

From the repository root on the Mac:

```sh
export LITER8_IOS_SDK="$HOME/theos/sdks/iPhoneOS16.5.sdk"
python3 device/marketplacefix/repair.py apply
```

Use `--port PORT` if the USB forward differs. The helper refuses other device
models/builds. The script builds the two tweaks with their host self-tests,
backs up existing tweak files and marker states, edits eligibility with an
entitled helper, verifies the disk readback and restarts these user/501 jobs:

- `com.apple.installcoordinationd`
- `com.apple.mobile.installd`
- `com.apple.managedappdistributiond`
- `com.apple.appstorecomponentsd`

The installed Procursus `launchctl` was killed on this boot because it carried
`task_for_pid-allow`. The script signs a temporary copy without that entitlement
or `get-task-allow`, keeping its other entitlements. The installed copy is unchanged.

Retry Marketplace installation from Safari and approve the system prompt.
A completed script means the repair was applied; confirm actual installation
on the device. Observe the log separately, specifying the iPad's UDID if more
than one device is connected:

```sh
idevicesyslog --no-colors | grep -iE 'l8persona|l8localauth|managedappdistribution|installcoordination|installd'
```

## Restore

The script prints a device directory such as
`/var/jb/var/backups/marketplace-20261007-181500`. Use that exact directory:

```sh
python3 device/marketplacefix/repair.py restore /var/jb/var/backups/marketplace-20261007-181500
```

This restores eligibility, the four original tweak files and the original marker
states, then refreshes the same four jobs. Backups remain available. A partial
apply can also be restored once its eligibility backup exists. No reboot or
respring is performed.

## Validation and limits

```sh
python3 device/marketplacefix/test.py
```

The host test exercises the actual plist writer against temporary fixtures:
seven-domain changes, preservation of other data and file permissions, refusal
to overwrite a backup, restore, and rejection of incomplete input. Production
builds retain the device/build guard; the host test bypass exists only when
explicitly compiled for that test.

This is an installation workaround. It does not create a real personal persona,
repair Files' “On My iPad”, supply SEP-backed authentication or enable kernel
text hooks. On the tested boot the corrected `csprobe` still failed at stage 1
(`RW|COPY`, protection failure). The normal repair does not prevent eligibility regeneration. The optional
cache lock below protects its on-disk answers from writes and atomic replacement.
It does not force eligibility decisions made in daemon memory. Other Marketplace stores and builds remain unverified.

Only source and instructions belong in Git. Apple binaries, device plists,
account data, logs and backups stay outside the repository's tracked files.

## Optional cache lock (iPad11,6 / 23H30 only)

After the original answers were regenerated, `persist.py` was added as an
explicit, reversible disk-cache lock. It saves the pre-edit plist and original
file/directory flags in a fresh device backup, writes the same seven answers,
then adds `UF_IMMUTABLE` to the file AND its directory. Directory protection
also blocks creating temporary replacements and changing directory entries. Other cached feature eligibility
answers also stop refreshing while this complete cache is locked. It neither
stops eligibilityd nor modifies unrelated domain answers.

```sh
export LITER8_IOS_SDK="$HOME/theos/sdks/iPhoneOS16.5.sdk"
./tools/marketplace-eligibility apply
./tools/marketplace-eligibility status
```

The active backup path is saved automatically. Commands without a backup path
use that active backup. An explicit older backup path is also accepted:

```sh
# Remove protection while keeping the current eligibility answers.
./tools/marketplace-eligibility unlock
# Remove protection and restore the pre-edit plist.
./tools/marketplace-eligibility restore
```

Repeated apply verifies both locks and the seven answers without replacing
rollback metadata. A partial lock or unexpected locked answers are refused.
The original `repair.py` writer cannot operate while the cache is locked;
unlock it first. The persist commands do not restart services or the device.

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
