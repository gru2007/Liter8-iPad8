# iPad 8 (23H30) — tweaks, code signing, passcode, personas

Status: experimental. The kernel code-signing-invalid patches, the `boot-jit`
plan and the `csprobe`/`personainfo` diagnostics exist and build. Nothing here
is confirmed on hardware yet. This is the end-to-end test path, from a host build to a booted system with working
tweaks, plus exactly what to send back at each point that still needs device
data.

Everything here applies to the iPad 8 Wi-Fi (`j171aap`) SEP-less port. `$B` is
`.build/release/liter8`. Every `fw` command needs `--experimental`.

## 0. Build the host tool

```sh
make setup && make release
```

Confirm the new plans are registered:

```sh
$B 2>&1 | grep -A3 'kernel '
# expect: ... ppl-allow-invalid, vm-fault-cs-bypass, vm-map-protect, ... boot-jit ...
$B profiles | grep -A3 ios26-23H30-j171aap
# expect a kernel-codesign-invalid line
```

## 1. The kernel patches against your kernelcache (host-side, no device)

The three resolvers are ported from palera1n's T8020 KPF. Each matches exactly
one site in the stock `23H30` kernelcache, and `boot-jit` gives 123 records
(`boot-public`'s 118 plus five). They are written to fail safe: if a pattern
does not match, `resolve` reports `no candidate` and nothing is patched.

```sh
$B im4p extract /path/to/BuildManifest/kernelcache.release.ipad11b kc.raw

$B resolve kernel ppl-allow-invalid  kc.raw
$B resolve kernel vm-fault-cs-bypass kc.raw
$B resolve kernel vm-map-protect     kc.raw
$B resolve kernel boot-jit           kc.raw   # boot-public + the three above
```

Three outcomes per resolver:

- **Records printed** — the pattern matched. Good; go to step 2.
- **`no candidate`** — that encoding is not in this kernel. Send me a
  disassembly window so I can add the right variant. For the PPL one:
  `$B inspect kc.raw strings pmap_create` then `$B inspect kc.raw dis <offset> 60`
  around the hit. For `vm-fault`/`vm-map-protect`, palera1n's KPF has many
  version-specific forms; I ported the Darwin-25 ones, and the disassembly tells
  me which your build uses.
- **`ambiguous candidate`** — more than one match; send the offsets.

`boot-jit` needs all three to resolve; if any reports `no candidate`, a normal
`get-boot` on the iPad stops until it is fixed. Until then, boot with
`get-boot --no-tweaks` (ObjC-only tweaks can still be tested that way).

## 2. Exact-build fixture

The exact bytes are pinned in
`fixtures/23H30/j171aap/kernel-boot-jit-j171aap-23H30.json`, next to the
`kernel-boot-public` oracle. To check your kernelcache against it:

```sh
$B verify fixtures/23H30/j171aap/kernel-boot-jit-j171aap-23H30.json kc.raw
```

## 3. Full device flow

Same as the base iPad 8 runbook, with one change at `get-boot`. See
[IPAD8_J171AAP_23H30.md](IPAD8_J171AAP_23H30.md) for the restore/provision
detail; the short form:

```sh
export WORK_DIR="$PWD/.liter8-ipad8-23H30"
# with only Command Line Tools, point this at an unpacked iPhoneOS SDK so the
# device helpers build:
export LITER8_IOS_SDK=/path/to/iPhoneOS.sdk

$B fw prepare    --experimental --file /path/to/iPad_..._23H30_Restore.ipsw
$B fw make-cfw   --experimental
$B fw restore-cfw --experimental        # erase restore, wipes the iPad

$B fw get-rd     --experimental
$B fw boot-rd    --experimental

$B fw bootstrap      --experimental
$B fw prepare-rootfs --experimental
$B fw provision      --experimental
$B fw unmount-rootfs --experimental

# NORMAL BOOT (the iPad profile builds boot-jit by default):
$B fw get-boot   --experimental
$B fw boot       --experimental
```

The iPad profile sets `normalBootRelaxesCodeSigning`, so `get-boot` builds the
normal-boot kernelcache with `boot-jit` and prints `kernel plan boot-jit`.
`--no-tweaks` builds `boot-public` instead: the recovery path if a code-signing
patch is wrong. If a code-signing resolver did not match in step 1, `get-boot`
stops with `no candidate` until it is fixed or `--no-tweaks` is passed. The
boot manifest in `Ramdisk/liter8-boot.json` records the `"kernelPlan"`.

> First time: consider one boot with `--no-tweaks` to confirm the system is
> stable (SSH, SpringBoard, apps), then rebuild without it. If something breaks
> afterwards, the kernel plan is the only variable.

## 4. Confirm the kernel patches took (on device)

SSH in. First, prove you booted the patched kernel:

```sh
uname -a            # contains PATCHED_ARM64_T8020
```

Then run `csprobe`. It does exactly what a function-hook tweak does — makes its
own code writable, rewrites an instruction, restores execute, runs it — and
reports which stage fails.

```sh
# build it on the Mac (needs the iOS SDK as above), then copy over:
sh device/csprobe/build.sh
scp device/csprobe/csprobe root@DEVICE:/var/jb/usr/bin/

# on the Mac, watch the code-signing log while it runs:
idevicesyslog | grep -iE "CODE ?SIGNING|csproc|Invalid Page|cs_invalid|amfi"

# on the device:
/var/jb/usr/bin/csprobe
```

Reading the result:

- **`[csprobe] PASS`** — self-modifying code works; the kernel side is done.
  Go to step 5.
- **FAIL at stage1/stage3** — `vm_map_protect` patch missing or wrong. The log
  names the refusal. Send me both outputs.
- **killed before stage4 prints its result** — `vm_fault_enter` and/or the PPL
  `allow-invalid` patch is missing. The kernel log line tells which
  (`not allowed by pmap` = PPL; a cs-violation kill = vm_fault). Send it.

**Send me the csprobe output and the matching syslog lines.** That single run
tells us whether the kernel work is finished or which patch to refine.

## 5. Tweaks

With csprobe passing:

```sh
# ElleKit + a tweak must be installed under the bootstrap, then:
/var/jb/usr/bin/lhookctl enable       # after UI startup; this boot only
touch /var/jb/.lhook_debug            # optional: trace injection
# respring or relaunch the target process
cat /var/jb/tmp/lhook.log | tail -50  # did TweakLoader reach the process?
```

Test one ObjC-only tweak and one that hooks a C function. If the C-function one
now works where it used to crash, the code-signing patches did their job.

`lhook` now does the scoped-extension injection: dyld inserts only the
System-volume `lhook`, the parent mints a `/private/var/jb` read extension for an
injected child, and the child consumes it before `dlopen`-ing TweakLoader, so a
sandboxed app can read the rootless `TweakInject` directory. The early-boot fast
path (no allocation, never fail a PID 1 spawn) and the removal of the reverted
`Liter8SpawnBridge` reference are in. It builds only with the iOS SDK.

## 6. Passcode prompts (alt-store confirmations)

Every "enter passcode to confirm" prompt returned "cancelled" because, with no
SEP, ACM rejects the check with `-3` before the sheet appears and the app sees
`com.apple.LocalAuthentication/-1000`. The blocker is known: the marketplace
prompt is `LAPolicyOslo` (policy 1005), failing with
`ACM verification of Oslo on ACMContext 0 failed: -3`.

`l8localauth.dylib` handles this generally. It swizzles `LAContext` and, only
for that exact ACM `-3` / LA `-1000` signature, reports `LAErrorPasscodeNotSet`
so the UI takes its no-passcode branch. It matches the signature, not a policy
number, so it covers Oslo (store install), Trust-computer (1028) and the rest at
once. It is marker-gated and changes no code pages, so it does not depend on the
kernel patches.

```sh
sh device/localauthfix/build.sh          # also runs the self-test on a Mac
# install it as an ElleKit tweak; lhook's TweakLoader loads it (Foundation filter):
scp device/localauthfix/l8localauth.dylib device/localauthfix/l8localauth.plist \
    root@DEVICE:/var/jb/usr/lib/TweakInject/
# arm it (root-owned marker; remove to disable):
ssh root@DEVICE 'touch /private/var/jb/.liter8-localauth && chmod 600 /private/var/jb/.liter8-localauth'
```

It must be loaded into the process that shows the prompt (the store's
`AppDistributionLaunchAngel`, Settings, lockdownd, ...). With injection enabled
(`/var/jb/.lhook_enabled`), the Foundation filter reaches all of them. For a
daemon that is not injected, weak-load it the way `l8coreauth` is wired in
provisioning.

If, after this, a store install still fails without a passcode error, the
remaining blocker is the persona/session state in section 7, not passcode.
Send the `idevicesyslog` around the attempt (`grep -iE
"LocalAuthentication|ACM|distribution|install"`) so we can tell which it is.

## 7. Personas / "On My iPad" / alternative app stores

The install failure (eligibility written, mobiledistributiond hooked, but the
store will not install, and "On My iPad" is missing in Files) is a persona and
user-session problem, not a tweak problem: the SEP-less boot never ran Setup, so
the personal persona and session that Setup creates do not exist. Fixing it is
separate from, and a prerequisite for, the store working.

`personainfo` dumps the exact state. It reads only, changes nothing.

```sh
sh device/personafix/build.sh
scp device/personafix/personainfo root@DEVICE:/var/jb/usr/bin/
ssh root@DEVICE /var/jb/usr/bin/personainfo
```

**Send me the whole output.** It shows the persona table, whether the personal
persona (id 100) exists, the data-volume paths a personal persona and File
Provider need, and which install/session daemons are present. With that I can
design the persona/session fix; writing one that runs at boot without seeing
this state risks an unbootable device, so it waits for the dump.

## What is confirmed vs. pending

| Piece | State |
| --- | --- |
| Kernel resolvers build + unit tests | done (synthetic images) |
| `boot-jit` plan, iPad default, `--tweaks`/`--no-tweaks` | done |
| lhook scoped-extension injection + early-boot guards | done |
| `l8localauth` passcode fix + self-test | done (source) |
| `csprobe`, `personainfo`, `l8localauth` build | source done; build needs the iOS SDK |
| Resolvers match real 23H30 kernelcache | done (one site each, 123 records) |
| Exact-build fixture | done (`kernel-boot-jit-j171aap-23H30.json`) |
| csprobe PASS on device | **pending step 4** |
| l8localauth confirmed on device | **pending a store-install attempt** |
| Persona fix | **pending step 7 dump** |
