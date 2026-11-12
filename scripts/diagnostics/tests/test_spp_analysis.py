import sys
from pathlib import Path
import unittest
import math

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from analyze_mic2_spp import analyze, callback_summary, envelopes
from mic2_link_events import crc8, crc16
from inspect_pcm_bandwidth import fft, region
from analyze_mic2_stimulus import align
from make_mic2_bandwidth_stimulus import generate
from inspect_mic2_stream_rate import slope


def control():
    head = bytes.fromhex('550d04')
    frame = head + bytes([crc8(head)]) + bytes.fromhex('3a020100000232')
    return frame + crc16(frame).to_bytes(2, 'little')


def block(control=b''):
    parts = []
    for i in range(5):
        part = bytearray(125)
        part[:4] = (16 * i).to_bytes(4, 'little')
        part[6:9] = bytes.fromhex('557705')
        part[12] = (254 + i) & 255
        parts.append(part)
    return b'\xaa\x14' + bytes([len(control)]) + b''.join(parts) + control + b'\xa5'


class AnalysisTests(unittest.TestCase):
    def test_sequence_wrap_and_control(self):
        result = analyze(block(control()))
        self.assertEqual(result['offset12_mod256_deltas'], {1: 4})
        self.assertEqual(result['offset0_uint32le_deltas'], {16: 4})
        self.assertEqual(result['commands'], {'0232': 1})
        self.assertFalse(result['audio_decoding_performed_by_this_analyzer'])

    def test_reject_truncation_or_bad_control(self):
        raw = block(control())
        for value in [raw[:-1], raw[:-2] + b'\xff\xa5', raw[1:], b'\xaa\x14\x01']:
            with self.assertRaises(ValueError):
                list(envelopes(value))

    def test_unknown_block_has_no_checksum_claim(self):
        raw = bytearray(block(control()))
        raw[90] ^= 0x80
        result = analyze(raw)
        self.assertFalse(result['control_crc_validates_unknown_block'])
        self.assertEqual(result['valid_control_frames'], 1)

    def test_event_coverage_rejects_gap(self):
        event = {'kind': 'rx', 'offset': 1, 'count': 3, 'source_time': '2026-11-08T09:00:00.000Z'}
        with self.assertRaises(ValueError):
            callback_summary([event], 4)

    def test_spectral_power_for_known_high_frequency_tone(self):
        rate = 48000
        values = [0.5 * math.sin(2 * math.pi * 9000 * i / rate) for i in range(4096)]
        result = region(values, rate, 0, len(values) / rate)
        self.assertAlmostEqual(result['bands'][2]['mean_square'], 0.125, places=5)
        self.assertLess(result['bands'][1]['mean_square'], 1e-8)

    def test_fft_impulse_and_dc_removal(self):
        self.assertEqual(fft([1, 0, 0, 0]), [1, 1, 1, 1])
        result = region([0.1] * 4096, 48000, 0, 4096 / 48000)
        self.assertLess(sum(band['mean_square'] for band in result['bands']), 1e-20)

    def test_stimulus_timeline_and_alignment(self):
        pcm, metadata = generate()
        self.assertEqual(len(pcm), round(36.2 * 48000))
        self.assertLessEqual(max(abs(v) for v in pcm), 4126)
        events = metadata['timeline']
        self.assertTrue(all(a['end_sample_exclusive'] == b['start_sample']
                            for a,b in zip(events,events[1:])))
        # Known delayed input validates timing without any microphone or speaker.
        delay = 0.35
        values = [0.0] * round(delay*48000) + [v/32768 for v in pcm]
        result = align(values,48000,events,0.2)
        self.assertAlmostEqual(result['offset_seconds'],delay,delta=0.06)
        self.assertGreater(result['reference_envelope_correlation'],0.95)

    def test_alignment_rejects_no_reference(self):
        with self.assertRaises(ValueError):
            align([0.0]*600000,48000,[],0)

    def test_codec_edge_stimulus_is_bounded_and_repeated(self):
        pcm, metadata = generate('codec-edge')
        tones=[e['frequency_hz'] for e in metadata['timeline'] if e['kind']=='test_tone']
        self.assertEqual(len(pcm),41*48000)
        self.assertEqual(len(tones),14)
        for f in (997,17417,19001,19873,20507,21701,22943):
            self.assertEqual(tones.count(f),2)
        self.assertLess(max(tones),24000)

    def test_rate_regression_ignores_constant_offset(self):
        self.assertAlmostEqual(slope([1,2,3,4],[150,350,550,750]),200)
        with self.assertRaises(ValueError):slope([1,1],[0,200])


if __name__ == '__main__':
    unittest.main()
