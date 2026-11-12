#!/usr/bin/python3
"""Verified local Bluetooth reset. Preview by default; no firmware or SPP IO.

Apply requires root and --all-pairings. Device pairing credentials are removed
only through the helper's exact MobileBluetooth and BluetoothLE device selection.
BluetoothGlobal identity roots and all other Keychain services are preserved.
No backup is made: the operator has elected to discard local Bluetooth records.
"""
import argparse
import datetime
import errno
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import shutil
import signal
import stat
import subprocess
import sys
import time

BASE = Path(__file__).resolve().parents[2]
MAC = re.compile(r'^[0-9A-F]{2}(?:[:-][0-9A-F]{2}){5}$', re.I)
SYSTEM_PLISTS = (
    Path('/Library/Preferences/com.apple.bluetooth.plist'),
    Path('/Library/Bluetooth/Library/Preferences/com.apple.MobileBluetooth.devices.plist'),
)
DATABASES = tuple(Path('/Library/Bluetooth') / (name + suffix)
                  for name in ('com.apple.MobileBluetooth.ledevices.paired.db',
                               'com.apple.MobileBluetooth.ledevices.other.db')
                  for suffix in ('', '-wal', '-shm'))
AUDIO_CONTROLS = Path('/Library/Preferences/Audio/com.apple.audio.DeviceSettings.plist')


def run(argv, timeout=30, check=True):
    result = subprocess.run([str(x) for x in argv], capture_output=True, text=True,
                            timeout=timeout)
    if check and result.returncode:
        raise RuntimeError('Command failed (%d): %s\n%s' %
                           (result.returncode, argv[0], result.stderr.strip()[:1500]))
    return result


def normalize(value):
    if not isinstance(value, str) or not MAC.fullmatch(value):
        raise ValueError('Invalid Bluetooth device address')
    return value.upper().replace('-', ':')


def check_path(path, directory=False):
    """Reject symlinks, including parents; missing expected files are normal."""
    for parent in (path, *path.parents):
        if parent.is_symlink():
            raise RuntimeError('Refusing symlink: ' + str(parent))
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        return False
    if not (stat.S_ISDIR(mode) if directory else stat.S_ISREG(mode)):
        raise RuntimeError('Unexpected file type: ' + str(path))
    return True


def cache_paths(home, cache_dir, temp_dir):
    # Exact application directories only; never clear the containing user cache.
    return [cache_dir / name for name in
            ('com.apple.BluetoothSettings', 'com.apple.bluetoothuserd', 'com.apple.BluetoothUIServer')] + [
        temp_dir / 'com.apple.bluetoothuserd',
        home / 'Library/Caches/CloudKit/com.apple.bluetoothuserd',
        home / 'Library/Caches/com.apple.bluetoothuserd',
    ]


def clear_cache_contents(path):
    """Keep the OS-managed container, clearing only its contents.

    macOS marks some otherwise empty per-app temp roots sunlnk/rootless.
    Empty protected subdirectories are harmless; nonempty failures are not.
    """
    if not check_path(path, directory=True):
        return []
    retained_empty = []
    for child in list(path.iterdir()):
        mode = child.lstat().st_mode
        if stat.S_ISLNK(mode):
            child.unlink()  # Never follow a cache link outside this exact container.
        elif stat.S_ISDIR(mode):
            retained_empty.extend(clear_cache_contents(child))
            try:
                child.rmdir()
            except OSError as exc:
                if exc.errno in (errno.EPERM, errno.EACCES) and not any(child.iterdir()):
                    retained_empty.append(str(child))
                else:
                    raise
        elif stat.S_ISREG(mode):
            child.unlink()
        else:
            raise RuntimeError('Unexpected cache item type: ' + str(child))
    # A directory tree of protected empty containers is acceptable; no file data
    # may remain. Do not strip protection flags or change ownership to remove it.
    for child in path.rglob('*'):
        if child.is_symlink() or not child.is_dir():
            raise RuntimeError('Cache contents remain: ' + str(child))
    return retained_empty


def user_preferences(home):
    paths = [home / 'Library/Preferences' / name for name in
             ('com.apple.bluetooth.plist', 'com.apple.bluetoothuserd.plist')]
    byhost = home / 'Library/Preferences/ByHost'
    for pattern in ('com.apple.Bluetooth.*.plist', 'com.apple.bluetooth.*.plist',
                    'com.apple.bluetoothuserd.*.plist'):
        paths.extend(sorted(byhost.glob(pattern)))
    # Case-insensitive volumes may return two spellings of the same inode.
    seen, unique = set(), []
    for path in paths:
        key = (path.stat().st_dev, path.stat().st_ino) if path.exists() else str(path).lower()
        if key not in seen:
            seen.add(key)
            unique.append(path)
    return unique


def bluetooth_audio_keys(data, accounts):
    selected = {normalize(x).replace(':', '-') for x in accounts}
    return [key for key in data if isinstance(key, str)
            and re.fullmatch(r'[0-9A-Fa-f]{2}(?:-[0-9A-Fa-f]{2}){5}:(?:input|output)', key)
            and key.rsplit(':', 1)[0].upper() in selected]


def processes():
    rows = []
    for line in run(['/bin/ps', '-axo', 'pid=,uid=,comm='], timeout=2).stdout.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3:
            rows.append((int(parts[0]), int(parts[1]), parts[2]))
    return rows


def still_same(row):
    return row in processes()


def stop_writer(row):
    if not still_same(row):
        raise RuntimeError('Writer changed before pause')
    os.kill(row[0], signal.SIGSTOP)
    for _ in range(30):
        state = run(['/bin/ps', '-p', row[0], '-o', 'state='], timeout=2, check=False).stdout
        if 'T' in state:
            return
        time.sleep(0.05)
    raise RuntimeError('Could not confirm writer pause')


def release_writers(rows, changed):
    errors = []
    for row in reversed(rows):
        try:
            if still_same(row):
                os.kill(row[0], signal.SIGKILL if changed else signal.SIGCONT)
        except ProcessLookupError:
            pass
        except Exception as exc:
            errors.append('%s: %s' % (row[0], exc))
            # A termination failure must not leave a suspended daemon behind.
            try:
                if still_same(row):
                    os.kill(row[0], signal.SIGCONT)
            except ProcessLookupError:
                pass
            except Exception as fallback:
                errors.append('%s resume: %s' % (row[0], fallback))
    return errors


def boot_id():
    return run(['/usr/sbin/sysctl', '-n', 'kern.boottime']).stdout.strip()


class Reset:
    def __init__(self, uid, helper):
        self.uid = uid
        self.home = Path(pwd.getpwuid(uid).pw_dir).resolve()
        self.helper = helper.resolve()
        if not check_path(self.helper):
            raise RuntimeError('Build BluetoothResetHelper first')
        folders = []
        for selector in ('DARWIN_USER_CACHE_DIR', 'DARWIN_USER_TEMP_DIR'):
            value = self.as_user(['/usr/bin/getconf', selector]).stdout.strip()
            if not value or not Path(value).is_absolute() or not Path(value).is_dir():
                raise RuntimeError('No valid per-user cache/temp directory from getconf')
            folders.append(Path(value).resolve())
        self.cache_dir, self.temp_dir = folders
        self.user_plists = user_preferences(self.home)
        self.caches = cache_paths(self.home, self.cache_dir, self.temp_dir)
        self.report = {'schema_version': 1, 'result': 'preflight', 'boot_before': boot_id(),
                       'started': datetime.datetime.now().astimezone().isoformat(),
                       'removed_files': [], 'removed_cache_directories': [], 'unpair_requests': [],
                       'audio_keys_removed': [], 'verification': {}, 'no_backup_requested': True}
        self.journal = None

    def as_user(self, argv, **kw):
        if os.geteuid() == self.uid:
            return run(argv, **kw)
        return run(['/bin/launchctl', 'asuser', self.uid, '/usr/bin/sudo', '-n', '-u',
                    '#' + str(self.uid), *argv], **kw)

    def native(self, *argv, system=False):
        result = (run if system else self.as_user)([self.helper, *argv], timeout=25, check=False)
        try:
            value = json.loads(result.stdout)
        except ValueError:
            raise RuntimeError('Native helper returned no valid result: ' + result.stderr[:500])
        if result.returncode or not value.get('ok'):
            raise RuntimeError('Native operation failed: ' + json.dumps(value, ensure_ascii=False))
        return value

    def preflight(self):
        for path in (*SYSTEM_PLISTS, *DATABASES, *self.user_plists, AUDIO_CONTROLS):
            check_path(path)
        for path in self.caches:
            check_path(path, directory=True)
        if any(Path(row[2]).name in ('RXlessDemo', 'mic2-receive-probe', 'mic2-channel-observer',
                                    'mic2-audio-route-guard', 'PacketLogger') for row in processes()):
            raise RuntimeError('Quit the Demo and Bluetooth experiment tools first')
        return {'system_plists': [str(p) for p in SYSTEM_PLISTS],
                'database_files': [str(p) for p in DATABASES],
                'user_plists': [str(p) for p in self.user_plists],
                'cache_directories': [str(p) for p in self.caches],
                'keychain_scope': 'System.keychain / genp / MobileBluetooth MAC + BluetoothLE/BluetoothLESync Public MAC Random MAC only',
                'audio_scope': 'input/output controls matching original paired device accounts',
                'preserved': ['BluetoothGlobal identity roots', 'other Keychain services',
                              'Wi-Fi', 'native Bluetooth services', 'firmware']}

    def save(self):
        if self.journal:
            tmp = self.journal.with_suffix('.tmp')
            tmp.write_text(json.dumps(self.report, indent=2, ensure_ascii=False) + '\n')
            tmp.chmod(0o600)
            os.chown(tmp, self.uid, pwd.getpwuid(self.uid).pw_gid)
            os.replace(tmp, self.journal)

    def read_preference(self, path):
        if not check_path(path):
            return {}
        data = plistlib.loads(path.read_bytes())
        if not isinstance(data, dict):
            raise RuntimeError('Preference domain is not a dictionary: ' + str(path))
        return data

    def delete_preference(self, path, user=False):
        if self.read_preference(path):
            action = self.as_user if user else run
            result = action(['/usr/bin/defaults', 'delete', path.with_suffix('')],
                            timeout=15, check=False)
            # Only the exact missing-domain diagnostic is benign, and only if
            # the subsequent on-disk check confirms no values remain.
            missing = "Domain '%s' not found." % path.with_suffix('')
            lines = [line.strip() for line in result.stderr.splitlines() if line.strip()]
            benign = lines in ([missing, 'Defaults have not been changed.'],
                               ['Error: ' + missing, 'Defaults have not been changed.'])
            if result.returncode and not benign:
                raise RuntimeError('Preference deletion failed: %s: %s' %
                                   (path, result.stderr.strip()[:1000]))
            if self.read_preference(path):
                raise RuntimeError('Preference domain still contains values: ' + str(path))
        if check_path(path):
            self.report.setdefault('empty_preference_files', []).append(str(path))
        else:
            self.report['removed_files'].append(str(path))
        self.save()

    def attempt_cleanup(self, label, action):
        try:
            action()
        except InterruptedError:
            raise  # Terminal close/Ctrl-C must immediately release writers.
        except Exception as exc:
            self.report.setdefault('cleanup_errors', []).append({'item': label, 'error': str(exc)})
        self.save()

    def delete_database(self, path):
        if check_path(path):
            path.unlink()
            self.report['removed_files'].append(str(path))

    def clear_cache(self, path):
        if check_path(path, directory=True):
            retained = clear_cache_contents(path)
            self.report.setdefault('cleared_cache_containers', []).append(str(path))
            self.report.setdefault('retained_empty_cache_directories', []).extend(retained)

    def clear_audio_controls(self, accounts):
        original = self.read_preference(AUDIO_CONTROLS)
        selected = bluetooth_audio_keys(original, accounts)

        def delete_key(key):
            run(['/usr/bin/defaults', 'delete', AUDIO_CONTROLS.with_suffix(''), key], timeout=15)
            if key in self.read_preference(AUDIO_CONTROLS):
                raise RuntimeError('Audio control remains: ' + key)
            self.report['audio_keys_removed'].append(key)

        for key in selected:
            self.attempt_cleanup('audio control ' + key, lambda key=key: delete_key(key))
        actual = self.read_preference(AUDIO_CONTROLS)
        if ({k: v for k, v in original.items() if k not in selected} !=
                {k: v for k, v in actual.items() if k not in selected}):
            raise RuntimeError('Unrelated audio controls changed unexpectedly')
        if any(key in actual for key in selected):
            raise RuntimeError('Selected Bluetooth audio controls remain')

    def clear_local_stores(self, accounts):
        for path in SYSTEM_PLISTS:
            self.attempt_cleanup(str(path), lambda path=path: self.delete_preference(path))
        for path in self.user_plists:
            self.attempt_cleanup(str(path), lambda path=path: self.delete_preference(path, user=True))
        for path in DATABASES:
            self.attempt_cleanup(str(path), lambda path=path: self.delete_database(path))
        for path in self.caches:
            self.attempt_cleanup(str(path), lambda path=path: self.clear_cache(path))
        self.attempt_cleanup(str(AUDIO_CONTROLS), lambda: self.clear_audio_controls(accounts))
        self.report['local_stores_processed'] = not self.report.get('cleanup_errors')

    def apply(self):
        self.preflight()
        destination = BASE / 'work/diagnostics' / ('bluetooth-full-reset-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
        destination.mkdir(parents=True, mode=0o700, exist_ok=False)
        os.chown(destination, self.uid, pwd.getpwuid(self.uid).pw_gid)
        self.journal = destination / 'result.json'
        before = self.native('--snapshot')
        keys_before = self.native('--keychain-summary', system=True)
        if keys_before.get('skipped_count') != 0:
            raise RuntimeError('Unexpected Bluetooth credential items; refusing before any reset action')
        accounts = {normalize(d['address']) for d in before['devices'] if d['paired']}
        accounts.update(normalize(a) for a in keys_before['accounts'])
        # A partial attempt may already have removed a device's pairing identity.
        # Carry its audited account scope forward so its saved audio controls are
        # still cleared on a rerun instead of silently losing the target.
        prior = sorted((BASE / 'work/diagnostics').glob('bluetooth-full-reset-*/result.json'))
        for previous_path in prior:
            if previous_path == self.journal:
                continue
            previous = json.loads(previous_path.read_text())
            if previous.get('result') == 'failed_or_partial' and previous.get('boot_before') == self.report['boot_before']:
                accounts.update(normalize(a) for a in previous.get('original_accounts', []))
                self.report.setdefault('resuming_reports', []).append(str(previous_path))
        self.report.update(before_snapshot=before, before_keychain=keys_before,
                           original_accounts=sorted(accounts), scope=self.preflight())
        self.save()
        print('1/5 Turning Bluetooth off and requesting device unpair...', flush=True)
        self.native('--power-off')
        if self.native('--snapshot')['power'] != 0:
            raise RuntimeError('Bluetooth did not stay OFF')
        for address in sorted(accounts):
            try:
                result = self.native('--unpair', address)
            except Exception as exc:
                result = {'address': address, 'requested': False, 'error': str(exc)}
            self.report['unpair_requests'].append(result)
            self.save()
        self.report['after_unpair_snapshot'] = self.native('--snapshot')
        self.save()
        print('2/5 Pausing Bluetooth writers; removing exact device pairing keys...', flush=True)
        writers = [row for row in processes() if
                   (row[2] == '/usr/sbin/bluetoothd' and row[1] == 0)
                   or (row[2] == '/usr/libexec/bluetoothuserd' and row[1] == self.uid)
                   or row[2] == '/usr/sbin/coreaudiod']
        if len([r for r in writers if r[2] == '/usr/sbin/bluetoothd']) != 1:
            raise RuntimeError('Expected one Bluetooth system daemon')
        paused, changed = [], False
        try:
            for row in writers:
                # Track before pause so a failed confirmation still releases it.
                paused.append(row)
                stop_writer(row)
            changed = True  # The helper may partially delete before reporting an error.
            deleted = self.native('--delete-device-pairing-keys', '--apply', system=True)
            self.report['keychain_deletion'] = deleted
            if not deleted.get('verified') or deleted.get('remaining_count') != 0:
                raise RuntimeError('Pairing-key deletion could not be verified')
            self.save()
            print('3/5 Removing local Bluetooth stores and matched caches...', flush=True)
            self.clear_local_stores(accounts)
            # Replace preference clients even on partial cleanup, before the
            # paused Bluetooth/audio writers are released in finally.
            def restart_preference_clients():
                for row in processes():
                    if row[2] == '/usr/sbin/cfprefsd' and row[1] in (0, self.uid):
                        def terminate(row=row):
                            try:
                                os.kill(row[0], signal.SIGTERM)
                            except ProcessLookupError:
                                pass
                        self.attempt_cleanup('cfprefsd ' + str(row[0]), terminate)
            self.attempt_cleanup('preference client restart', restart_preference_clients)
            self.report['local_stores_processed'] = not self.report.get('cleanup_errors')
            self.report['result'] = 'removed_pending_service_restart'
            self.save()
        finally:
            failures = release_writers(paused, changed)
            if failures:
                self.report['writer_release_errors'] = failures
                self.save()
                raise RuntimeError('Could not release all stopped writers: ' + '; '.join(failures))
        if self.report.get('cleanup_errors'):
            raise RuntimeError('Local cleanup incomplete: ' + '; '.join(
                item['item'] + ': ' + item['error'] for item in self.report['cleanup_errors']))
        print('4/5 Verifying fresh system state...', flush=True)
        time.sleep(2)
        self.native('--power-off')
        result = self.verify(require_new_boot=False, original_accounts=accounts)
        self.report['verification'] = result
        self.report['result'] = 'local_reset_verified_reboot_required' if result['ok'] else 'partial_or_records_returned'
        self.save()
        print('5/5 Result: ' + self.report['result'], flush=True)
        print('Report: ' + str(self.journal), flush=True)
        if not result['ok']:
            raise RuntimeError('Verification found remaining or restored records; not reporting reset success')
        print('LOCAL RESET VERIFIED. Keep Mic 2 OFF. Restart the Mac, then run --verify before pairing.')
        print('This verifies local cleanup, not microphone audio recovery or removal of cloud records.')

    def verify(self, require_new_boot=False, original_accounts=()):
        previous = None
        if require_new_boot:
            histories = sorted((BASE / 'work/diagnostics').glob('bluetooth-full-reset-*/result.json'))
            if not histories:
                raise RuntimeError('No previous reset result to verify')
            previous = json.loads(histories[-1].read_text())
            if not previous.get('local_stores_processed') or not previous.get('keychain_deletion', {}).get('verified'):
                raise RuntimeError('Previous reset did not finish local store/key removal; inspect its report first')
            original_accounts = previous.get('original_accounts', [])
        snapshot = self.native('--snapshot')
        keys = self.native('--keychain-summary', system=True)
        persistent = {}
        if SYSTEM_PLISTS[0].exists():
            persistent = plistlib.loads(SYSTEM_PLISTS[0].read_bytes()).get('PersistentPorts', {})
        audio_remaining = []
        if AUDIO_CONTROLS.exists():
            audio_remaining = bluetooth_audio_keys(plistlib.loads(AUDIO_CONTROLS.read_bytes()), original_accounts)
        result = {'snapshot': snapshot, 'keychain_device_count': keys['count'],
                  'keychain_unexpected_count': keys.get('skipped_count'),
                  'matching_audio_controls_remaining': audio_remaining,
                  'persistent_port_count': len(persistent), 'boot_now': boot_id(),
                  'power_off': snapshot['power'] == 0,
                  'paired_count': snapshot['paired_count'], 'firmware_touched': False}
        result['ok'] = (result['power_off'] and snapshot['paired_count'] == 0 and keys['count'] == 0
                        and keys.get('skipped_count') == 0 and not persistent and not audio_remaining)
        if require_new_boot:
            result['new_boot'] = previous.get('boot_before') != result['boot_now']
            result['ok'] = result['ok'] and result['new_boot']
            result['reset_report'] = str(histories[-1])
        return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--apply', action='store_true')
    mode.add_argument('--verify', action='store_true')
    parser.add_argument('--all-pairings', action='store_true')
    parser.add_argument('--helper', type=Path, default=BASE / 'work/diagnostics/BluetoothResetHelper')
    args = parser.parse_args(argv)
    uid = int(os.environ.get('SUDO_UID', os.getuid()))
    if uid == 0:
        raise RuntimeError('Run from the signed-in user through sudo, not a root login')
    if args.apply and not args.all_pairings:
        raise RuntimeError('--apply requires --all-pairings')
    if (args.apply or args.verify) and os.geteuid() != 0:
        raise RuntimeError('Administrator privileges required; run with sudo')
    reset = Reset(uid, args.helper)
    try:
        if args.apply:
            reset.apply()
        elif args.verify:
            result = reset.verify(require_new_boot=True)
            print(json.dumps(result, indent=2, ensure_ascii=False))
            if not result['ok']:
                raise RuntimeError('Post-reboot verification failed; do not pair yet')
            print('POST-REBOOT LOCAL STATE VERIFIED. Ordinary audio still requires a fresh pairing and recording test.')
        else:
            print(json.dumps({'preview_only': True, 'scope': reset.preflight()}, indent=2, ensure_ascii=False))
    except BaseException as exc:
        reset.report['result'] = 'failed_or_partial'
        reset.report['error'] = str(exc)
        reset.save()
        raise


if __name__ == '__main__':
    def interrupted(number, _frame):
        # A normal Terminal close or Ctrl-C still runs the writer-release finally.
        raise InterruptedError('Interrupted by signal %d' % number)
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, interrupted)
    try:
        main()
    except Exception as exc:
        print('STOPPED: ' + str(exc), file=sys.stderr)
        print('No successful reset is claimed. Keep Mic 2 off and inspect the result report.', file=sys.stderr)
        sys.exit(1)
