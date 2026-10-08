#!/usr/bin/env python3
"""Activate and manage Liter8's Data-volume tweaks on a normally booted device.

This is the one post-boot entry point for every fix in tweaks.list. It replaces
the per-fix host tools that used to install, enable and restart things one at a
time (app-launch, device-preferences, files-local, icleaner-root, icons-local,
karing-vpn, marketplace-eligibility, trolldecrypt-launch, marketplacefix/repair.py).

  activate [--check] [--no-build]   per boot, after the UI is up: `liter8 fw tweaks`
  status                            the same report as `activate --check`
  enable NAME | disable NAME        flip a tweaks.list switch on the device
  restore-apps                      put NewTerm and rootless Sileo back as shipped
  eligibility status|lock|unlock|restore [BACKUP]

`activate` is idempotent and safe to repeat:

1. Rebuild payload/tweaks from source (build_tweaks.sh) and re-sync any file
   on the device whose hash differs. The payload lives on the Data volume, so a
   source change reaches the device without SSHRD.
2. Create the default switches once on a device provisioned before they existed.
3. `lhookctl enable` for this boot. Injection is bound to the boot session and
   is never enabled automatically during boot; see launchdhook/SESSION_GUARD.md.
4. Per-boot and self-healing steps, each behind its switch: Karing app-group
   grant, Marketplace eligibility answers, device preferences, app adapters.
5. Restart only the daemons whose tweaks must load after the enable (icons,
   FileProvider, the install jobs, runningboardd while `rootapps` is on), once
   per boot unless a tweak file changed, then respring.

Nothing here touches the System volume, the kernel or launchd's boot state.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import io
import os
import pathlib
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from dataclasses import dataclass

BASE = pathlib.Path(__file__).resolve().parent
TOOLS = BASE.parent / "tools"
PAYLOAD = BASE / "payload/tweaks"

RPATH = ("export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:"
         "/usr/bin:/bin:/usr/sbin:/sbin; ")
STATE_DIR = "/var/jb/etc/liter8"
MARKERS_INITIALIZED = STATE_DIR + "/markers-initialized"
ACTIVATED = STATE_DIR + "/activated"
LIBEXEC = "/var/jb/usr/libexec/liter8"
LAUNCHCTL = "/var/jb/usr/bin/launchctl"
LHOOKCTL = "/var/jb/usr/bin/lhookctl"
TWEAKLOADER = "/var/jb/usr/lib/TweakLoader.dylib"
SBEXTISSUE = "/usr/local/bin/sbextissue"
BACKUPS = "/var/jb/var/backups"

# Fixes validated only on this device and build. Their helpers carry the same
# guard, so this check just avoids running them pointlessly elsewhere.
IPAD8 = ("iPad11,6", "23H30")

ICON_RESULT = "/private/var/tmp/sbext.iconservicesagent.result"
INSTALL_JOBS = ("com.apple.installcoordinationd", "com.apple.mobile.installd",
                "com.apple.managedappdistributiond", "com.apple.appstorecomponentsd")

ELIGIBILITY = "/private/var/db/os_eligibility/eligibility.plist"
ELIGIBILITY_DOMAINS = ("HYDROGEN", "HELIUM", "LITHIUM", "CARBON", "ARGON",
                       "POTASSIUM", "SEARCH_MARKETPLACES")
ELIGIBILITY_LOCK_ACTIVE = BACKUPS + "/eligibility-lock.active"

MOBILEGESTALT = ("/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache"
                 "/Library/Caches/com.apple.MobileGestalt.plist")
MOBILEGESTALT_STAGE = "/var/tmp/l8-mobilegestalt-new.plist"  # fixed in deviceprefs/prefs.m
SRD_KEY = "XYlJKKkj2hztRP1NWWnhlw"
MANAGED_SHARINGD = "/var/Managed Preferences/mobile/com.apple.sharingd.plist"
SHARINGD = "/var/mobile/Library/Preferences/com.apple.sharingd.plist"

KARING_GROUP = "group.com.nebula.karing"
APPGROUPS = "/var/mobile/Containers/Shared/AppGroup"

NEWTERM_HELPER = "/var/jb/Applications/NewTerm.app/NewTermLoginHelper"
LOGIN = "/var/jb/usr/bin/login"
# (installed path, adapter in LIBEXEC, a string only the adapter contains)
NEWTERM_ADAPTERS = ((NEWTERM_HELPER, "newterm-helper", "l8newterm:"),
                    (LOGIN, "newterm-login", "l8login:"))
ICLEANER = "/var/jb/Applications/iCleaner.app/iCleaner"
SILEO = "/var/jb/Applications/Sileo.app/Sileo"
TROLLDECRYPT_ID = "com.fiore.trolldecrypt"
TROLLDECRYPT_STAGE = "/var/tmp/l8-TrollDecrypt.launch"  # fixed in trolldecryptfix/replace.c
TASKAC2 = "TASKAC2_ARM64_T8020"


class TweakError(RuntimeError):
    pass


# ----------------------------------------------------------------- registry
@dataclass(frozen=True)
class PayloadFile:
    sha256: str
    mode: str
    path: str
    staged: str


@dataclass(frozen=True)
class Switch:
    name: str
    path: str
    default: bool


def load_manifest(directory: pathlib.Path = PAYLOAD) -> list[PayloadFile]:
    entries = []
    for line in (directory / "MANIFEST").read_text().splitlines():
        fields = line.split()
        if len(fields) != 4 or not re.fullmatch(r"[0-9a-f]{64}", fields[0]) \
                or fields[1] not in ("0644", "0755") or not fields[2].startswith("/var/jb/") \
                or ".." in fields[2].split("/"):
            raise TweakError(f"malformed MANIFEST line: {line!r}")
        entries.append(PayloadFile(*fields))
    if not entries:
        raise TweakError("MANIFEST is empty; run build_tweaks.sh")
    return entries


def load_switches(directory: pathlib.Path = PAYLOAD) -> dict[str, Switch]:
    switches = {}
    for line in (directory / "MARKERS").read_text().splitlines():
        fields = line.split()
        if len(fields) != 3 or not fields[1].startswith("/var/jb/.liter8-") \
                or fields[2] not in ("on", "off"):
            raise TweakError(f"malformed MARKERS line: {line!r}")
        switches[fields[0]] = Switch(fields[0], fields[1], fields[2] == "on")
    return switches


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# -------------------------------------------------------------------- device
class Device:
    """Root SSH to a normally booted device, the same transport finalize uses."""

    def __init__(self, host: str, port: int):
        self.host, self.port = host, port
        sshpass = shutil.which("sshpass")
        if not sshpass or subprocess.run([sshpass, "-V"], capture_output=True).returncode:
            sshpass = str(TOOLS / "sshpass")
        self.ssh = [sshpass, "-p", "alpine", "ssh",
                    "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                    "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=25",
                    "-o", "HostKeyAlgorithms=+ecdsa-sha2-nistp521", "-o", "Ciphers=+aes128-ctr",
                    "-p", str(port), f"root@{host}"]
        self.iproxy = None

    def connect(self) -> None:
        if self.run("exit 0", check=False, timeout=40)[0] == 0:
            return
        if (self.host, self.port) != ("localhost", 2222) or not shutil.which("iproxy"):
            raise TweakError(f"cannot reach root SSH on {self.host}:{self.port}")
        # Owned forward, stopped by close() on every exit path.
        self.iproxy = subprocess.Popen(["iproxy", "2222:22"], stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL)
        time.sleep(2)
        if self.run("exit 0", check=False, timeout=40)[0] != 0:
            raise TweakError("cannot reach root SSH on localhost:2222 (is the device booted?)")

    def close(self) -> None:
        if self.iproxy:
            self.iproxy.terminate()
            self.iproxy.wait()

    def run(self, command: str, data: bytes | None = None, check: bool = True,
            timeout: int = 180) -> tuple[int, bytes]:
        result = subprocess.run(self.ssh + [RPATH + command], input=data,
                                capture_output=True, timeout=timeout)
        if check and result.returncode:
            raise TweakError(f"device command failed ({result.returncode}): {command}\n"
                             + result.stderr.decode(errors="replace").strip())
        return result.returncode, result.stdout

    def out(self, command: str, **kwargs) -> str:
        return self.run(command, **kwargs)[1].decode(errors="replace").strip()

    def ok(self, command: str) -> bool:
        return self.run(command, check=False)[0] == 0

    def read(self, path: str) -> bytes | None:
        code, data = self.run(f"cat {shlex.quote(path)}", check=False)
        return data if code == 0 else None

    def write(self, path: str, data: bytes, mode: str, owner: str = "0:0") -> None:
        """Same-directory staging, one rename, then a hash readback."""
        q, tmp = shlex.quote(path), shlex.quote(path + ".liter8-new")
        self.run(f"mkdir -p {shlex.quote(str(pathlib.PurePosixPath(path).parent))} && "
                 f"cat > {tmp} && chown {owner} {tmp} && chmod {mode} {tmp} && mv -f {tmp} {q}",
                 data=data)
        if sha256(self.read(path) or b"") != sha256(data):
            raise TweakError(f"{path} readback hash mismatch")

    def touch_marker(self, path: str) -> None:
        q = shlex.quote(path)
        self.run(f"umask 077; : > {q} && chown 0:0 {q} && chmod 0600 {q}")

    def files(self, paths: list[str]) -> dict[str, bytes]:
        """Fetch several files in one round trip; missing ones are simply absent."""
        if not paths:
            return {}
        names = " ".join(shlex.quote(p.lstrip("/")) for p in paths)
        _, raw = self.run(f"cd / && tar -cf - {names} 2>/dev/null; exit 0", check=False)
        found = {}
        try:
            with tarfile.open(fileobj=io.BytesIO(raw)) as archive:
                for member in archive:
                    if member.isfile():
                        found["/" + member.name.lstrip("./")] = archive.extractfile(member).read()
        except tarfile.TarError:
            pass
        return found


def clear_icleaner_jobs(device: Device, launchctl: str = LAUNCHCTL) -> None:
    """A cached app job keeps its old UserName, so only iCleaner's are removed."""
    for line in device.out(f"{launchctl} list", check=False).splitlines():
        fields = line.split()
        if fields and fields[-1].startswith("UIKitApplication:com.ivanobilenchi.icleaner["):
            device.run(f"{launchctl} bootout {shlex.quote('user/501/' + fields[-1])}", check=False)


# -------------------------------------------------------------------- report
class Report:
    def __init__(self):
        self.failed = False

    def line(self, item: str, state: str, failure: bool = False) -> None:
        print(f"    {item:<26} {state}")
        self.failed |= failure

    @staticmethod
    def say(text: str) -> None:
        print(f"\n\033[1m==> {text}\033[0m", flush=True)


def ldid_path() -> str:
    """The bundled arm64 ldid, else PATH's; ldid -v exits non-zero even when it works."""
    for candidate in (str(TOOLS / "ldid_macosx_arm64"), shutil.which("ldid")):
        if not candidate:
            continue
        try:
            probe = subprocess.run([candidate, "-v"], capture_output=True, text=True)
        except OSError:
            continue
        if "Link Identity Editor" in probe.stdout + probe.stderr:
            return candidate
    raise TweakError("no runnable ldid; brew install ldid-procursus")


def slice_entitlements(ldid: str, binary: pathlib.Path) -> dict:
    """Entitlements of a fat binary, refusing slices that disagree."""
    raw = subprocess.run([ldid, "-e", str(binary)], capture_output=True, check=True).stdout
    parts = [plistlib.loads(b"<?xml" + part) for part in raw.split(b"<?xml")[1:]]
    if not parts:
        return {}
    if any(part != parts[0] for part in parts):
        raise TweakError(f"{binary.name} slices carry different entitlements")
    return parts[0]


# ---------------------------------------------------------------- pure logic
def eligibility_answers(plist: dict) -> dict[str, tuple]:
    return {d: (plist.get("OS_ELIGIBILITY_DOMAIN_" + d, {}).get("os_eligibility_answer_t"),
                plist.get("OS_ELIGIBILITY_DOMAIN_" + d, {}).get("os_eligibility_answer_source_t"))
            for d in ELIGIBILITY_DOMAINS}


def eligibility_applied(plist: dict) -> bool:
    return all(answer == (4, 2) for answer in eligibility_answers(plist).values())


def sileo_target_entitlements(original: dict) -> dict:
    """The AMFI-safe persona/spawn set, keeping Sileo's own Keychain groups."""
    target = plistlib.loads((BASE / "spawnprobe/e_both.plist").read_bytes())
    if "keychain-access-groups" in original:
        target["keychain-access-groups"] = original["keychain-access-groups"]
    return target


def karing_groups(raw_tar: bytes) -> list[str]:
    groups = []
    try:
        with tarfile.open(fileobj=io.BytesIO(raw_tar)) as archive:
            for member in archive:
                if not member.isfile() or member.size > 65536:
                    continue
                try:
                    metadata = plistlib.load(archive.extractfile(member))
                except Exception:
                    continue
                if metadata.get("MCMMetadataIdentifier") == KARING_GROUP:
                    groups.append("/private/" + str(pathlib.PurePosixPath(
                        member.name.lstrip("./")).parent))
    except tarfile.TarError:
        pass
    return groups


# ------------------------------------------------------------------ activate
class Activation:
    def __init__(self, device: Device, check: bool, build: bool):
        self.device, self.check, self.build = device, check, build
        self.report = Report()
        self.switches: dict[str, Switch] = {}
        self.changed_files = False
        self.launchctl = LAUNCHCTL

    # -- helpers
    def on(self, name: str) -> bool:
        switch = self.switches.get(name)
        return bool(switch) and self.device.ok(f"test -f {shlex.quote(switch.path)}")

    def kickstart(self, target: str) -> bool:
        return self.device.ok(f"{self.launchctl} kickstart -k {shlex.quote(target)}")

    # -- steps
    def preflight(self) -> None:
        Report.say("normal-boot connection")
        self.device.connect()
        if "md0 on /" in self.device.out("/sbin/mount"):
            raise TweakError("device is in SSHRD; fw tweaks needs a normal boot")
        self.machine, self.build_id = self.device.out("sysctl -n hw.machine kern.osversion").split()[:2]
        self.boot = self.device.out("sysctl -n kern.bootsessionuuid")
        self.kernel = self.device.out("uname -v")
        self.ipad8 = (self.machine, self.build_id) == IPAD8
        self.report.line("device", f"{self.machine} {self.build_id}")
        if not self.ipad8:
            self.report.line("iPad 8 fixes", "skipped: validated on iPad11,6 / 23H30 only")

    def payload(self) -> list[PayloadFile]:
        Report.say("payload (tweaks.list)")
        if self.build and not self.check:
            subprocess.run([str(BASE / "build_tweaks.sh")], check=True)
        if not (PAYLOAD / "MANIFEST").is_file():
            raise TweakError("payload/tweaks is not built; run without --check or build_tweaks.sh")
        manifest = load_manifest()
        self.switches = load_switches()
        for entry in manifest:
            if sha256((PAYLOAD / entry.staged).read_bytes()) != entry.sha256:
                raise TweakError(f"{entry.staged} does not match its manifest hash")
        return manifest

    def sync(self, manifest: list[PayloadFile]) -> None:
        current = self.device.files([e.path for e in manifest])
        stale = [e for e in manifest if sha256(current.get(e.path, b"")) != e.sha256]
        for entry in stale:
            if self.check:
                self.report.line(entry.path.rsplit("/", 1)[1],
                                 "MISSING" if entry.path not in current else "MISMATCH", True)
                continue
            self.device.write(entry.path, (PAYLOAD / entry.staged).read_bytes(), entry.mode)
            self.report.line(entry.path.rsplit("/", 1)[1], "updated")
            self.changed_files = True
        if not stale:
            self.report.line("installed files", f"{len(manifest)} match the payload")

    def markers(self) -> None:
        Report.say("switches")
        if not self.device.ok(f"test -f {MARKERS_INITIALIZED}") and not self.check:
            for switch in self.switches.values():
                if switch.default:
                    self.device.touch_marker(switch.path)
            self.device.run(f"mkdir -p {STATE_DIR} && : > {MARKERS_INITIALIZED}")
            self.report.line("defaults", "created (first activation)")
        for switch in self.switches.values():
            self.report.line(switch.name, "on" if self.on(switch.name) else "off")

    def injection(self) -> bool:
        Report.say("injection")
        if not self.device.ok("test -f /usr/lib/lhook") or not self.device.ok(f"test -x {LHOOKCTL}"):
            self.report.line("lhook", "MISSING: provision the injection step from SSHRD", True)
            return False
        if not self.device.ok(f"test -f {TWEAKLOADER}"):
            self.report.line("ElleKit", "MISSING: install ElleKit from Sileo, then rerun", True)
            return False
        self.report.line("ElleKit", "present")
        if self.device.out(f"{LHOOKCTL} status") == "enabled for this boot":
            self.report.line("lhook", "enabled for this boot")
        elif self.check:
            self.report.line("lhook", "PENDING: not enabled for this boot", True)
        else:
            print(self.device.out(f"{LHOOKCTL} enable"))
            self.report.line("lhook", "enabled for this boot")
        if not self.device.ok(f"{LAUNCHCTL} version >/dev/null 2>&1"):
            # The bootstrap's Procursus package can bring back a launchctl that
            # dies before main; device/launchctl is the reviewed iOS 26+ build.
            fallback = LIBEXEC + "/launchctl"
            if not self.check:
                self.device.write(fallback, (BASE / "launchctl/launchctl").read_bytes(), "0755")
            self.launchctl = fallback
            self.report.line("launchctl", f"bootstrap copy cannot run; using {fallback}")
        return True

    def karing(self) -> None:
        if not self.on("vpn"):
            return
        raw = self.device.run(f"tar -cf - {APPGROUPS}/*/.com.apple.mobile_container_manager"
                              ".metadata.plist 2>/dev/null; exit 0", check=False)[1]
        groups = karing_groups(raw)
        if not groups:
            self.report.line("Karing grant", "skipped: Karing is not installed")
        elif len(groups) > 1:
            self.report.line("Karing grant", f"FAILED: {len(groups)} Karing app groups", True)
        elif self.check:
            present = self.device.ok("test -s /var/jb/etc/liter8-vpn/karing.token")
            self.report.line("Karing grant", "token present" if present else "PENDING")
        else:
            self.device.run("mkdir -p /var/jb/etc/liter8-vpn && chown 0:501 /var/jb/etc/liter8-vpn"
                            " && chmod 750 /var/jb/etc/liter8-vpn")
            self.device.run(f"{LIBEXEC}/l8vpn-issue {shlex.quote(groups[0])}")
            self.report.line("Karing grant", "issued for this boot; reconnect the VPN")

    def marketplace(self) -> None:
        if not self.on("marketplace"):
            return
        raw = self.device.read(ELIGIBILITY)
        if raw is None:
            self.report.line("Marketplace eligibility", "MISSING eligibility.plist", True)
            return
        if eligibility_applied(plistlib.loads(raw)):
            self.report.line("Marketplace eligibility", "answers in place")
            return
        if "file_locked=1" in self.device.out(f"{LIBEXEC}/eligibility-persist status", check=False):
            self.report.line("Marketplace eligibility",
                             "LOCKED with other answers; eligibility unlock first", True)
            return
        if self.check:
            self.report.line("Marketplace eligibility", "PENDING", True)
            return
        backup = BACKUPS + "/marketplace-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        self.device.run(f"mkdir -p {BACKUPS} && mkdir -m 700 {shlex.quote(backup)}")
        self.device.run(f"{LIBEXEC}/eligibility apply {shlex.quote(backup)}/eligibility.plist")
        self.report.line("Marketplace eligibility", f"applied; original in {backup}")
        self.changed_files = True  # the install jobs must reread it

    def deviceprefs(self) -> None:
        if not self.on("deviceprefs"):
            return
        gestalt = plistlib.loads(self.device.read(MOBILEGESTALT) or plistlib.dumps({}))
        managed = plistlib.loads(self.device.read(MANAGED_SHARINGD) or plistlib.dumps({}))
        sharing = plistlib.loads(self.device.read(SHARINGD) or plistlib.dumps({}))
        done = (gestalt.get("CacheExtra", {}).get(SRD_KEY) == 1
                and managed.get("OverrideTimeLimitEveryoneMode") is True
                and sharing.get("DiscoverableMode") == "Everyone")
        if done:
            self.report.line("device preferences", "SRD flag and AirDrop Everyone in place")
            return
        if self.check:
            self.report.line("device preferences", "PENDING", True)
            return
        if not isinstance(gestalt.get("CacheExtra"), dict):
            self.report.line("device preferences", "FAILED: no MobileGestalt CacheExtra", True)
            return
        backup = BACKUPS + "/deviceprefs-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        self.device.run(f"mkdir -p {shlex.quote(backup)}")
        for path, name in ((MOBILEGESTALT, "MobileGestalt.plist"),
                           (MANAGED_SHARINGD, "managed-sharingd.plist"),
                           (SHARINGD, "sharingd.plist")):
            q, dest = shlex.quote(path), shlex.quote(f"{backup}/{name}")
            self.device.run(f"if test -f {q}; then cp -p {q} {dest}; else : > {dest}.absent; fi")
        gestalt["CacheExtra"][SRD_KEY] = 1
        self.device.run(f"cat > {MOBILEGESTALT_STAGE}",
                        data=plistlib.dumps(gestalt, fmt=plistlib.FMT_BINARY))
        self.device.run(f"{LIBEXEC}/deviceprefs mg-write && rm -f {MOBILEGESTALT_STAGE}")
        managed["OverrideTimeLimitEveryoneMode"] = True
        self.device.write(MANAGED_SHARINGD, plistlib.dumps(managed, fmt=plistlib.FMT_BINARY),
                          "0644", owner="501:501")
        self.device.run(f"{LIBEXEC}/deviceprefs airdrop")
        self.device.run("killall sharingd 2>/dev/null; exit 0", check=False)
        self.report.line("device preferences", f"applied; originals in {backup}")

    def apps(self) -> None:
        if not self.on("apps"):
            return
        self.icleaner()
        self.newterm()
        self.sileo()
        self.trolldecrypt()

    def icleaner(self) -> None:
        real = shlex.quote(ICLEANER + ".liter8-real")
        found = self.device.files([ICLEANER, ICLEANER + ".liter8-real"])
        if ICLEANER + ".liter8-real" not in found:
            return
        # The old parent/child proxy showed a black window; rootapps replaces it.
        if found.get(ICLEANER) == found[ICLEANER + ".liter8-real"]:
            self.report.line("iCleaner", "original executable")
        elif self.check:
            self.report.line("iCleaner", "PENDING: failed proxy still installed", True)
        else:
            tmp = shlex.quote(ICLEANER + ".liter8-new")
            self.device.run(f"cp -p {real} {tmp} && mv -f {tmp} {shlex.quote(ICLEANER)}")
            self.report.line("iCleaner", "failed proxy removed, original restored")

    def newterm(self) -> None:
        if not self.device.ok(f"test -f {shlex.quote(NEWTERM_HELPER)}"):
            return
        for path, adapter, signature in NEWTERM_ADAPTERS:
            q, real = shlex.quote(path), shlex.quote(path + ".liter8-real")
            source = f"{LIBEXEC}/{adapter}"
            found = self.device.files([path, source])
            if source not in found:
                raise TweakError(f"{source} is missing; the payload sync did not install it")
            if found.get(path) == found[source]:
                self.report.line(pathlib.PurePosixPath(path).name, "NewTerm adapter in place")
                continue
            if self.check:
                self.report.line(pathlib.PurePosixPath(path).name, "PENDING: adapter not installed",
                                 True)
                continue
            # Anything without the adapter's log string is the real program, for
            # example after a package upgrade, and becomes the new .liter8-real.
            # An older adapter is replaced without touching the saved original,
            # because the login adapter execs .liter8-real.
            if path in found and signature.encode() not in found[path]:
                tmp = shlex.quote(path + ".liter8-real.new")
                self.device.run(f"cp -p {q} {tmp} && mv -f {tmp} {real}")
            if not self.device.ok(f"test -f {real}"):
                raise TweakError(f"{path}.liter8-real is missing; refusing to install the adapter")
            tmp = shlex.quote(path + ".liter8-new")
            self.device.run(f"cp {shlex.quote(source)} {tmp} && chown 0:0 {tmp} && chmod 755 {tmp}"
                            f" && mv -f {tmp} {q}")
            self.report.line(pathlib.PurePosixPath(path).name, "NewTerm adapter installed")

    def sileo(self) -> None:
        binary = self.device.read(SILEO)
        if binary is None:
            return
        ldid = ldid_path()
        with tempfile.TemporaryDirectory(prefix="liter8-sileo-") as work:
            local = pathlib.Path(work) / "Sileo"
            local.write_bytes(binary)
            current = slice_entitlements(ldid, local)
            target = sileo_target_entitlements(current)
            if current == target:
                self.report.line("rootless Sileo", "signature in place")
                return
            if self.check:
                self.report.line("rootless Sileo", "PENDING: unsupported entitlements", True)
                return
            entitlements = pathlib.Path(work) / "entitlements.plist"
            entitlements.write_bytes(plistlib.dumps(target))
            subprocess.run([ldid, f"-S{entitlements}", "-Cadhoc", str(local)], check=True)
            if slice_entitlements(ldid, local) != target:
                raise TweakError("Sileo entitlement verification failed")
            q = shlex.quote(SILEO)
            # The binary as shipped (current version), kept for restore-apps.
            self.device.run(f"cp -p {q} {shlex.quote(SILEO + '.liter8-before.new')} && "
                            f"mv -f {shlex.quote(SILEO + '.liter8-before.new')} "
                            f"{shlex.quote(SILEO + '.liter8-before')}")
            self.device.write(SILEO, local.read_bytes(), "0755")
            self.device.run("uicache -p /var/jb/Applications/Sileo.app")
            self.report.line("rootless Sileo", "re-signed with the AMFI-safe set")

    def trolldecrypt(self) -> None:
        paths = self.device.out("find /var/containers/Bundle/Application -path "
                                "'*/TrollDecrypt.app/TrollDecrypt' -type f 2>/dev/null",
                                check=False).splitlines()
        if not paths:
            return
        if TASKAC2 not in self.kernel:
            self.report.line("TrollDecrypt", "skipped: needs the TASKAC2 kernel")
            return
        if len(paths) != 1:
            self.report.line("TrollDecrypt", f"FAILED: {len(paths)} installs", True)
            return
        path = paths[0]
        match = re.fullmatch(r"/var/containers/Bundle/Application/([0-9a-fA-F-]{36})"
                             r"/TrollDecrypt.app/TrollDecrypt", path)
        info = plistlib.loads(self.device.read(str(pathlib.PurePosixPath(path).parent
                                                   / "Info.plist")) or plistlib.dumps({}))
        if not match or info.get("CFBundleIdentifier") != TROLLDECRYPT_ID:
            self.report.line("TrollDecrypt", "FAILED: unexpected bundle", True)
            return
        ldid = ldid_path()
        with tempfile.TemporaryDirectory(prefix="liter8-trolldecrypt-") as work:
            original = pathlib.Path(work) / "original"
            original.write_bytes(self.device.read(path) or b"")
            expected = slice_entitlements(ldid, original)
            if "task_for_pid-allow" not in expected:
                self.report.line("TrollDecrypt", "launch signature in place")
                return
            if self.check:
                self.report.line("TrollDecrypt", "PENDING: carries task_for_pid-allow", True)
                return
            backup = (BASE / "payload/.work/trolldecrypt-backups"
                      / datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f"))
            backup.mkdir(parents=True)
            shutil.copy2(original, backup / "TrollDecrypt.original")
            (backup / "device-path.txt").write_text(path + "\n")
            expected.pop("task_for_pid-allow")
            entitlements = pathlib.Path(work) / "app.entitlements"
            entitlements.write_bytes(plistlib.dumps(expected))
            replacement = pathlib.Path(work) / "replacement"
            shutil.copy2(original, replacement)
            subprocess.run([ldid, f"-S{entitlements}", "-Cadhoc", str(replacement)], check=True)
            if slice_entitlements(ldid, replacement) != expected:
                raise TweakError("TrollDecrypt entitlement verification failed")
            self.device.run(f"cat > {TROLLDECRYPT_STAGE}", data=replacement.read_bytes())
            if self.device.read(path) != original.read_bytes():
                raise TweakError("TrollDecrypt changed during preparation; nothing replaced")
            self.device.run(f"{LIBEXEC}/trolldecrypt-writer {match[1]}")
            self.device.run(f"rm -f {TROLLDECRYPT_STAGE}")
            if sha256(self.device.read(path) or b"") != sha256(replacement.read_bytes()):
                raise TweakError("TrollDecrypt readback mismatch")
            self.report.line("TrollDecrypt", f"launch signature repaired; original in {backup}")

    def restart(self) -> None:
        """Once per boot, plus whenever a tweak file changed: the daemons below
        were running before lhookctl enable, so they hold no tweaks yet."""
        Report.say("daemons")
        stamp = self.device.out(f"cat {ACTIVATED} 2>/dev/null", check=False)
        if stamp == self.boot and not self.changed_files:
            self.report.line("restarts", "already done this boot")
            return
        if self.check:
            self.report.line("restarts", "PENDING for this boot", True)
            return

        # Icons: fresh read token, then the agent consumes it on its next start.
        result = ""
        if not self.device.ok(f"rm -f {ICON_RESULT}; {SBEXTISSUE}"):
            result = f"{SBEXTISSUE} could not issue the read token"
        elif not self.kickstart("user/501/com.apple.iconservices.iconservicesagent"):
            result = "iconservicesagent did not restart"
        for _ in range(0 if result else 15):
            result = self.device.out(f"cat {ICON_RESULT} 2>/dev/null", check=False)
            if result:
                break
            time.sleep(1)
        if "consume OK, /var/jb verified readable" in result:
            self.device.run('for app in /var/jb/Applications/*.app; do [ -d "$app" ] || continue; '
                            'uicache -p "$app" || exit; done')
            self.report.line("icons", "grant verified, rootless apps re-registered")
        else:
            self.report.line("icons", f"FAILED: {result or 'no grant result'}", True)

        if self.ipad8 and self.on("files"):
            self.files_provider()
        if any(self.on(name) for name in ("persona", "localauth", "marketplace")):
            for job in INSTALL_JOBS:
                self.kickstart(f"user/501/{job}")
            self.report.line("install jobs", "restarted with persona/passcode tweaks")
        if self.ipad8 and self.on("rootapps"):
            self.kickstart("system/com.apple.runningboardd")
            clear_icleaner_jobs(self.device, self.launchctl)
            self.report.line("runningboardd", "restarted for rootapps")
        # A failed restart is retried by the next run instead of being skipped.
        if not self.report.failed:
            self.device.run(f"mkdir -p {STATE_DIR} && printf '%s' {shlex.quote(self.boot)}"
                            f" > {ACTIVATED}")

    def files_provider(self) -> None:
        self.kickstart("user/501/com.apple.FileProvider")
        seen = set()
        for _ in range(10):
            for row in self.device.out("ps -axo pid=,comm=", check=False).splitlines():
                fields = row.split()
                if len(fields) == 2 and fields[1].endswith("/fileproviderd"):
                    seen.add(fields[0])
            if len(seen) > 2:
                # Same guard files-local had: a crash loop turns the switch off.
                self.device.run(f"rm -f {shlex.quote(self.switches['files'].path)}")
                self.kickstart("user/501/com.apple.FileProvider")
                self.report.line("Files", "FAILED: fileproviderd kept exiting; switch turned off",
                                 True)
                return
            time.sleep(2)
        self.report.line("Files", "FileProvider restarted with the local volume view")

    def run(self) -> int:
        self.preflight()
        manifest = self.payload()
        self.sync(manifest)
        self.markers()
        injected = self.injection()
        if self.ipad8:
            Report.say("per-boot and self-healing fixes")
            self.karing()
            self.marketplace()
            self.deviceprefs()
            self.apps()
        if injected:
            self.restart()
        if self.check:
            print("\n    tweaks are " + ("NOT fully active; run liter8 fw tweaks"
                                         if self.report.failed else "active for this boot"))
            return 1 if self.report.failed else 0
        if self.report.failed:
            print("\n    something above needs attention; nothing was respringed")
            return 1
        Report.say("SpringBoard restart")
        self.device.run("killall -9 SpringBoard", check=False)
        print("\n[+] Liter8 tweaks active for this boot")
        return 0


# ----------------------------------------------------------- other commands
def set_switch(device: Device, name: str, enabled: bool) -> None:
    switches = load_switches()
    if name not in switches:
        raise TweakError(f"unknown switch {name}; known: {', '.join(sorted(switches))}")
    path = shlex.quote(switches[name].path)
    if enabled:
        device.touch_marker(switches[name].path)
    else:
        device.run(f"rm -f {path}")
    if name == "rootapps":
        clear_icleaner_jobs(device)
    print(f"{name}: {'on' if enabled else 'off'}. Run liter8 fw tweaks (or relaunch the "
          "affected app) for it to take effect.")


def restore_apps(device: Device) -> None:
    switches = load_switches()
    device.run(f"rm -f {shlex.quote(switches['apps'].path)}")
    for path, _, _ in NEWTERM_ADAPTERS:
        q, real, tmp = (shlex.quote(path), shlex.quote(path + ".liter8-real"),
                        shlex.quote(path + ".liter8-new"))
        if device.ok(f"test -f {real}"):
            device.run(f"cp -p {real} {tmp} && mv -f {tmp} {q}")
            print(f"restored {path}")
    before = shlex.quote(SILEO + ".liter8-before")
    if device.ok(f"test -f {before}"):
        tmp = shlex.quote(SILEO + ".liter8-new")
        device.run(f"cp -p {before} {tmp} && mv -f {tmp} {shlex.quote(SILEO)} && "
                   "uicache -p /var/jb/Applications/Sileo.app")
        print(f"restored {SILEO}")
    print("apps switch is off; close and reopen the apps")


def eligibility(device: Device, action: str, backup: str | None) -> None:
    writer, freezer = LIBEXEC + "/eligibility", LIBEXEC + "/eligibility-persist"
    if backup and (not backup.startswith(BACKUPS + "/") or ".." in backup.split("/")):
        raise TweakError(f"backup must be below {BACKUPS}/ without ..")
    print(device.out(f"{writer} check"))
    if action == "lock":
        flags = device.out(f"{freezer} status")
        if "file_locked=1" in flags or "directory_locked=1" in flags:
            print(flags + "\nalready protected; existing rollback state kept")
            return
        backup = BACKUPS + "/eligibility-lock-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        qb = shlex.quote(backup)
        device.run(f"mkdir -p {BACKUPS} && mkdir -m 700 {qb}")
        print(device.out(f"{writer} apply {qb}/eligibility.plist"))
        print(device.out(f"{freezer} lock {qb}/flags.plist"))
        device.run(f"cat > {ELIGIBILITY_LOCK_ACTIVE}.new && chmod 600 {ELIGIBILITY_LOCK_ACTIVE}.new"
                   f" && mv {ELIGIBILITY_LOCK_ACTIVE}.new {ELIGIBILITY_LOCK_ACTIVE}",
                   data=(backup + "\n").encode())
        print("backup:", backup)
    elif action in ("unlock", "restore"):
        if not backup:
            backup = device.out(f"cat {ELIGIBILITY_LOCK_ACTIVE} 2>/dev/null", check=False)
        if not backup:
            raise TweakError("name the backup directory printed when the change was made")
        qb = shlex.quote(backup)
        device.run(f"test -f {qb}/eligibility.plist")
        if device.ok(f"test -f {qb}/flags.plist"):
            print(device.out(f"{freezer} unlock {qb}/flags.plist"))
            device.run(f'if test "$(cat {ELIGIBILITY_LOCK_ACTIVE} 2>/dev/null)" = {qb}; then '
                       f"rm -f {ELIGIBILITY_LOCK_ACTIVE}; fi")
        if action == "restore":
            print(device.out(f"{writer} restore {qb}/eligibility.plist"))
            # Otherwise the next activation would simply apply the answers again.
            device.run(f"rm -f {shlex.quote(load_switches()['marketplace'].path)}")
            print("marketplace switch is off")
    print(device.out(f"{freezer} status", check=False))
    answers = eligibility_answers(plistlib.loads(device.read(ELIGIBILITY) or plistlib.dumps({})))
    for domain, answer in answers.items():
        print(f"{domain} {answer[0]} {answer[1]}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default=os.environ.get("LITER8_SSH_HOST", "localhost"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("LITER8_SSH_PORT", "2222")))
    commands = parser.add_subparsers(dest="command", required=True)
    activate = commands.add_parser("activate")
    activate.add_argument("--check", action="store_true")
    activate.add_argument("--no-build", action="store_true")
    commands.add_parser("status")
    for name in ("enable", "disable"):
        commands.add_parser(name).add_argument("switch")
    commands.add_parser("restore-apps")
    elig = commands.add_parser("eligibility")
    elig.add_argument("action", choices=("status", "lock", "unlock", "restore"))
    elig.add_argument("backup", nargs="?")
    args = parser.parse_args(argv)

    device = Device(args.host, args.port)
    try:
        if args.command in ("activate", "status"):
            check = args.command == "status" or args.check
            build = args.command == "activate" and not args.no_build
            return Activation(device, check, build).run()
        device.connect()
        if args.command in ("enable", "disable"):
            set_switch(device, args.switch, args.command == "enable")
        elif args.command == "restore-apps":
            restore_apps(device)
        else:
            eligibility(device, args.action, args.backup)
        return 0
    except (TweakError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"    [!] {error}", file=sys.stderr)
        return 1
    finally:
        device.close()


if __name__ == "__main__":
    sys.exit(main())
