#!/usr/bin/python3
"""Preview by default. --apply resets only the two saved DJI Mic 2 control entries.

Requires Mac Bluetooth OFF and root. Backs up the entire source file before
changing it. Restarts coreaudiod; ongoing audio may pause briefly. Does not
change Bluetooth pairing records, PersistentPorts, firmware or other devices.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import time

BASE = Path(__file__).resolve().parents[2]
SOURCE = Path('/Library/Preferences/Audio/com.apple.audio.DeviceSettings.plist')



def run(args, **kw):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kw)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--device-address', required=True, help='Mic 2 Bluetooth address, e.g. AA:BB:CC:DD:EE:FF')
    args = parser.parse_args()
    import re
    address = args.device_address.upper().replace(':', '-')
    if not re.fullmatch(r'[0-9A-F]{2}(?:-[0-9A-F]{2}){5}', address):
        parser.error('Invalid Bluetooth address')
    KEYS = (address + ':input', address + ':output')
    if SOURCE.is_symlink():
        raise RuntimeError('Unexpected source symlink.')
    data = plistlib.loads(SOURCE.read_bytes())
    found = [key for key in KEYS if key in data]
    print('Saved Mic 2 control entries to reset:', ', '.join(found) or '(none)')
    print('Bluetooth pairing records and serial ports are preserved.')
    if not args.apply:
        print('PREVIEW: no changes made.')
        return
    if not found:
        print('No matching settings; nothing changed.')
        return
    if os.geteuid() != 0:
        raise RuntimeError('Run with sudo; administrator privileges required.')
    state = json.loads(run(['/usr/sbin/system_profiler', 'SPBluetoothDataType', '-json'],
                           timeout=30).stdout).get('SPBluetoothDataType', [])
    if not state or any(x.get('controller_properties', {}).get('controller_state')
                        != 'attrib_off' for x in state):
        raise RuntimeError('Mac Bluetooth must be OFF. No changes made.')
    pids = [int(x) for x in run(['/usr/bin/pgrep', '-x', 'coreaudiod']).stdout.split()]
    if len(pids) != 1:
        raise RuntimeError('Expected exactly one coreaudiod process.')
    pid = pids[0]
    if run(['/bin/ps', '-p', str(pid), '-o', 'comm=']).stdout.strip() != '/usr/sbin/coreaudiod':
        raise RuntimeError('Unexpected process identity.')
    os.umask(0o077)
    work = BASE / 'work/diagnostics'
    work.mkdir(mode=0o700, parents=True, exist_ok=True)
    backup = work / ('mic2-audio-controls-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    backup.mkdir(mode=0o700, parents=False, exist_ok=False)
    saved = backup / SOURCE.name
    suspended = False
    changed = False
    success = False
    status = {'result': 'preparing', 'backup': str(backup), 'removed_keys': found}
    try:
        os.kill(pid, signal.SIGSTOP)
        suspended = True
        for _ in range(20):
            if 'T' in run(['/bin/ps', '-p', str(pid), '-o', 'state=']).stdout:
                break
            time.sleep(0.05)
        else:
            raise RuntimeError('Could not suspend the settings writer.')
        # Read the authoritative baseline only after the writer is stopped.
        raw = SOURCE.read_bytes()
        data = plistlib.loads(raw)
        found = [key for key in KEYS if key in data]
        st = SOURCE.stat()
        shutil.copy2(SOURCE, saved)
        if hashlib.sha256(saved.read_bytes()).digest() != hashlib.sha256(raw).digest():
            raise RuntimeError('Backup verification failed.')
        status['backup_sha256'] = hashlib.sha256(raw).hexdigest()
        for key in found:
            changed = True
            run(['/usr/bin/defaults', 'delete', str(SOURCE.with_suffix('')), key], timeout=15)
        os.chown(SOURCE, st.st_uid, st.st_gid)
        os.chmod(SOURCE, st.st_mode & 0o777)
        expected = {k: v for k, v in data.items() if k not in KEYS}
        actual = plistlib.loads(SOURCE.read_bytes())
        if actual != expected:
            raise RuntimeError('Post-write verification failed; restoring backup.')
        status['result'] = 'saved-mic2-controls-reset-audio-restart-requested'
        success = True
    except BaseException:
        if changed:
            run(['/usr/bin/defaults', 'import', str(SOURCE.with_suffix('')), str(saved)], timeout=15)
            shutil.copy2(saved, SOURCE)
            os.chown(SOURCE, st.st_uid, st.st_gid)
            os.chmod(SOURCE, st.st_mode & 0o777)
            status['result'] = 'rolled-back-after-error'
        else:
            status['result'] = 'aborted-before-changes'
        raise
    finally:
        try:
            (backup / 'manifest.json').write_text(json.dumps(status, indent=2) + '\n')
        finally:
            if suspended:
                try:
                    os.kill(pid, signal.SIGKILL if success else signal.SIGCONT)
                except ProcessLookupError:
                    pass
    report = work / 'mic2-audio-reset-status.json'
    report.write_text(json.dumps(status, indent=2) + '\n')
    report.chmod(0o644)
    print('RESET COMPLETED: only Mic 2 saved audio controls were removed.')
    print('Backup:', backup)
    print('coreaudiod will restart automatically. Keep Bluetooth off until verification.')
    print('This is a diagnostic reset, not a confirmed fix.')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print('STOPPED:', exc, file=sys.stderr)
        sys.exit(1)
