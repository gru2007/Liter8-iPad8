#!/usr/bin/env python3
"""Prepare CocoaTop-TS for the current Liter8 kernel, retaining original inputs.

This removes task_for_pid-allow from the app and helper. It does not grant task
ports or fix kernel permissions; process inspection can remain incomplete.
"""
import argparse
import pathlib
import plistlib
import subprocess
import tempfile
import zipfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('input', type=pathlib.Path)
p.add_argument('output', type=pathlib.Path)
p.add_argument('--ldid', type=pathlib.Path, required=True)
a = p.parse_args()
if a.input.resolve() == a.output.resolve() or a.output.exists():
    p.error('output must be a new file distinct from the input')
ldid = str(a.ldid.resolve())
with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    with zipfile.ZipFile(a.input) as archive:
        for info in archive.infolist():
            target = (root / info.filename).resolve()
            if not target.is_relative_to(root):
                raise ValueError('archive member escapes extraction directory')
        archive.extractall(root)
    app = root / 'Payload/CocoaTop.app'
    for name in ('CocoaTop', 'CocoaTop-helper'):
        binary = app / name
        entitlements = plistlib.loads(subprocess.check_output([ldid, '-e', str(binary)]))
        if entitlements.pop('task_for_pid-allow', None) is None:
            raise ValueError(f'{name}: expected entitlement is absent; review input version')
        ent = root / (name + '.plist')
        ent.write_bytes(plistlib.dumps(entitlements))
        subprocess.run([ldid, '-S' + str(ent), '-Cadhoc', str(binary)], check=True)
        binary.chmod(0o755)
    with zipfile.ZipFile(a.output, 'w', zipfile.ZIP_DEFLATED) as archive:
        for item in (root / 'Payload').rglob('*'):
            if item.is_file():
                archive.write(item, item.relative_to(root))
print(a.output)
