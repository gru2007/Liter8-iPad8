#!/usr/bin/env python3
"""Lock the eligibility cache against writes and atomic replacement on the tested iPad.

apply: save original plist and flags, patch seven Marketplace answers, lock cache.
status: show flags and seven answers. unlock BACKUP: remove protection, keep answers.
restore BACKUP: restore protection flags and original plist. No device reboot.
While locked, other feature eligibility answers in this cache also cannot refresh.
"""
import argparse
import datetime
import hashlib
import pathlib
import plistlib
import shlex
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]
FILE = '/private/var/db/os_eligibility/eligibility.plist'
WRITER = '/var/tmp/liter8-marketplace-eligibility'
FREEZER = '/var/tmp/liter8-eligibility-persist'
DOMAINS = ('HYDROGEN','HELIUM','LITHIUM','CARBON','ARGON','POTASSIUM','SEARCH_MARKETPLACES')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=('apply','status','unlock','restore'))
    p.add_argument('backup', nargs='?')
    p.add_argument('--port', type=int, default=2222)
    a = p.parse_args()
    backup = a.backup or '/var/jb/var/backups/eligibility-lock-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    if not backup.startswith('/var/jb/var/backups/') or '..' in pathlib.PurePosixPath(backup).parts:
        p.error('Backup must be under /var/jb/var/backups without traversal')
    ssh = [str(ROOT/'tools/sshpass'),'-p','alpine','ssh','-o','StrictHostKeyChecking=no',
           '-o','UserKnownHostsFile=/dev/null','-o','LogLevel=ERROR','-o','ConnectTimeout=8',
           '-p',str(a.port),'root@localhost']
    def remote(command, data=None):
        r = subprocess.run(ssh+['export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin; '+command],input=data,capture_output=True,timeout=60)
        if r.returncode:
            raise RuntimeError(r.stderr.decode(errors='replace')+r.stdout.decode(errors='replace'))
        return r.stdout
    def upload(path, data):
        q=shlex.quote(path)
        remote(f'cat > {q}.new && chmod 755 {q}.new && mv {q}.new {q}',data)
    if a.action != 'status':
        subprocess.run(['sh','device/marketplacefix/build.sh'],cwd=ROOT,check=True)
        upload(WRITER,(ROOT/'device/marketplacefix/eligibility').read_bytes())
        upload(FREEZER,(ROOT/'device/marketplacefix/persist').read_bytes())
    print(remote(f'{WRITER} check').decode(),end='')
    active='/var/jb/var/backups/eligibility-lock.active'
    if a.action in ('unlock','restore') and not a.backup:
        backup=remote(f'cat {active}').decode().strip()
        if not backup.startswith('/var/jb/var/backups/eligibility-lock-') or '..' in pathlib.PurePosixPath(backup).parts:
            raise RuntimeError('Invalid active rollback path; supply an explicit backup path')
    qb=shlex.quote(backup)
    if a.action == 'apply':
        flags=remote(f'{FREEZER} status').decode()
        if 'file_locked=1' in flags or 'directory_locked=1' in flags:
            if 'file_locked=1' not in flags or 'directory_locked=1' not in flags:
                raise RuntimeError('Partially protected cache; unlock using the original backup first')
            current=plistlib.loads(remote(f'cat {FILE}'))
            if any((current.get('OS_ELIGIBILITY_DOMAIN_'+k,{}).get('os_eligibility_answer_t'),
                    current.get('OS_ELIGIBILITY_DOMAIN_'+k,{}).get('os_eligibility_answer_source_t')) != (4,2) for k in DOMAINS):
                raise RuntimeError('Cache is locked with unexpected answers; unlock before applying')
            print(flags,end='')
            print('Already protected; existing rollback state retained.')
            return

        before=remote(f'cat {FILE}')
        data=plistlib.loads(before)
        for suffix in DOMAINS:
            entry=data.get('OS_ELIGIBILITY_DOMAIN_'+suffix,{})
            if not all(k in entry for k in ('os_eligibility_answer_t','os_eligibility_answer_source_t')):
                raise RuntimeError('Missing domain: '+suffix)
        remote(f'mkdir -m 700 {qb}')
        print('Backup:',backup,flush=True)
        print(remote(f'{WRITER} apply {qb}/eligibility.plist').decode(),end='')
        print(remote(f'{FREEZER} lock {qb}/flags.plist').decode(),end='')
    elif a.action in ('unlock','restore'):
        remote(f'test -f {qb}/flags.plist && test -f {qb}/eligibility.plist')
        print(remote(f'{FREEZER} unlock {qb}/flags.plist').decode(),end='')
        if a.action == 'restore':
            print(remote(f'{WRITER} restore {qb}/eligibility.plist').decode(),end='')
    print(remote(f'{FREEZER} status').decode(),end='')
    raw=remote(f'cat {FILE}')
    data=plistlib.loads(raw)
    for suffix in DOMAINS:
        e=data.get('OS_ELIGIBILITY_DOMAIN_'+suffix,{})
        print(suffix,e.get('os_eligibility_answer_t'),e.get('os_eligibility_answer_source_t'))
        if a.action == 'apply' and (e.get('os_eligibility_answer_t'),e.get('os_eligibility_answer_source_t')) != (4,2):
            raise RuntimeError('Unexpected cached answer after locking')
    print('sha256:',hashlib.sha256(raw).hexdigest())
    if a.action == 'apply':
        remote(f'cat > {active}.new && chmod 600 {active}.new && mv {active}.new {active}', (backup+'\n').encode())
    elif a.action in ('unlock','restore'):
        remote(f'if test -f {active} && test "$(cat {active})" = {qb}; then rm {active}; fi')


if __name__ == '__main__':
    main()
