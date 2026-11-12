import contextlib
from datetime import datetime, timedelta, timezone
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import signal
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from mic2_link_events import Decoder, CandidateDetector, Frame, analyze, crc8, crc16
from inspect_mic2_compatibility import candidates
from inspect_mic2_log_transport import inspect as inspect_transport
import watch_mic2_buttons as watchdog


def status_frame(seq, pressed=False, source=0x3A, command=b'\x02\xff', flags=0):
    payload = bytearray(45)
    payload[9] = 8 if pressed else 0
    raw = bytearray(b'\x55\x3a\x04\x70')
    raw.extend([source, 2])
    raw.extend(seq.to_bytes(2, 'little'))
    raw.extend([flags])
    raw.extend(command)
    raw.extend(payload)
    raw.extend(crc16(raw).to_bytes(2, 'little'))
    return Frame(bytes(raw))


def wrap(frame):
    return b'\xaa' + len(frame.raw).to_bytes(2, 'big') + frame.raw + b'\xa5'


class StreamTests(unittest.TestCase):
    def test_known_header_crc(self):
        self.assertEqual(crc8(b'\x55\x3a\x04'), 0x70)
        self.assertEqual(crc8(b'\x55\x1d\x04'), 0xDF)

    def test_fragmented_and_combined_frames(self):
        data = b''.join(wrap(status_frame(n)) for n in range(3))
        d = Decoder()
        frames = []
        for byte in data[:70]:
            frames.extend(d.feed(bytes([byte])))
        frames.extend(d.feed(data[70:]))
        self.assertEqual([f.sequence for f in frames], [0, 1, 2])
        self.assertEqual(len(d.buffer), 0)

    def test_corrupt_header_body_trailer_and_resynchronize(self):
        good = wrap(status_frame(1))
        for offset in [2, 6, 24, len(good)-1]:
            with self.subTest(offset=offset):
                damaged = bytearray(good)
                damaged[offset] ^= 0x80
                d = Decoder()
                found = d.feed(b'noise' + damaged + good)
                self.assertEqual([f.sequence for f in found], [1])

    def test_first_pressed_packet_is_not_an_event(self):
        d = CandidateDetector()
        now = datetime.now(timezone.utc)
        self.assertFalse(d.observe(status_frame(1, True), now))
        self.assertFalse(d.observe(status_frame(2, True), now))
        self.assertFalse(d.observe(status_frame(3, False), now))
        self.assertTrue(d.observe(status_frame(4, True), now))

    def test_duplicates_late_packets_and_sequence_wrap(self):
        d = CandidateDetector()
        now = datetime.now(timezone.utc)
        self.assertFalse(d.observe(status_frame(65534), now))
        self.assertTrue(d.observe(status_frame(65535, True), now))
        self.assertFalse(d.observe(status_frame(65535, True), now))
        self.assertFalse(d.observe(status_frame(0), now))
        self.assertFalse(d.observe(status_frame(65535, True), now))
        self.assertTrue(d.observe(status_frame(1, True), now))

    def test_gap_or_new_session_requires_new_idle(self):
        d = CandidateDetector()
        now = datetime.now(timezone.utc)
        d.observe(status_frame(1), now)
        self.assertFalse(d.observe(status_frame(2, True), now + timedelta(seconds=4)))
        d.reset()
        self.assertFalse(d.observe(status_frame(3, True), now + timedelta(seconds=5)))

    def test_unknown_direction_command_and_flags_are_not_key_events(self):
        d = CandidateDetector()
        now = datetime.now(timezone.utc)
        d.observe(status_frame(1), now)
        for frame in [status_frame(2, True, source=2),
                      status_frame(3, True, command=b'\x00\x32'),
                      status_frame(4, True, flags=0x80)]:
            self.assertFalse(d.observe(frame, now))
        self.assertTrue(d.observe(status_frame(5, True), now))

    def test_log_session_boundary_and_redacted_output(self):
        def rx(seq, pressed):
            b = wrap(status_frame(seq, pressed))
            return 'RX 2026-11-08 06:14:00 +0000 bytes=62 hex=' + b.hex(' ')
        report = analyze([rx(0, False), rx(1, True), rx(2, True), 'CHANNEL_CLOSED',
                          'OPEN_COMPLETE 0', rx(0, True), rx(1, False), rx(2, True)])
        self.assertEqual(report['candidate_event_count'], 2)
        self.assertNotIn('payload', json.dumps(report))

    def test_unknown_transport_forensics_does_not_assert_key_events(self):
        raw = b'unknown' + status_frame(1, True).raw + b'unknown'
        line = 'RX 2026-11-08 06:14:00 +0000 bytes=72 hex=' + raw.hex(' ')
        report = inspect_transport([line])
        self.assertEqual(report['embedded_crc_valid_duml_commands'], {'02ff': 1})
        self.assertEqual(report['embedded_frames_with_known_outer_envelope'], 0)
        self.assertNotIn('candidate_events', report)
        self.assertEqual(analyze([line])['candidate_event_count'], 0)

    def test_extended_envelope_requires_opt_in_and_control_crc(self):
        frame = status_frame(1)
        extended = b'\xaa\x14\x3a' + bytes(625) + frame.raw + b'\xa5'
        empty_control = b'\xaa\x14\x00' + bytes(625) + b'\xa5'
        self.assertEqual(Decoder().feed(extended), [])
        d = Decoder(allow_extended=True)
        found = d.feed(empty_control + extended[:667])
        self.assertEqual(found, [])
        found = d.feed(extended[667:])
        self.assertEqual([f.sequence for f in found], [1])
        self.assertEqual(d.stats['extended_blocks_without_control_crc'], 1)
        self.assertEqual(d.stats['valid_control_frames_in_extended_envelope'], 1)
        self.assertFalse(d.buffer)


class CompatibilityTests(unittest.TestCase):
    def test_exact_model_and_optional_selection(self):
        ports = {'AA:BB:CC:DD:EE:FF': {'BSDName': 'DJI-MIC2-123456', 'RFCOMMChannel': 10},
                 '00:11:22:33:44:55': {'BSDName': 'DJI-MIC-MINI', 'RFCOMMChannel': 10}}
        with tempfile.TemporaryDirectory() as tmp:
            found = candidates({'PersistentPorts': ports}, dev_root=Path(tmp))
            self.assertEqual(len(found), 1)
            self.assertTrue(found[0]['matches_observed_channel'])
            self.assertFalse(found[0]['callout_node_exists'])
            selected = candidates({'PersistentPorts': ports}, '00:11:22:33:44:55', Path(tmp))
            self.assertEqual(selected[0]['device_family'], 'user-selected, unverified')


class WatchdogTests(unittest.TestCase):
    def test_cpu_reader_ignores_unrelated_processes_and_rejects_missing_service(self):
        with patch.object(watchdog.subprocess, 'check_output', return_value=' 90.0 /other\n 1.5 /usr/sbin/coreaudiod\n'):
            self.assertEqual(watchdog.cpu_percent(), 1.5)
        with patch.object(watchdog.subprocess, 'check_output', return_value=' 0.0 /other\n'):
            with self.assertRaises(RuntimeError):
                watchdog.cpu_percent()

    def test_preview_never_starts_child_or_reads_system_preferences(self):
        with patch.object(sys, 'argv', ['watch', '--device-address', 'AA:BB:CC:DD:EE:FF']), \
                patch.object(watchdog.subprocess, 'Popen', side_effect=AssertionError('unexpected child')), \
                patch.object(watchdog, 'cpu_percent', side_effect=AssertionError('unexpected system read')), \
                contextlib.redirect_stdout(io.StringIO()):
            watchdog.main()


class RecoveryTests(unittest.TestCase):
    def test_preview_success_and_rollback_use_no_real_system_calls(self):
        for scenario in ['preview', 'success', 'failure', 'radio_on']:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as tmp:
                spec = importlib.util.spec_from_file_location('recovery', SCRIPTS / 'reset-mic2-audio-controls.py')
                m = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(m)
                m.BASE = Path(tmp)
                m.SOURCE = Path(tmp) / 'DeviceSettings.plist'
                keys = ('AA-BB-CC-DD-EE-FF:input', 'AA-BB-CC-DD-EE-FF:output')
                original = {keys[0]: {'controls': [1]}, keys[1]: {'controls': [2]},
                            'other-device': {'keep': True}}
                m.SOURCE.write_bytes(plistlib.dumps(original))
                signals = []

                def fake_run(args, **kwargs):
                    if args[0].endswith('system_profiler'):
                        power = 'attrib_on' if scenario == 'radio_on' else 'attrib_off'
                        return types.SimpleNamespace(stdout=json.dumps({'SPBluetoothDataType': [
                            {'controller_properties': {'controller_state': power}}]}))
                    if args[0].endswith('pgrep'):
                        return types.SimpleNamespace(stdout='999999')
                    if args[0].endswith('ps'):
                        return types.SimpleNamespace(stdout='/usr/sbin/coreaudiod' if args[-1] == 'comm=' else 'T')
                    if args[0].endswith('defaults'):
                        if args[1] == 'delete':
                            if scenario == 'failure' and args[3] == keys[1]:
                                raise RuntimeError('simulated write failure')
                            value = plistlib.loads(m.SOURCE.read_bytes())
                            del value[args[3]]
                            m.SOURCE.write_bytes(plistlib.dumps(value))
                        else:
                            m.SOURCE.write_bytes(Path(args[3]).read_bytes())
                        return types.SimpleNamespace(stdout='')
                    raise AssertionError('Unexpected subprocess: ' + repr(args))

                argv = ['reset', '--device-address', 'AA:BB:CC:DD:EE:FF']
                if scenario != 'preview':
                    argv.append('--apply')
                with patch.object(m, 'run', fake_run), patch.object(m.os, 'geteuid', lambda: 0), \
                        patch.object(m.os, 'kill', lambda pid, sig: signals.append(sig)), \
                        patch.object(m.os, 'chown', lambda *args: None), \
                        patch.object(sys, 'argv', argv), contextlib.redirect_stdout(io.StringIO()):
                    if scenario in ['failure', 'radio_on']:
                        with self.assertRaises(RuntimeError):
                            m.main()
                    else:
                        m.main()
                actual = plistlib.loads(m.SOURCE.read_bytes())
                self.assertEqual(actual, {'other-device': {'keep': True}} if scenario == 'success' else original)
                if scenario == 'success':
                    self.assertEqual(signals[-1], signal.SIGKILL)
                    self.assertTrue((m.BASE / 'work/diagnostics/mic2-audio-reset-status.json').exists())
                elif scenario == 'failure':
                    self.assertEqual(signals[-1], signal.SIGCONT)
                else:
                    self.assertEqual(signals, [])


if __name__ == '__main__':
    unittest.main()
