#!/usr/bin/env python3
"""Repeat the iPad11,6 / 23H30 live Marketplace repair over localhost SSH."""
import argparse
import datetime
import pathlib
import plistlib
import shlex
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
HELPER = "/var/tmp/liter8-marketplace-eligibility"
LAUNCHCTL = "/var/tmp/liter8-marketplace-launchctl"
FILES = [
    "/var/jb/usr/lib/TweakInject/l8persona.dylib",
    "/var/jb/usr/lib/TweakInject/l8persona.plist",
    "/var/jb/usr/lib/TweakInject/l8localauth.dylib",
    "/var/jb/usr/lib/TweakInject/l8localauth.plist",
    "/var/jb/.liter8-persona",
    "/var/jb/.liter8-localauth",
]
JOBS = ["com.apple.installcoordinationd", "com.apple.mobile.installd",
        "com.apple.managedappdistributiond", "com.apple.appstorecomponentsd"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["apply", "restore"])
    parser.add_argument("backup", nargs="?", help="Device backup directory (required for restore)")
    parser.add_argument("--port", type=int, default=2222)
    args = parser.parse_args()
    if args.action == "restore" and not args.backup:
        parser.error("restore requires the backup directory printed by apply")
    backup = args.backup or ("/var/jb/var/backups/marketplace-" +
                            datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    if not backup.startswith("/var/jb/var/backups/"):
        parser.error("backup must be below /var/jb/var/backups/")
    ssh = [str(ROOT / "tools/sshpass"), "-p", "alpine", "ssh",
           "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
           "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=8",
           "-p", str(args.port), "root@localhost"]

    def remote(command, data=None):
        result = subprocess.run(ssh + [command], input=data, capture_output=True, timeout=60)
        if result.returncode:
            raise RuntimeError(result.stderr.decode(errors="replace") +
                               result.stdout.decode(errors="replace"))
        return result.stdout

    def upload(path, data, mode="755"):
        q = shlex.quote(path)
        remote(f"cat > {q}.new && chmod {mode} {q}.new && mv {q}.new {q}", data)

    # Build from reviewed source; no Apple executables are stored in Git.
    subprocess.run(["sh", "device/marketplacefix/build.sh"], cwd=ROOT, check=True)
    upload(HELPER, (ROOT / "device/marketplacefix/eligibility").read_bytes())
    print(remote(f"{HELPER} check").decode(), end="")

    # Procursus launchctl carries task_for_pid-allow, which kills it on this boot.
    # Keep its other entitlements in a temporary copy; leave the installed binary.
    with tempfile.TemporaryDirectory(prefix="liter8-launchctl-") as directory:
        binary = pathlib.Path(directory) / "launchctl"
        binary.write_bytes(remote("cat /var/jb/usr/bin/launchctl"))
        ldid = str(ROOT / "tools/ldid_macosx_arm64")
        ent = plistlib.loads(subprocess.check_output([ldid, "-e", str(binary)]))
        for key in ("task_for_pid-allow", "get-task-allow"):
            ent.pop(key, None)
        entfile = pathlib.Path(directory) / "entitlements.plist"
        entfile.write_bytes(plistlib.dumps(ent))
        subprocess.run([ldid, "-S" + str(entfile), "-Cadhoc", str(binary)], check=True)
        upload(LAUNCHCTL, binary.read_bytes())
    # Check the management tool before making persistent changes.
    remote(f"{LAUNCHCTL} print user/501/com.apple.installcoordinationd")
    qbackup = shlex.quote(backup)
    print("Backup directory:", backup, flush=True)
    if args.action == "apply":
        subprocess.run(["sh", "device/personafix/build.sh"], cwd=ROOT, check=True)
        subprocess.run(["sh", "device/localauthfix/build.sh"], cwd=ROOT, check=True)
        remote(f"test -f /var/jb/.lhook_enabled && mkdir -m 700 {qbackup}")
        # Snapshot present and absent files, including marker states.
        for path in FILES:
            source = shlex.quote(path)
            dest = shlex.quote(backup + "/" + pathlib.PurePosixPath(path).name)
            remote(f"if test -e {source}; then cp -p {source} {dest}; else : > {dest}.missing; fi")
        print(remote(f"{HELPER} apply {qbackup}/eligibility.plist").decode(), end="")
        for path in FILES[:4]:
            name = pathlib.PurePosixPath(path).name
            folder = "personafix" if name.startswith("l8persona") else "localauthfix"
            upload(path, (ROOT / "device" / folder / name).read_bytes(),
                   "755" if name.endswith(".dylib") else "644")
        for path in FILES[4:]:
            upload(path, b"", "600")
    else:
        remote(f"test -f {qbackup}/eligibility.plist")
        for path in FILES:
            source = shlex.quote(backup + "/" + pathlib.PurePosixPath(path).name)
            remote(f"test -f {source} || test -f {source}.missing")
        print(remote(f"{HELPER} restore {qbackup}/eligibility.plist").decode(), end="")
        for path in FILES:
            dest = shlex.quote(path)
            source = shlex.quote(backup + "/" + pathlib.PurePosixPath(path).name)
            remote(f"if test -f {source}.missing; then rm -f {dest}; "
                   f"else cp -p {source} {dest}.restore && mv {dest}.restore {dest}; fi")
    # Refresh only install/Marketplace jobs. No reboot or respring.
    for job in JOBS:
        remote(f"{LAUNCHCTL} kickstart -k user/501/{job}")
    print("Backup:", backup)
    print("Retry Marketplace installation in Safari; actual installation needs user consent.")


if __name__ == "__main__":
    main()
