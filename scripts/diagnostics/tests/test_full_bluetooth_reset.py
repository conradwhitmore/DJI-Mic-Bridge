"""Offline-only tests. Native commands, signals and system mutations are mocked."""
import contextlib
import errno
import importlib.util
import io
import json
import plistlib
from pathlib import Path
import signal
import stat
import types
import unittest
from unittest.mock import Mock, call, patch


SOURCE = Path(__file__).resolve().parents[1] / 'reset-bluetooth-all.py'
SPEC = importlib.util.spec_from_file_location('full_bluetooth_reset_under_test', SOURCE)
reset = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reset)


class FullBluetoothResetTests(unittest.TestCase):
    def setUp(self):
        # Fail closed if a test accidentally reaches an unmocked external action.
        for owner, name in ((reset.subprocess, 'run'), (reset.subprocess, 'Popen'),
                            (reset.os, 'kill'), (reset.os, 'chown'),
                            (reset.shutil, 'rmtree'), (reset.Reset, 'native'),
                            (Path, 'read_text'), (Path, 'unlink'), (Path, 'rmdir'),
                            (Path, 'iterdir'), (Path, 'rglob')):
            blocker = patch.object(owner, name, side_effect=AssertionError('Unexpected external action: ' + name))
            blocker.start()
            self.addCleanup(blocker.stop)

    def test_mac_normalization_accepts_only_complete_mac_accounts(self):
        self.assertEqual(reset.normalize('aa:bb:cc:dd:ee:ff'), 'AA:BB:CC:DD:EE:FF')
        self.assertEqual(reset.normalize('aa-bb-cc-dd-ee-ff'), 'AA:BB:CC:DD:EE:FF')
        for invalid in ('BluetoothGlobal', 'host-AA:BB:CC:DD:EE:FF',
                        'AA:BB:CC:DD:EE:FF:input', 'AA:BB:CC:DD:EE:FF\n',
                        ' AA:BB:CC:DD:EE:FF', 'AA:BB:CC:DD:EE',
                        'AA:BB:CC:DD:EE:GG', 'AABBCCDDEEFF', '', None, 123):
            with self.subTest(value=invalid), self.assertRaises(ValueError):
                reset.normalize(invalid)

    def test_user_preferences_deduplicate_case_variants_of_same_inode(self):
        home = Path('/fixture/user')
        upper = home / 'Library/Preferences/ByHost/com.apple.Bluetooth.HOST.plist'
        lower = home / 'Library/Preferences/ByHost/com.apple.bluetooth.HOST.plist'
        userd = home / 'Library/Preferences/ByHost/com.apple.bluetoothuserd.HOST.plist'
        found = {
            'com.apple.Bluetooth.*.plist': [upper],
            'com.apple.bluetooth.*.plist': [lower],
            'com.apple.bluetoothuserd.*.plist': [userd],
        }
        inode = {upper: 10, lower: 10, userd: 11}
        with patch.object(Path, 'glob', lambda _, pattern: iter(found[pattern])), \
                patch.object(Path, 'exists', lambda path: path in inode), \
                patch.object(Path, 'stat', lambda path: types.SimpleNamespace(st_dev=1, st_ino=inode[path])):
            paths = reset.user_preferences(home)
        self.assertEqual(paths, [home / 'Library/Preferences/com.apple.bluetooth.plist',
                                 home / 'Library/Preferences/com.apple.bluetoothuserd.plist',
                                 upper, userd])

    def test_missing_case_variants_are_deduplicated_by_normalized_path(self):
        home = Path('/fixture/user')
        upper = home / 'Library/Preferences/ByHost/com.apple.Bluetooth.HOST.plist'
        lower = home / 'Library/Preferences/ByHost/com.apple.bluetooth.HOST.plist'
        with patch.object(Path, 'glob', lambda _, pattern: iter(
                [upper] if pattern == 'com.apple.Bluetooth.*.plist' else
                [lower] if pattern == 'com.apple.bluetooth.*.plist' else [])), \
                patch.object(Path, 'exists', return_value=False):
            paths = reset.user_preferences(home)
        self.assertEqual(paths.count(upper), 1)
        self.assertNotIn(lower, paths)

    def test_cache_scope_contains_only_six_exact_application_directories(self):
        home, cache, temporary = map(Path, ('/fixture/user', '/fixture/cache', '/fixture/temp'))
        paths = reset.cache_paths(home, cache, temporary)
        self.assertEqual(paths, [
            cache / 'com.apple.BluetoothSettings',
            cache / 'com.apple.bluetoothuserd',
            cache / 'com.apple.BluetoothUIServer',
            temporary / 'com.apple.bluetoothuserd',
            home / 'Library/Caches/CloudKit/com.apple.bluetoothuserd',
            home / 'Library/Caches/com.apple.bluetoothuserd',
        ])
        self.assertNotIn(cache, paths)
        self.assertNotIn(temporary, paths)
        self.assertNotIn(home / 'Library/Caches', paths)
        self.assertNotIn(home / 'Library/Caches/CloudKit', paths)
        self.assertTrue(all('*' not in str(path) for path in paths))

    @contextlib.contextmanager
    def cache_tree(self, entries, unlink_errors=None, rmdir_errors=None):
        """In-memory directory tree; no real cache or filesystem mutation occurs."""
        root = Path('/fixture/cache/com.apple.bluetoothuserd')
        nodes = {root: stat.S_IFDIR}
        nodes.update({root / name if name else root: mode for name, mode in entries.items()})
        unlink_errors, rmdir_errors = unlink_errors or {}, rmdir_errors or {}
        operations = []

        def children(path):
            if not stat.S_ISDIR(nodes.get(path, 0)):
                raise AssertionError('Attempted traversal outside virtual cache directory: ' + str(path))
            operations.append(('iterdir', path))
            return iter([candidate for candidate in nodes if candidate.parent == path])

        def lstat(path):
            operations.append(('lstat', path))
            if path not in nodes:
                raise FileNotFoundError(str(path))
            return types.SimpleNamespace(st_mode=nodes[path])

        def unlink(path):
            operations.append(('unlink', path))
            error = unlink_errors.get(str(path.relative_to(root)))
            if error:
                raise OSError(error, 'mocked unlink failure')
            if stat.S_ISDIR(nodes[path]):
                raise AssertionError('unlink must not be used on a directory')
            del nodes[path]

        def rmdir(path):
            operations.append(('rmdir', path))
            error = rmdir_errors.get(str(path.relative_to(root)))
            if error:
                raise OSError(error, 'mocked rmdir failure')
            if any(candidate.parent == path for candidate in nodes):
                raise OSError(errno.ENOTEMPTY, 'virtual directory is not empty')
            del nodes[path]

        def rglob(path, pattern):
            self.assertEqual(pattern, '*')
            operations.append(('rglob', path))
            return iter([candidate for candidate in nodes if path in candidate.parents])

        with patch.object(Path, 'lstat', lstat), \
                patch.object(Path, 'is_symlink', lambda path: stat.S_ISLNK(nodes.get(path, 0))), \
                patch.object(Path, 'is_dir', lambda path: stat.S_ISDIR(nodes.get(path, 0))), \
                patch.object(Path, 'iterdir', children), \
                patch.object(Path, 'rglob', rglob), \
                patch.object(Path, 'unlink', unlink), \
                patch.object(Path, 'rmdir', rmdir):
            yield root, nodes, operations

    def test_cache_clearing_preserves_managed_root_and_removes_only_contents(self):
        entries = {'state.bin': stat.S_IFREG, 'nested': stat.S_IFDIR,
                   'nested/state.bin': stat.S_IFREG}
        with self.cache_tree(entries) as (root, nodes, operations):
            self.assertEqual(reset.clear_cache_contents(root), [])
            self.assertEqual(nodes, {root: stat.S_IFDIR})
            self.assertNotIn(('rmdir', root), operations)
            self.assertNotIn(('unlink', root), operations)
            self.assertIn(('unlink', root / 'nested/state.bin'), operations)

    def test_protected_empty_cache_child_can_remain_without_removing_root(self):
        for error in (errno.EPERM, errno.EACCES):
            with self.subTest(errno=error), self.cache_tree(
                    {'protected': stat.S_IFDIR, 'state.bin': stat.S_IFREG},
                    rmdir_errors={'protected': error}) as (root, nodes, operations):
                self.assertEqual(reset.clear_cache_contents(root), [str(root / 'protected')])
                self.assertEqual(nodes, {root: stat.S_IFDIR, root / 'protected': stat.S_IFDIR})
                self.assertNotIn(('rmdir', root), operations)

    def test_nonempty_cache_with_unlink_failure_is_rejected_not_retained_as_empty(self):
        with self.cache_tree({'protected': stat.S_IFDIR, 'protected/state.bin': stat.S_IFREG},
                             unlink_errors={'protected/state.bin': errno.EPERM},
                             rmdir_errors={'protected': errno.EPERM}) as (root, nodes, operations):
            with self.assertRaises(OSError) as raised:
                reset.clear_cache_contents(root)
            self.assertEqual(raised.exception.errno, errno.EPERM)
            self.assertIn(root / 'protected/state.bin', nodes)
            self.assertNotIn(('rmdir', root / 'protected'), operations)
            self.assertNotIn(('rmdir', root), operations)

    def test_other_rmdir_errors_on_empty_cache_child_are_not_ignored(self):
        with self.cache_tree({'empty': stat.S_IFDIR},
                             rmdir_errors={'empty': errno.EIO}) as (root, nodes, operations):
            with self.assertRaises(OSError) as raised:
                reset.clear_cache_contents(root)
            self.assertEqual(raised.exception.errno, errno.EIO)
            self.assertIn(root / 'empty', nodes)

    def test_cache_symlink_is_unlinked_without_traversing_its_target(self):
        with self.cache_tree({'outside-link': stat.S_IFLNK}) as (root, nodes, operations):
            self.assertEqual(reset.clear_cache_contents(root), [])
            self.assertEqual(nodes, {root: stat.S_IFDIR})
            self.assertIn(('unlink', root / 'outside-link'), operations)
            self.assertNotIn(('iterdir', root / 'outside-link'), operations)
            self.assertNotIn(('rglob', root / 'outside-link'), operations)

    def test_cache_root_symlink_is_rejected_before_traversal_or_deletion(self):
        with self.cache_tree({'': stat.S_IFLNK}) as (root, nodes, operations):
            with self.assertRaisesRegex(RuntimeError, 'Refusing symlink'):
                reset.clear_cache_contents(root)
            self.assertEqual(nodes, {root: stat.S_IFLNK})
            self.assertEqual(operations, [])

    def test_check_path_rejects_leaf_and_parent_symlinks_before_stat(self):
        path = Path('/fixture/preferences/item.plist')
        for symlink in (path, path.parent, path.parent.parent):
            with self.subTest(symlink=str(symlink)), \
                    patch.object(Path, 'is_symlink', lambda item: item == symlink), \
                    patch.object(Path, 'lstat', side_effect=AssertionError('Must reject before stat')):
                with self.assertRaisesRegex(RuntimeError, 'Refusing symlink'):
                    reset.check_path(path)

    def test_check_path_accepts_only_expected_file_type_and_missing_paths(self):
        path = Path('/fixture/item')
        with patch.object(Path, 'is_symlink', return_value=False):
            with patch.object(Path, 'lstat', return_value=types.SimpleNamespace(st_mode=stat.S_IFREG | 0o600)):
                self.assertTrue(reset.check_path(path))
                with self.assertRaisesRegex(RuntimeError, 'Unexpected file type'):
                    reset.check_path(path, directory=True)
            with patch.object(Path, 'lstat', return_value=types.SimpleNamespace(st_mode=stat.S_IFDIR | 0o700)):
                self.assertTrue(reset.check_path(path, directory=True))
                with self.assertRaisesRegex(RuntimeError, 'Unexpected file type'):
                    reset.check_path(path)
            with patch.object(Path, 'lstat', side_effect=FileNotFoundError):
                self.assertFalse(reset.check_path(path))

    def test_audio_keys_select_only_original_accounts_and_exact_input_output_keys(self):
        original = {
            'aa-bb-cc-dd-ee-ff:input': {'volume': 1},
            'AA-BB-CC-DD-EE-FF:output': {'volume': 2},
            '11-22-33-44-55-66:input': {'volume': 3},
            '77-88-99-AA-BB-CC:input': {'preserve': True},
            'AA-BB-CC-DD-EE-FF:other': {'preserve': True},
            'AA-BB-CC-DD-EE-FF:input:extra': {'preserve': True},
            'AA:BB:CC:DD:EE:FF:input': {'preserve': True},
            'prefix-AA-BB-CC-DD-EE-FF:input': {'preserve': True},
            'BuiltInSpeaker:output': {'preserve': True},
            12: {'preserve': True},
        }
        before = dict(original)
        self.assertEqual(reset.bluetooth_audio_keys(original, ['aa:bb:cc:dd:ee:ff', '11-22-33-44-55-66']),
                         ['aa-bb-cc-dd-ee-ff:input', 'AA-BB-CC-DD-EE-FF:output', '11-22-33-44-55-66:input'])
        self.assertEqual(reset.bluetooth_audio_keys(original, []), [])
        self.assertEqual(original, before, 'Selection must not mutate input controls')

    def test_preview_uses_no_native_operation(self):
        result = types.SimpleNamespace(stdout='/fixture/cache\n', stderr='', returncode=0)
        with patch.dict(reset.os.environ, {'SUDO_UID': '501'}, clear=True), \
                patch.object(reset.os, 'getuid', return_value=501), \
                patch.object(reset.os, 'geteuid', return_value=501), \
                patch.object(reset.pwd, 'getpwuid', return_value=types.SimpleNamespace(pw_dir='/fixture/user', pw_gid=20)), \
                patch.object(Path, 'resolve', lambda path: path), \
                patch.object(Path, 'is_dir', return_value=True), \
                patch.object(reset, 'check_path', return_value=True), \
                patch.object(reset, 'user_preferences', return_value=[]), \
                patch.object(reset, 'processes', return_value=[]), \
                patch.object(reset, 'run', return_value=result) as commands, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            reset.main([])
        reset.Reset.native.assert_not_called()
        self.assertIn('"preview_only": true', output.getvalue())
        self.assertEqual([entry.args[0][0] for entry in commands.call_args_list],
                         ['/usr/bin/getconf', '/usr/bin/getconf', '/usr/sbin/sysctl'])

    def test_invalid_getconf_directory_is_rejected_before_native_or_store_reads(self):
        for failing_selector in ('DARWIN_USER_CACHE_DIR', 'DARWIN_USER_TEMP_DIR'):
            for value, directory_exists in (('', True), ('  \n', True),
                                             ('relative/cache', True), ('/fixture/missing', False)):
                with self.subTest(selector=failing_selector, value=value):
                    def getconf(argv, **keywords):
                        return types.SimpleNamespace(stdout=value if argv[1] == failing_selector else '/fixture/valid')
                    with patch.object(reset.pwd, 'getpwuid', return_value=types.SimpleNamespace(pw_dir='/fixture/user')), \
                            patch.object(Path, 'resolve', lambda path: path), \
                            patch.object(Path, 'is_dir', lambda path: str(path) == '/fixture/valid' or directory_exists), \
                            patch.object(reset, 'check_path', return_value=True), \
                            patch.object(reset.Reset, 'as_user', side_effect=getconf), \
                            patch.object(reset, 'user_preferences') as preferences, \
                            patch.object(reset, 'boot_id') as boot:
                        with self.assertRaisesRegex(RuntimeError, 'No valid per-user cache/temp directory'):
                            reset.Reset(501, Path('/fixture/helper'))
                        preferences.assert_not_called()
                        boot.assert_not_called()
        reset.Reset.native.assert_not_called()

    def test_apply_without_all_pairings_is_rejected_before_initialization(self):
        with patch.dict(reset.os.environ, {'SUDO_UID': '501'}, clear=True), \
                patch.object(reset.os, 'getuid', return_value=0), \
                patch.object(reset.os, 'geteuid', return_value=0), \
                patch.object(reset, 'Reset') as constructor:
            with self.assertRaisesRegex(RuntimeError, '--all-pairings'):
                reset.main(['--apply'])
        constructor.assert_not_called()

    def test_apply_and_verify_without_sudo_are_rejected(self):
        for arguments in (['--apply', '--all-pairings'], ['--verify']):
            with self.subTest(arguments=arguments), \
                    patch.dict(reset.os.environ, {'SUDO_UID': '501'}, clear=True), \
                    patch.object(reset.os, 'getuid', return_value=501), \
                    patch.object(reset.os, 'geteuid', return_value=501), \
                    patch.object(reset, 'Reset') as constructor:
                with self.assertRaisesRegex(RuntimeError, 'Administrator privileges'):
                    reset.main(arguments)
                constructor.assert_not_called()

    def test_root_login_and_invalid_sudo_uid_are_rejected(self):
        for environment in ({}, {'SUDO_UID': '0'}, {'SUDO_UID': 'not-a-uid'}):
            with self.subTest(environment=environment), \
                    patch.dict(reset.os.environ, environment, clear=True), \
                    patch.object(reset.os, 'getuid', return_value=0), \
                    patch.object(reset.os, 'geteuid', return_value=0), \
                    patch.object(reset, 'Reset') as constructor:
                with self.assertRaises((RuntimeError, ValueError)):
                    reset.main(['--apply', '--all-pairings'])
                constructor.assert_not_called()

    @contextlib.contextmanager
    def apply_harness(self, native_failure=False, delete_failure=False):
        subject = reset.Reset.__new__(reset.Reset)
        subject.uid = 501
        subject.user_plists = []
        subject.caches = []
        subject.report = {'boot_before': 'mocked same boot',
                          'removed_files': [], 'removed_cache_directories': [],
                          'unpair_requests': [], 'audio_keys_removed': []}
        subject.journal = None
        subject.preflight = Mock(return_value={})
        subject.save = Mock()
        subject.verify = Mock(return_value={'ok': True})
        subject.delete_preference = Mock(side_effect=RuntimeError('preference delete failed') if delete_failure else None)

        def native(*arguments, **keywords):
            if arguments[0] == '--snapshot':
                return {'ok': True, 'operation': 'snapshot', 'power': 0, 'count': 1, 'paired_count': 1,
                        'devices': [{'address': 'AA:BB:CC:DD:EE:FF', 'paired': True}]}
            if arguments[0] == '--keychain-summary':
                return {'ok': True, 'operation': 'keychain-summary',
                        'keychain': '/Library/Keychains/System.keychain', 'service': 'MobileBluetooth',
                        'accounts': ['11:22:33:44:55:66'], 'count': 1, 'skipped_count': 0}
            if arguments[0] == '--delete-device-pairing-keys':
                if native_failure:
                    raise RuntimeError('native deletion failed after possible partial changes')
                return {'ok': True, 'operation': 'delete-device-pairing-keys',
                        'verified': True, 'remaining_count': 0, 'remaining_accounts': [],
                        'skipped_count': 0, 'remaining_skipped_count': 0}
            return {'ok': True}

        subject.native = Mock(side_effect=native)
        writers = [(101, 0, '/usr/sbin/bluetoothd'),
                   (102, 501, '/usr/libexec/bluetoothuserd'),
                   (103, 202, '/usr/sbin/coreaudiod')]
        with patch.object(Path, 'mkdir'), \
                patch.object(Path, 'glob', return_value=[]), \
                patch.object(reset.os, 'chown'), \
                patch.object(reset.pwd, 'getpwuid', return_value=types.SimpleNamespace(pw_gid=20)), \
                patch.object(reset, 'processes', return_value=writers), \
                patch.object(reset, 'still_same', return_value=True), \
                patch.object(reset, 'check_path', return_value=False), \
                patch.object(reset, 'run', return_value=types.SimpleNamespace(stdout='T', stderr='', returncode=0)), \
                patch.object(reset.os, 'kill') as kill, \
                patch.object(reset.time, 'sleep'), \
                contextlib.redirect_stdout(io.StringIO()):
            yield subject, writers, kill

    def assert_all_paused_released(self, writers, kill, release_signal):
        self.assertEqual(kill.call_args_list,
                         [call(row[0], signal.SIGSTOP) for row in writers] +
                         [call(row[0], release_signal) for row in reversed(writers)])

    def test_native_deletion_exception_releases_all_paused_writers(self):
        with self.apply_harness(native_failure=True) as (subject, writers, kill):
            with self.assertRaisesRegex(RuntimeError, 'native deletion failed'):
                subject.apply()
            self.assert_all_paused_released(writers, kill, signal.SIGKILL)
            subject.delete_preference.assert_not_called()
            subject.verify.assert_not_called()

    def test_preference_deletion_exception_releases_all_paused_writers(self):
        with self.apply_harness(delete_failure=True) as (subject, writers, kill):
            with self.assertRaisesRegex(RuntimeError, 'preference delete failed'):
                subject.apply()
            self.assert_all_paused_released(writers, kill, signal.SIGKILL)
            subject.verify.assert_not_called()

    def test_failed_pause_confirmation_resumes_every_attempted_writer(self):
        with self.apply_harness() as (subject, writers, kill):
            def pause_state(argv, **keywords):
                return types.SimpleNamespace(stdout='T' if argv[2] == writers[0][0] else 'R')
            with patch.object(reset, 'run', side_effect=pause_state):
                with self.assertRaisesRegex(RuntimeError, 'Could not confirm writer pause'):
                    subject.apply()
            self.assert_all_paused_released(writers[:2], kill, signal.SIGCONT)
            self.assertNotIn(call('--delete-device-pairing-keys', '--apply', system=True), subject.native.call_args_list)

    def test_disappeared_process_during_cleanup_does_not_skip_remaining_writers(self):
        with self.apply_harness(native_failure=True) as (subject, writers, kill):
            def send(pid, number):
                if pid == writers[-1][0] and number == signal.SIGKILL:
                    raise ProcessLookupError('already exited')
            kill.side_effect = send
            with self.assertRaisesRegex(RuntimeError, 'native deletion failed'):
                subject.apply()
            self.assert_all_paused_released(writers, kill, signal.SIGKILL)

    def test_release_permission_error_attempts_resume_and_continues_other_writers(self):
        for resume_fails in (False, True):
            with self.subTest(resume_fails=resume_fails), \
                    self.apply_harness(native_failure=True) as (subject, writers, kill):
                failing_pid = writers[-1][0]

                def send(pid, number):
                    if pid == failing_pid and (number == signal.SIGKILL or
                                              (number == signal.SIGCONT and resume_fails)):
                        raise PermissionError('mocked signal permission failure')

                kill.side_effect = send
                with self.assertRaisesRegex(RuntimeError, 'Could not release all stopped writers'):
                    subject.apply()
                self.assertEqual(kill.call_args_list,
                                 [call(row[0], signal.SIGSTOP) for row in writers] +
                                 [call(failing_pid, signal.SIGKILL), call(failing_pid, signal.SIGCONT)] +
                                 [call(row[0], signal.SIGKILL) for row in reversed(writers[:-1])])
                self.assertEqual(len(subject.report['writer_release_errors']), 2 if resume_fails else 1)
                subject.verify.assert_not_called()

    def test_release_identity_check_exception_does_not_skip_other_writers(self):
        writers = [(101, 0, '/usr/sbin/bluetoothd'), (102, 501, '/usr/libexec/bluetoothuserd')]
        with patch.object(reset, 'still_same', side_effect=[RuntimeError('mocked ps failure'), True, True]), \
                patch.object(reset.os, 'kill') as kill:
            failures = reset.release_writers(writers, changed=True)
        self.assertEqual(kill.call_args_list, [call(102, signal.SIGCONT), call(101, signal.SIGKILL)])
        self.assertEqual(len(failures), 1)
        self.assertIn('mocked ps failure', failures[0])

    def test_unexpected_keychain_items_refuse_before_any_reset_action(self):
        for skipped_count in (1, None):
            with self.subTest(skipped_count=skipped_count), \
                    self.apply_harness() as (subject, writers, kill):
                original_native = subject.native.side_effect

                def native(*arguments, **keywords):
                    result = original_native(*arguments, **keywords)
                    if arguments[0] == '--keychain-summary':
                        if skipped_count is None:
                            result.pop('skipped_count')
                        else:
                            result['skipped_count'] = skipped_count
                    return result

                subject.native.side_effect = native
                with self.assertRaisesRegex(RuntimeError, 'Unexpected Bluetooth credential items'):
                    subject.apply()
                self.assertEqual(subject.native.call_args_list,
                                 [call('--snapshot'), call('--keychain-summary', system=True)])
                kill.assert_not_called()
                subject.delete_preference.assert_not_called()
                subject.verify.assert_not_called()
                subject.save.assert_not_called()
                self.assertEqual(subject.report['removed_files'], [])
                self.assertEqual(subject.report['unpair_requests'], [])

    def test_existing_empty_plist_skips_defaults_without_unlink(self):
        subject = reset.Reset.__new__(reset.Reset)
        subject.report = {'removed_files': []}
        subject.save = Mock()
        path = Path('/fixture/preferences/com.apple.bluetooth.plist')
        with patch.object(reset, 'check_path', return_value=True), \
                patch.object(reset, 'run') as commands, \
                patch.object(Path, 'exists', return_value=True), \
                patch.object(Path, 'read_bytes', return_value=plistlib.dumps({})), \
                patch.object(Path, 'unlink', side_effect=AssertionError('Do not remove retained empty domain')) as unlink:
            subject.delete_preference(path)
        commands.assert_not_called()
        self.assertEqual(subject.report['removed_files'], [])
        self.assertEqual(subject.report['empty_preference_files'], [str(path)])
        subject.save.assert_called_once_with()
        unlink.assert_not_called()

    def test_nonempty_plist_after_defaults_delete_is_rejected(self):
        subject = reset.Reset.__new__(reset.Reset)
        subject.report = {'removed_files': []}
        subject.save = Mock()
        with patch.object(reset, 'check_path', return_value=True), \
                patch.object(reset, 'run', return_value=types.SimpleNamespace(returncode=0, stderr='')), \
                patch.object(Path, 'exists', return_value=True), \
                patch.object(Path, 'read_bytes', return_value=plistlib.dumps({'DeviceCache': {'retained': True}})):
            with self.assertRaisesRegex(RuntimeError, 'Preference domain still contains values'):
                subject.delete_preference(Path('/fixture/preferences/com.apple.bluetooth.plist'))
        subject.save.assert_not_called()

    def test_defaults_missing_domain_only_accepted_when_absence_confirmed(self):
        path = Path('/fixture/preferences/com.apple.bluetooth.plist')
        for user in (False, True):
            for state in ('absent', 'empty', 'nonempty', 'denied'):
                with self.subTest(user=user, state=state):
                    subject = reset.Reset.__new__(reset.Reset)
                    subject.report = {'removed_files': []}
                    subject.save = Mock()
                    error = ("Error: Domain '%s' not found.\nDefaults have not been changed.\n" %
                             path.with_suffix('')) if state != 'denied' else 'Operation not permitted'
                    result = types.SimpleNamespace(returncode=1, stderr=error)
                    subject.as_user = Mock(return_value=result)
                    checks = [True, False, False] if state == 'absent' else [True, True, True]
                    data = [plistlib.dumps({'old': True}),
                            plistlib.dumps({'old': True} if state == 'nonempty' else {})]
                    with patch.object(reset, 'check_path', side_effect=checks), \
                            patch.object(Path, 'read_bytes', side_effect=data), \
                            patch.object(reset, 'run', return_value=result) as commands:
                        if state in ('nonempty', 'denied'):
                            with self.assertRaises(RuntimeError):
                                subject.delete_preference(path, user=user)
                        else:
                            subject.delete_preference(path, user=user)
                        (subject.as_user if user else commands).assert_called_once_with(
                            ['/usr/bin/defaults', 'delete', path.with_suffix('')], timeout=15, check=False)

    def test_local_failure_does_not_skip_independent_cleanup_or_writer_release(self):
        with self.apply_harness(delete_failure=True) as (subject, writers, kill):
            subject.user_plists = [Path('/fixture/user.plist')]
            subject.caches = [Path('/fixture/cache1'), Path('/fixture/cache2')]
            subject.delete_database = Mock()
            subject.clear_cache = Mock(side_effect=[PermissionError('cache denied'), None])
            subject.clear_audio_controls = Mock()
            with self.assertRaisesRegex(RuntimeError, 'Local cleanup incomplete'):
                subject.apply()
            self.assertEqual(subject.delete_preference.call_count, len(reset.SYSTEM_PLISTS) + 1)
            self.assertEqual(subject.delete_database.call_count, len(reset.DATABASES))
            self.assertEqual(subject.clear_cache.call_count, 2)
            subject.clear_audio_controls.assert_called_once()
            self.assertFalse(subject.report['local_stores_processed'])
            self.assertEqual(len(subject.report['cleanup_errors']), len(reset.SYSTEM_PLISTS) + 2)
            self.assert_all_paused_released(writers, kill, signal.SIGKILL)
            subject.verify.assert_not_called()

    def test_audio_failure_continues_next_key_and_checks_unrelated_controls(self):
        subject = reset.Reset.__new__(reset.Reset)
        subject.report = {'audio_keys_removed': []}
        subject.save = Mock()
        first, second = 'AA-BB-CC-DD-EE-FF:input', 'AA-BB-CC-DD-EE-FF:output'
        original = {first: {}, second: {}, 'BuiltIn:output': {'volume': 1}}
        remaining = {key: value for key, value in original.items() if key != second}
        subject.read_preference = Mock(side_effect=[original, remaining, remaining])
        with patch.object(reset, 'run', side_effect=[PermissionError('audio denied'), None]) as commands:
            with self.assertRaisesRegex(RuntimeError, 'Selected Bluetooth audio controls remain'):
                subject.clear_audio_controls(['AA:BB:CC:DD:EE:FF'])
        self.assertEqual(commands.call_count, 2)
        self.assertEqual(subject.report['audio_keys_removed'], [second])
        self.assertEqual(len(subject.report['cleanup_errors']), 1)

    def test_interrupt_during_local_cleanup_releases_writers_immediately(self):
        with self.apply_harness() as (subject, writers, kill):
            subject.delete_preference.side_effect = InterruptedError('user interrupted')
            subject.delete_database = Mock()
            with self.assertRaises(InterruptedError):
                subject.apply()
            subject.delete_database.assert_not_called()
            self.assert_all_paused_released(writers, kill, signal.SIGKILL)

    def test_apply_deletes_only_matching_audio_controls_and_verifies_other_values(self):
        original = {'AA-BB-CC-DD-EE-FF:input': {'volume': 1},
                    '11-22-33-44-55-66:output': {'volume': 2},
                    '77-88-99-AA-BB-CC:input': {'volume': 3},
                    'BuiltInSpeaker:output': {'volume': 4},
                    'AA-BB-CC-DD-EE-FF:other': {'volume': 5}}
        selected = ['AA-BB-CC-DD-EE-FF:input', '11-22-33-44-55-66:output']
        remaining = {key: value for key, value in original.items() if key not in selected}
        with self.apply_harness() as (subject, writers, kill), \
                patch.object(reset, 'check_path', side_effect=lambda path, **kw: path == reset.AUDIO_CONTROLS), \
                patch.object(Path, 'read_bytes', side_effect=[plistlib.dumps(original)] + [plistlib.dumps(remaining)] * 3), \
                patch.object(Path, 'exists', return_value=True), \
                patch.object(reset, 'run', return_value=types.SimpleNamespace(stdout='T')) as commands:
            subject.apply()
            deletes = [entry.args[0] for entry in commands.call_args_list if entry.args[0][0] == '/usr/bin/defaults']
            self.assertCountEqual(deletes, [['/usr/bin/defaults', 'delete', reset.AUDIO_CONTROLS.with_suffix(''), key]
                                           for key in selected])
            self.assertCountEqual(subject.report['audio_keys_removed'], selected)
            self.assert_all_paused_released(writers, kill, signal.SIGKILL)

    def test_partial_rerun_inherits_same_boot_accounts_and_clears_unpaired_device_controls(self):
        partial = Path('/fixture/bluetooth-full-reset-1/result.json')
        older_boot = Path('/fixture/bluetooth-full-reset-2/result.json')
        successful = Path('/fixture/bluetooth-full-reset-3/result.json')
        histories = {
            partial: {'result': 'failed_or_partial', 'boot_before': 'mocked same boot',
                      'original_accounts': ['aa-bb-cc-dd-ee-ff', 'AA:BB:CC:DD:EE:FF']},
            older_boot: {'result': 'failed_or_partial', 'boot_before': 'different boot',
                         'original_accounts': ['11:22:33:44:55:66']},
            successful: {'result': 'local_reset_verified_reboot_required', 'boot_before': 'mocked same boot',
                         'original_accounts': ['77:88:99:AA:BB:CC']},
        }
        original_audio = {'AA-BB-CC-DD-EE-FF:input': {'volume': 1},
                          '11-22-33-44-55-66:input': {'volume': 2},
                          '77-88-99-AA-BB-CC:output': {'volume': 3},
                          'BuiltInSpeaker:output': {'volume': 4}}
        remaining_audio = {key: value for key, value in original_audio.items() if key != 'AA-BB-CC-DD-EE-FF:input'}
        with self.apply_harness() as (subject, writers, kill):
            default_native = subject.native.side_effect

            def native(*arguments, **keywords):
                result = default_native(*arguments, **keywords)
                if arguments[0] == '--snapshot':
                    result.update(devices=[], count=0, paired_count=0)
                elif arguments[0] == '--keychain-summary':
                    result.update(accounts=[], count=0)
                return result

            subject.native.side_effect = native
            with patch.object(Path, 'glob', side_effect=lambda pattern: list(histories)), \
                    patch.object(Path, 'read_text', lambda path: json.dumps(histories[path])), \
                    patch.object(reset, 'check_path', side_effect=lambda path, **kw: path == reset.AUDIO_CONTROLS), \
                    patch.object(Path, 'read_bytes', side_effect=[plistlib.dumps(original_audio)] + [plistlib.dumps(remaining_audio)] * 2), \
                    patch.object(Path, 'exists', return_value=True), \
                    patch.object(reset, 'run', return_value=types.SimpleNamespace(stdout='T')) as commands:
                subject.apply()
            self.assertEqual(subject.report['original_accounts'], ['AA:BB:CC:DD:EE:FF'])
            self.assertEqual(subject.report['resuming_reports'], [str(partial)])
            self.assertEqual(subject.report['audio_keys_removed'], ['AA-BB-CC-DD-EE-FF:input'])
            self.assertEqual([entry.args for entry in subject.native.call_args_list if entry.args[0] == '--unpair'],
                             [('--unpair', 'AA:BB:CC:DD:EE:FF')])
            self.assertEqual([entry.args[0] for entry in commands.call_args_list if entry.args[0][0] == '/usr/bin/defaults'],
                             [['/usr/bin/defaults', 'delete', reset.AUDIO_CONTROLS.with_suffix(''), 'AA-BB-CC-DD-EE-FF:input']])
            subject.verify.assert_called_once_with(require_new_boot=False, original_accounts={'AA:BB:CC:DD:EE:FF'})
            self.assert_all_paused_released(writers, kill, signal.SIGKILL)

    @contextlib.contextmanager
    def verify_harness(self, skipped_count=0, audio=None):
        subject = reset.Reset.__new__(reset.Reset)

        def native(*arguments, **keywords):
            if arguments[0] == '--snapshot':
                return {'ok': True, 'operation': 'snapshot', 'power': 0,
                        'paired_count': 0, 'count': 0, 'devices': []}
            if arguments[0] == '--keychain-summary':
                value = {'ok': True, 'operation': 'keychain-summary',
                         'service': 'MobileBluetooth', 'accounts': [], 'count': 0}
                if skipped_count is not None:
                    value['skipped_count'] = skipped_count
                return value
            raise AssertionError('Unexpected native operation: ' + str(arguments))

        subject.native = Mock(side_effect=native)
        with patch.object(Path, 'exists', lambda path: path == reset.AUDIO_CONTROLS and audio is not None), \
                patch.object(Path, 'read_bytes', return_value=plistlib.dumps(audio or {})), \
                patch.object(reset, 'boot_id', return_value='new mocked boot'):
            yield subject

    def test_verify_rejects_non_mac_skipped_keychain_items_or_missing_count(self):
        # The helper excludes non-MAC MobileBluetooth items from accounts/count and
        # reports them as skipped; zero eligible items alone is not a clean result.
        for skipped_count in (1, None):
            with self.subTest(skipped_count=skipped_count), \
                    self.verify_harness(skipped_count=skipped_count) as subject:
                result = subject.verify()
                self.assertFalse(result['ok'])
                self.assertEqual(result['keychain_device_count'], 0)
                self.assertEqual(result['keychain_unexpected_count'], skipped_count)
                self.assertEqual(subject.native.call_args_list,
                                 [call('--snapshot'), call('--keychain-summary', system=True)])

    def test_verify_rejects_original_account_audio_controls_but_ignores_other_controls(self):
        target_key = 'AA-BB-CC-DD-EE-FF:input'
        unrelated = {'77-88-99-AA-BB-CC:input': {'volume': 3}, 'BuiltInSpeaker:output': {'volume': 4}}
        for retained in (False, True):
            audio = {**unrelated, **({target_key: {'volume': 1}} if retained else {})}
            with self.subTest(retained=retained), self.verify_harness(audio=audio) as subject:
                result = subject.verify(original_accounts=['aa:bb:cc:dd:ee:ff'])
                self.assertEqual(result['ok'], not retained)
                self.assertEqual(result['matching_audio_controls_remaining'], [target_key] if retained else [])

    def test_post_reboot_verify_uses_original_accounts_from_record_for_audio_check(self):
        journal = Path('/fixture/bluetooth-full-reset-20261108/result.json')
        original = {'original_accounts': ['AA:BB:CC:DD:EE:FF'], 'boot_before': 'old mocked boot',
                    'local_stores_processed': True, 'keychain_deletion': {'verified': True}}
        with self.verify_harness(audio={'AA-BB-CC-DD-EE-FF:output': {}}) as subject, \
                patch.object(Path, 'glob', return_value=iter([journal])), \
                patch.object(Path, 'read_text', return_value=json.dumps(original)):
            result = subject.verify(require_new_boot=True)
        self.assertTrue(result['new_boot'])
        self.assertFalse(result['ok'])
        self.assertEqual(result['matching_audio_controls_remaining'], ['AA-BB-CC-DD-EE-FF:output'])


if __name__ == '__main__':
    unittest.main()
