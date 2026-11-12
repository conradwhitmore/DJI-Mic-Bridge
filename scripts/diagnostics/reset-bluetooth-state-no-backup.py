#!/usr/bin/python3
"""Reset local Bluetooth cache files and serial registrations, not all pairings.

No backup, as explicitly requested by the user. Preview unless --apply is given.
Pairing credentials can survive in Keychain or return through account sync.
This is NOT a full unpair operation; use system Forget Device for that.
Does not erase Wi-Fi, Keychain/iCloud, CoreAudio or unrelated application data.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import time

PLISTS = (
    Path('/Library/Preferences/com.apple.bluetooth.plist'),
    Path('/Library/Bluetooth/Library/Preferences/com.apple.MobileBluetooth.devices.plist'),
)
DATABASES = tuple(Path('/Library/Bluetooth') / (name + suffix)
                  for name in ('com.apple.MobileBluetooth.ledevices.paired.db',
                               'com.apple.MobileBluetooth.ledevices.other.db')
                  for suffix in ('', '-wal', '-shm'))
TARGETS = PLISTS + DATABASES


def run(command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, text=True,
                          timeout=kwargs.pop('timeout', 15), **kwargs).stdout


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args(argv)
    if not args.apply:
        print('PREVIEW ONLY. No backup will be created with --apply.')
        for path in TARGETS:
            print(path)
        return
    if os.geteuid() != 0:
        raise RuntimeError('Run with sudo.')
    state = json.loads(run(['/usr/sbin/system_profiler', 'SPBluetoothDataType', '-json'],
                           timeout=30)).get('SPBluetoothDataType', [])
    if not state or any(s.get('controller_properties', {}).get('controller_state')
                        != 'attrib_off' for s in state):
        raise RuntimeError('Turn Mac Bluetooth OFF in Control Center first. Nothing changed.')
    if not PLISTS[1].is_file():
        raise RuntimeError('Expected local pairing store is missing; refusing to guess.')
    pids = run(['/usr/bin/pgrep', '-x', 'bluetoothd']).split()
    if len(pids) != 1:
        raise RuntimeError('Expected exactly one bluetoothd process. Nothing changed.')
    pid = int(pids[0])
    if run(['/bin/ps', '-p', str(pid), '-o', 'comm=']).strip() != '/usr/sbin/bluetoothd':
        raise RuntimeError('Unexpected process identity. Nothing changed.')

    suspended = False
    changed = False
    removed = []
    try:
        os.kill(pid, signal.SIGSTOP)
        suspended = True
        for _ in range(20):
            if 'T' in run(['/bin/ps', '-p', str(pid), '-o', 'state=']):
                break
            time.sleep(0.05)
        else:
            raise RuntimeError('Unable to pause Bluetooth database writer. Nothing changed.')
        # Enumerate after pausing the writer, including SQLite WAL/SHM companions.
        existing = []
        for path in TARGETS:
            try:
                mode = path.lstat().st_mode
            except FileNotFoundError:
                continue
            if not stat.S_ISREG(mode):
                raise RuntimeError('Refusing unexpected file type: ' + str(path))
            existing.append(path)
        for path in existing:
            changed = True  # A failing defaults operation may still have mutated its domain.
            if path in PLISTS:
                run(['/usr/bin/defaults', 'delete', str(path.with_suffix(''))])
            else:
                path.unlink()
            removed.append(str(path))
    finally:
        if suspended:
            try:
                # Prevent the old daemon from restoring its previous in-memory stores.
                os.kill(pid, signal.SIGKILL if changed else signal.SIGCONT)
            except ProcessLookupError:
                pass
        if changed:
            print('Processed local stores:')
            for path in removed:
                print('  ' + path)
    print('LOCAL CACHE RESET COMPLETED. No backup was created.')
    print('Save your work and restart the Mac. Keep Mic 2 OFF until after restart.')
    print('Pairing credentials may remain in Keychain or sync back. This did NOT fully unpair devices.')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print('STOPPED: ' + str(exc), file=sys.stderr)
        print('If any stores were already processed, the reset is partial; do not assume success.',
              file=sys.stderr)
        sys.exit(1)
