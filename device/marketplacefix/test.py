#!/usr/bin/env python3
"""Exercise the actual writer with temporary host plists, never device data."""
import copy
import pathlib
import plistlib
import subprocess
import tempfile

DOMAINS = ["HYDROGEN", "HELIUM", "LITHIUM", "CARBON", "ARGON", "POTASSIUM", "SEARCH_MARKETPLACES"]
with tempfile.TemporaryDirectory(prefix="liter8-eligibility-test-") as directory:
    root = pathlib.Path(directory)
    target, backup, binary = root / "eligibility.plist", root / "backup.plist", root / "writer"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                    "-DLITER8_ELIGIBILITY_HOST_TEST", '-DL8_ELIGIBILITY_TARGET="' + str(target) + '"',
                    str(pathlib.Path(__file__).with_name("eligibility.m")), "-o", str(binary)], check=True)
    original = {"unrelated": {"answer": 1}, **{
        "OS_ELIGIBILITY_DOMAIN_" + name: {"os_eligibility_answer_t": 2,
          "os_eligibility_answer_source_t": 0, "context": {"country": "unchanged"}}
        for name in DOMAINS}}
    raw = plistlib.dumps(original)
    target.write_bytes(raw)
    target.chmod(0o640)
    subprocess.run([str(binary), "apply", str(backup)], check=True)
    expected = copy.deepcopy(original)
    for name in DOMAINS:
        expected["OS_ELIGIBILITY_DOMAIN_" + name].update(
            os_eligibility_answer_t=4, os_eligibility_answer_source_t=2)
    assert plistlib.loads(target.read_bytes()) == expected
    assert backup.read_bytes() == raw
    assert target.stat().st_mode & 0o777 == 0o640
    changed = target.read_bytes()
    assert subprocess.run([str(binary), "apply", str(backup)]).returncode != 0
    assert backup.read_bytes() == raw and target.read_bytes() == changed
    subprocess.run([str(binary), "restore", str(backup)], check=True)
    assert target.read_bytes() == raw
    malformed = copy.deepcopy(original)
    del malformed["OS_ELIGIBILITY_DOMAIN_ARGON"]
    target.write_bytes(plistlib.dumps(malformed))
    before = target.read_bytes()
    assert subprocess.run([str(binary), "apply", str(root / "bad-backup.plist")]).returncode != 0
    assert target.read_bytes() == before and not (root / "bad-backup.plist").exists()
print("PASS: seven-domain edit, unrelated data, permissions, backup collision, restore and malformed input")
