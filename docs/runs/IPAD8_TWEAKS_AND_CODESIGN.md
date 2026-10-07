# iPad 8 (23H30) — tweaks, code signing, passcode, personas

Status: experimental. The kernel code-signing-invalid patches, the `boot-jit`
plan and the `csprobe`/`personainfo` diagnostics exist and build, but none of
them is confirmed against the real `23H30` kernelcache or on hardware yet. This
is the end-to-end test path, from a host build to a booted system with working
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

## 1. Confirm the kernel patches against your kernelcache (host-side, no device)

This is the gate. The three resolvers are ported from palera1n's T8020 KPF but
have never run against `23H30`. They are written to fail safe: if a pattern does
not match, `resolve` reports `no candidate` and nothing is patched. **Do this
before any device step and send me the output.**

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

Do not proceed to a device boot with `--tweaks` until at least
`ppl-allow-invalid` and `vm-fault-cs-bypass` resolve. `vm-map-protect` is only
needed for hooks that re-protect pages (most function hooks); ObjC-only tweaks
can be tested without it.

## 2. Pin them with an exact-build fixture

Once they resolve, bind the exact bytes so a later accidental change is caught:

```sh
$B fixture kernel boot-jit kc.raw fixtures/23H30/j171aap/kernel-boot-jit-j171aap-23H30.json \
    --device "iPad 8 (Wi-Fi)" --board j171aap --build 23H30 --component kernelcache
```

Send me that JSON; I will add it to the fixture tests next to the existing
`kernel-boot-public` oracle.

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

# NORMAL BOOT WITH THE TWEAK-HOOK KERNEL:
$B fw get-boot   --experimental --tweaks
$B fw boot       --experimental
```

`--tweaks` builds the normal-boot kernelcache with `boot-jit` instead of
`boot-public`. Without it you get the ordinary boot (tweaks that only hook ObjC
methods may still work; function hooks will be killed). The boot manifest in
`Ramdisk/liter8-boot.json` records `"kernelPlan": "boot-jit"` so you can confirm
which kernel you booted.

> First time: boot once **without** `--tweaks` and confirm the system is stable
> (SSH, SpringBoard, apps). Only then rebuild with `--tweaks`. That way, if a
> code-signing patch is wrong, you know the base boot was fine and the kernel is
> the variable.

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
touch /var/jb/.lhook_enabled          # master switch (lhook re-reads per spawn)
touch /var/jb/.lhook_debug            # optional: trace injection
# respring or relaunch the target process
cat /var/jb/tmp/lhook.log | tail -50  # did TweakLoader reach the process?
```

Test one ObjC-only tweak and one that hooks a C function. If the C-function one
now works where it used to crash, the code-signing patches did their job.

Known `lhook` limitation, not yet fixed in this branch: injecting into
app-sandboxed processes still needs the process to be able to read
`/var/jb/usr/lib/TweakInject`. Your local `lhook.c` rework (sandbox-extension
flow) is the right direction but is missing an early-boot fast path and still
references the reverted `Liter8SpawnBridge`. Push that diff to a branch and I
will finish it against this tree — I cannot apply it blind.

## 6. Passcode prompts (needed for alt-store confirmations)

Every prompt that asks for the passcode to confirm something returns "cancelled"
because, with no SEP, ACM rejects the check before the sheet appears. Upstream
already fixed this for one case (Trust this computer) inside `lockdownd`. The
general fix belongs in `coreauthd`, which every LocalAuthentication request goes
through and which Liter8 already weak-loads `l8coreauth.dylib` into.

I can write that hook, but not blind. **Collect this and send it back:**

```sh
# on the Mac, while you trigger 2-3 different passcode prompts on the device:
idevicesyslog | grep -iE "coreauthd|LocalAuthentication|LAContext|ACM|policy|-100"
```

Note which action triggered each prompt. I need the `policy:` number, the
`failed: N` / `-100x` codes, and the process that asked. Also, from the mounted
`23H30` System volume, a class dump of `coreauthd` and `LocalAuthenticationCore`:

```sh
ipsw class-dump /path/to/mounted/System/.../Support/coreauthd > coreauthd.txt
```

Before that hook can deploy, confirm `coreauthd` has header room for the weak
load (launchd on 23H30 did not — that is why the hook path became
`/usr/lib/lhook`):

```sh
python3 device/launchdhook/patch_launchd.py \
  /path/to/mounted/System/.../Support/coreauthd --path /usr/lib/l8coreauth.dylib
```

If it reports "needs N bytes, only M available", I will shorten the path.

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
| `boot-jit` plan, `--tweaks` flag | done |
| `csprobe`, `personainfo` build | source done; build needs the iOS SDK |
| Resolvers match real 23H30 kernelcache | **pending your step 1 output** |
| Exact-build fixture | **pending step 2** |
| csprobe PASS on device | **pending step 4** |
| Passcode hook | **pending step 6 data** |
| Persona fix | **pending step 7 dump** |
| lhook sandbox-extension rework | **pending your diff on a branch** |
