import contextlib
import io
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import capture_mic2_spp as capture

ADDRESS = 'AA:BB:CC:DD:EE:FF'


class CaptureGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'status.json'
        self.good = {'epoch': 100, 'safe': True, 'target_running': False,
                     'contaminated': False, 'target_present': True,
                     'target_address': 'AABBCCDDEEFF'}

    def write(self, **overrides):
        self.path.write_text(json.dumps({**self.good, **overrides}))

    def test_rejects_audio_activity_old_contamination_stale_status_and_wrong_target(self):
        variants = [{'target_running': True}, {'contaminated': True}, {'safe': False},
                    {'target_present': False}, {'epoch': 97}, {'epoch': 102},
                    {'target_address': '000000000000'}]
        with patch.object(capture.time, 'time', return_value=101):
            self.write()
            self.assertTrue(capture.guard_state(self.path, ADDRESS)['safe'])
            for change in variants:
                with self.subTest(change=change):
                    self.write(**change)
                    with self.assertRaises(RuntimeError):
                        capture.guard_state(self.path, ADDRESS)

    def test_preview_does_not_read_hardware_or_start_process(self):
        with patch.object(sys, 'argv', ['capture', '--device-address', ADDRESS,
                                      '--guard-status', str(self.path)]), \
             patch.object(capture, 'guard_state', side_effect=AssertionError('hardware read')), \
             patch.object(capture.subprocess, 'Popen', side_effect=AssertionError('device open')), \
             contextlib.redirect_stdout(io.StringIO()):
            capture.main()

    def test_live_rejects_unsafe_guard_before_opening_spp(self):
        self.write(target_running=True)
        prefs = plistlib.dumps({'PersistentPorts': {ADDRESS: {
            'BSDName': 'DJI-MIC2-123456', 'RFCOMMChannel': 10}}})
        with patch.object(sys, 'argv', ['capture', '--device-address', ADDRESS,
                                      '--guard-status', str(self.path), '--listen']), \
             patch.object(capture, 'PREFERENCES') as preferences, \
             patch.object(capture.time, 'time', return_value=101), \
             patch.object(capture.subprocess, 'Popen', side_effect=AssertionError('device open')):
            preferences.read_bytes.return_value = prefs
            with self.assertRaisesRegex(RuntimeError, 'audio_guard_unsafe'):
                capture.main()
