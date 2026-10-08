#!/usr/bin/env python3
"""tweaks.list is the one list: its build, SSHRD install and post-boot activation agree."""

import io
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import unittest.mock
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEVICE = ROOT / "device"
sys.path.insert(0, str(DEVICE))
import liter8_tweaks  # noqa: E402
from liter8_tweaks import (  # noqa: E402
    Activation, TweakError, eligibility_applied, karing_groups, load_manifest,
    load_switches, sha256, sileo_target_entitlements,
)


def registry():
    files, markers = [], []
    for line in (DEVICE / "tweaks.list").read_text().splitlines():
        line = line.split("#", 1)[0].split()
        if not line:
            continue
        (files if line[0] == "file" else markers).append(line[1:])
    return files, markers


class RegistryTests(unittest.TestCase):
    def test_every_entry_is_built_by_its_component(self):
        files, markers = registry()
        self.assertTrue(files)
        for component, built, path, mode in files:
            builder = DEVICE / component / "build.sh"
            self.assertTrue(builder.is_file(), builder)
            self.assertTrue(os.access(builder, os.X_OK), builder)
            self.assertTrue(path.startswith("/var/jb/"), path)
            self.assertIn(mode, ("0644", "0755"))
            if built.endswith(".plist"):
                # Filters are source files, not build products.
                self.assertTrue((DEVICE / component / built).is_file(), built)
                self.assertTrue(path.startswith("/var/jb/usr/lib/TweakInject/"), path)
            else:
                self.assertIn(built.split(".")[0], (DEVICE / component / "build.sh").read_text())
            if path.startswith("/var/jb/usr/lib/TweakInject/") and built.endswith(".dylib"):
                # Every tweak has its filter, and its install name is where it lands.
                self.assertIn([component, built[:-6] + ".plist",
                               path[:-6] + ".plist", "0644"], files)
                self.assertIn(f"-install_name {path}", (DEVICE / component / "build.sh").read_text())
        names = [m[0] for m in markers]
        self.assertEqual(len(names), len(set(names)))
        for name, path, default in markers:
            self.assertEqual(path, f"/var/jb/.liter8-{name}")
            self.assertIn(default, ("on", "off"))

    def test_markers_match_the_paths_the_tweaks_check(self):
        _, markers = registry()
        paths = {name: path for name, path, _ in markers}
        self.assertIn('"/private' + paths["localauth"], (DEVICE / "localauthfix/l8localauth.m").read_text())
        self.assertIn('"/private' + paths["persona"], (DEVICE / "personafix/l8persona.m").read_text())
        self.assertIn(paths["files"], (DEVICE / "filesfix/l8files.m").read_text())
        self.assertIn("/private" + paths["vpn"], (DEVICE / "vpnfix/l8vpn.c").read_text())
        self.assertIn(paths["rootapps"], (DEVICE / "rootappfix/l8rootapps.m").read_text())
        # rootapps needs a runningboardd restart, so it is the one opt-in fix.
        self.assertEqual({n: d for n, _, d in markers}["rootapps"], "off")

    def test_helpers_are_where_the_activation_runs_them(self):
        files, _ = registry()
        installed = {path for _, _, path, _ in files}
        source = (DEVICE / "liter8_tweaks.py").read_text()
        for name in ("eligibility", "eligibility-persist", "deviceprefs", "l8vpn-issue",
                     "trolldecrypt-writer", "newterm-login", "newterm-helper"):
            self.assertIn(f"{liter8_tweaks.LIBEXEC}/{name}", installed)
            self.assertIn(name, source)
        # The login adapter execs exactly the backup the activation creates.
        self.assertIn('"/var/jb/usr/bin/login.liter8-real"',
                      (DEVICE / "appfix/newterm-login.c").read_text())

    def test_exception_port_guard_is_a_data_volume_tweak(self):
        source = (DEVICE / "excportfix/l8excport.c").read_text()
        builder = (DEVICE / "excportfix/build.sh").read_text()
        refuse = source.split("static bool kernel_would_refuse", 1)[1].split(
            "static void note_dropped", 1)[0]
        self.assertIn("case EXCEPTION_DEFAULT:", refuse)
        self.assertIn("case EXCEPTION_STATE_IDENTITY:", refuse)
        self.assertIn("MACH_PORT_VALID(port)", refuse)
        self.assertNotIn("IDENTITY_PROTECTED", refuse)
        self.assertIn("com.apple.private.set-exception-port", source)
        self.assertIn("_dyld_register_func_for_add_image(rebind_image)", source)
        self.assertIn("MH_DYLIB_IN_CACHE", source)
        self.assertIn("ptrauth_sign_unauthenticated(mine, ptrauth_key_asia, slot)", source)
        code = source.split("#include", 1)[1]
        self.assertNotIn("__interpose", code)
        self.assertNotIn("MSHookFunction", code)
        for name in ("task_set_exception_ports", "thread_set_exception_ports",
                     "task_swap_exception_ports", "thread_swap_exception_ports"):
            self.assertIn(f'{{"{name}"', source)
        self.assertEqual((DEVICE / "excportfix/l8excport.plist").read_text().strip(),
                         '{ Filter = { Bundles = ( "com.apple.UIKit" ); }; }')
        self.assertIn("sectname __interpose", builder)
        self.assertIn("LITER8_IOS_SDK", builder)

    @unittest.skipUnless(sys.platform == "darwin", "requires Xcode")
    def test_exception_port_guard_drops_refused_calls_on_the_host(self):
        result = subprocess.run([DEVICE / "excportfix/build.sh", "test"],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("control: ok", result.stdout)
        self.assertIn("shim: ok", result.stdout)


class WiringTests(unittest.TestCase):
    def test_every_stage_uses_the_list(self):
        fetch = (DEVICE / "fetch_payloads.sh").read_text()
        provision = (DEVICE / "sshrd_provision.sh").read_text()
        runner = (ROOT / "scripts/device_provision.py").read_text()
        self.assertIn("sileo helpers cache injection pairing tweaks", fetch)
        self.assertIn("./build_tweaks.sh", fetch)
        self.assertIn("cache jbtools tweaks sileo", provision)
        self.assertIn("payload/tweaks/MANIFEST", provision)
        self.assertIn("readback hash mismatch", provision)
        self.assertIn('note "tweaks.list payload"', provision)
        self.assertIn("markers-initialized", provision)
        self.assertIn('action == "tweaks"', runner)
        self.assertIn('"activate"', runner)
        self.assertIn('"tweaks": "device_provision.py"',
                      (ROOT / "Sources/Liter8CLI/FirmwareScriptRunner.swift").read_text())
        self.assertIn('"setup-shell", "tweaks"', (ROOT / "Sources/Liter8CLI/main.swift").read_text())
        self.assertIn("liter8 fw tweaks", (DEVICE / "finalize.sh").read_text())
        for gone in ("app-launch", "device-preferences", "files-local", "icleaner-root",
                     "icons-local", "karing-vpn", "marketplace-eligibility", "trolldecrypt-launch"):
            self.assertFalse((ROOT / "tools" / gone).exists(), gone)

    def test_provisioning_help_lists_the_step(self):
        environment = dict(os.environ, PATH="/usr/bin:/bin")
        result = subprocess.run([DEVICE / "sshrd_provision.sh", "--list"], capture_output=True,
                                text=True, env=environment, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("  tweaks   install every tweaks.list payload", result.stdout)

    def test_build_stages_exactly_the_listed_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            device = root / "device"
            device.mkdir()
            shutil.copy2(DEVICE / "build_tweaks.sh", device)
            (device / "tweaks.list").write_text(
                "# comment\n"
                "file one a.dylib /var/jb/usr/lib/TweakInject/a.dylib 0755\n"
                "file one a.plist /var/jb/usr/lib/TweakInject/a.plist 0644\n"
                "file two helper  /var/jb/usr/libexec/liter8/helper 0755\n"
                "marker a /var/jb/.liter8-a on\n"
                "marker b /var/jb/.liter8-b off\n")
            for component, outputs in (("one", "a.dylib"), ("two", "helper unlisted")):
                (device / component).mkdir()
                (device / component / "build.sh").write_text(
                    "".join(f"echo {name} > {name}\n" for name in outputs.split()))
            (device / "one/a.plist").write_text("{}")
            stubs = root / "bin"
            stubs.mkdir()
            for tool, body in (("codesign", "exit 0"), ("plutil", "exit 0"),
                               ("lipo", "echo arm64 arm64e")):
                (stubs / tool).write_text(f"#!/bin/sh\n{body}\n")
                (stubs / tool).chmod(0o755)
            environment = dict(os.environ, PATH=f"{stubs}:{os.environ['PATH']}")
            result = subprocess.run([device / "build_tweaks.sh"], capture_output=True,
                                    text=True, env=environment, check=False)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            out = device / "payload/tweaks"
            manifest = load_manifest(out)
            self.assertEqual([e.path for e in manifest], [
                "/var/jb/usr/lib/TweakInject/a.dylib", "/var/jb/usr/lib/TweakInject/a.plist",
                "/var/jb/usr/libexec/liter8/helper"])
            for entry in manifest:
                self.assertEqual(sha256((out / entry.staged).read_bytes()), entry.sha256)
            self.assertFalse((out / "root/usr/libexec/liter8/unlisted").exists())
            switches = load_switches(out)
            self.assertTrue(switches["a"].default)
            self.assertFalse(switches["b"].default)

            # A record the stages would misread stops the build, and keeps the old set.
            (device / "tweaks.list").write_text("file one a.dylib /usr/lib/a.dylib 0755\n")
            result = subprocess.run([device / "build_tweaks.sh"], capture_output=True,
                                    text=True, env=environment, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("is not under /var/jb", result.stderr)
            self.assertEqual(len(load_manifest(out)), 3)


class FakeDevice:
    """Just enough of Device for the sync and switch logic."""

    def __init__(self, files=None):
        self.fs = dict(files or {})
        self.commands = []

    def files(self, paths):
        return {p: self.fs[p] for p in paths if p in self.fs}

    def write(self, path, data, mode, owner="0:0"):
        self.fs[path] = data

    def touch_marker(self, path):
        self.fs[path] = b""

    def ok(self, command):
        match = re.fullmatch(r"test -f (\S+)", command)
        return bool(match) and match[1] in self.fs

    def run(self, command, **kwargs):
        self.commands.append(command)
        if "markers-initialized" in command:
            self.fs[liter8_tweaks.MARKERS_INITIALIZED] = b""
        return 0, b""


class ActivationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.payload = Path(self.directory.name)
        (self.payload / "root").mkdir()
        (self.payload / "root/a").write_bytes(b"new")
        (self.payload / "root/b").write_bytes(b"same")
        (self.payload / "MANIFEST").write_text(
            f"{sha256(b'new')} 0755 /var/jb/a root/a\n{sha256(b'same')} 0644 /var/jb/b root/b\n")
        (self.payload / "MARKERS").write_text(
            "files /var/jb/.liter8-files on\nrootapps /var/jb/.liter8-rootapps off\n")
        self.addCleanup(self.directory.cleanup)
        patcher = unittest.mock.patch.object(liter8_tweaks, "PAYLOAD", self.payload)
        patcher.start()
        self.addCleanup(patcher.stop)

    def activation(self, device, check=False):
        activation = Activation(device, check=check, build=False)
        activation.switches = load_switches(self.payload)
        return activation

    def test_sync_rewrites_only_what_differs(self):
        device = FakeDevice({"/var/jb/a": b"old", "/var/jb/b": b"same"})
        activation = self.activation(device)
        with redirect_stdout(io.StringIO()):
            activation.sync(load_manifest(self.payload))
        self.assertEqual(device.fs["/var/jb/a"], b"new")
        self.assertTrue(activation.changed_files)
        self.assertFalse(activation.report.failed)

    def test_check_reports_instead_of_writing(self):
        device = FakeDevice({"/var/jb/b": b"same"})
        activation = self.activation(device, check=True)
        output = io.StringIO()
        with redirect_stdout(output):
            activation.sync(load_manifest(self.payload))
        self.assertNotIn("/var/jb/a", device.fs)
        self.assertTrue(activation.report.failed)
        self.assertIn("MISSING", output.getvalue())

    def test_default_switches_are_created_once(self):
        device = FakeDevice()
        activation = self.activation(device)
        with redirect_stdout(io.StringIO()):
            activation.markers()
        self.assertIn("/var/jb/.liter8-files", device.fs)
        self.assertNotIn("/var/jb/.liter8-rootapps", device.fs)
        # Removed by the owner afterwards: a later activation leaves it off.
        del device.fs["/var/jb/.liter8-files"]
        with redirect_stdout(io.StringIO()):
            self.activation(device).markers()
        self.assertNotIn("/var/jb/.liter8-files", device.fs)


class LogicTests(unittest.TestCase):
    def test_eligibility_needs_all_seven_answers(self):
        plist = {f"OS_ELIGIBILITY_DOMAIN_{d}": {"os_eligibility_answer_t": 4,
                                                 "os_eligibility_answer_source_t": 2}
                 for d in liter8_tweaks.ELIGIBILITY_DOMAINS}
        self.assertTrue(eligibility_applied(plist))
        plist["OS_ELIGIBILITY_DOMAIN_ARGON"]["os_eligibility_answer_t"] = 2
        self.assertFalse(eligibility_applied(plist))
        self.assertFalse(eligibility_applied({}))

    def test_karing_group_comes_from_container_metadata(self):
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w") as archive:
            for uuid, identifier in (("A" * 8 + "-AAAA-AAAA-AAAA-" + "A" * 12, "group.other"),
                                     ("B" * 8 + "-BBBB-BBBB-BBBB-" + "B" * 12,
                                      liter8_tweaks.KARING_GROUP)):
                data = plistlib.dumps({"MCMMetadataIdentifier": identifier})
                info = tarfile.TarInfo(f"var/mobile/Containers/Shared/AppGroup/{uuid}/"
                                       ".com.apple.mobile_container_manager.metadata.plist")
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
        self.assertEqual(karing_groups(buffer.getvalue()), [
            "/private/var/mobile/Containers/Shared/AppGroup/BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"])
        self.assertEqual(karing_groups(b"not a tar"), [])

    def test_sileo_keeps_only_its_keychain_groups(self):
        target = sileo_target_entitlements({"get-task-allow": True,
                                            "keychain-access-groups": ["org.coolstar.SileoStore"]})
        self.assertNotIn("get-task-allow", target)
        self.assertEqual(target["keychain-access-groups"], ["org.coolstar.SileoStore"])
        self.assertTrue(target["com.apple.private.persona-mgmt"])

    def test_malformed_manifest_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "MANIFEST").write_text(f"{'0' * 64} 0755 /usr/lib/x root/x\n")
            with self.assertRaises(TweakError):
                load_manifest(Path(directory))


if __name__ == "__main__":
    unittest.main()
