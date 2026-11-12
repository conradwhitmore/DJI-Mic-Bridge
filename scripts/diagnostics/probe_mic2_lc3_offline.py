#!/usr/bin/env python3
"""Offline LC3 candidate screening, not a confirmed DJI audio decoder.

Requires an explicitly supplied, locally built google/liblc3 library. No device
access, playback, network, dependency installation or PCM files. A return code
of zero is only decoder acceptance, not evidence of intelligible speech.
"""
import argparse
from collections import Counter
import ctypes as ct
import hashlib
import json
from pathlib import Path

from analyze_mic2_spp import envelopes


class Decoder:
    def __init__(self, lib, hr, duration, rate):
        size = lib.lc3_hr_decoder_size(hr, duration, rate)
        if not size:
            raise ValueError('unsupported decoder parameters')
        self.memory = ct.create_string_buffer(size)
        self.handle = lib.lc3_hr_setup_decoder(hr, duration, rate, 0, self.memory)
        if not self.handle:
            raise ValueError('decoder setup failed')
        self.samples = lib.lc3_hr_frame_samples(hr, duration, rate)
        self.pcm = (ct.c_float * self.samples)()
        self.lib = lib

    def decode(self, frame):
        return self.lib.lc3_decode(self.handle, frame, len(frame), 3, self.pcm, 1)


def library(path):
    lib = ct.CDLL(str(path.resolve()))
    lib.lc3_hr_decoder_size.argtypes = [ct.c_bool, ct.c_int, ct.c_int]
    lib.lc3_hr_decoder_size.restype = ct.c_uint
    lib.lc3_hr_setup_decoder.argtypes = [ct.c_bool, ct.c_int, ct.c_int, ct.c_int, ct.c_void_p]
    lib.lc3_hr_setup_decoder.restype = ct.c_void_p
    lib.lc3_hr_frame_samples.argtypes = [ct.c_bool, ct.c_int, ct.c_int]
    lib.lc3_hr_frame_samples.restype = ct.c_int
    lib.lc3_decode.argtypes = [ct.c_void_p, ct.c_void_p, ct.c_int, ct.c_int, ct.c_void_p, ct.c_int]
    lib.lc3_decode.restype = ct.c_int
    return lib


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--raw', type=Path, required=True)
    parser.add_argument('--library', type=Path, required=True)
    args = parser.parse_args()
    data = args.raw.read_bytes()
    parts = [block[i:i+125] for _, block, _ in envelopes(data) if block for i in range(0, 625, 125)]
    if len(parts) < 1000:
        parser.error('at least 1000 subblocks required for separated screening windows')
    # Three separated windows; no assumption that any is speech or silence.
    windows = [parts[a:a+100] for a in (0, len(parts)//2, len(parts)-100)]
    lib = library(args.library)
    results = []
    # 5 ms is the observed cadence. Ranges are boundary hypotheses, not a format declaration.
    for hr, rate in [(False, r) for r in (8000, 16000, 24000, 32000, 48000)] + [(True, 48000), (True, 96000)]:
        for begin in range(10, 21):
            for end in range(120, 126):
                counts = Counter()
                for window in windows:
                    decoder = Decoder(lib, hr, 5000, rate)
                    for part in window:
                        counts[decoder.decode(part[begin:end])] += 1
                results.append({'hr': hr, 'sample_rate': rate, 'frame_us': 5000,
                                'slice_start': begin, 'slice_end_exclusive': end,
                                'decoder_return_counts': dict(counts),
                                'accepted_fraction': counts[0]/300})
    results.sort(key=lambda r: r['accepted_fraction'], reverse=True)
    print(json.dumps({'mode': 'offline_candidate_screen_only',
                      'raw_sha256': hashlib.sha256(data).hexdigest(),
                      'library_sha256': hashlib.sha256(args.library.read_bytes()).hexdigest(),
                      'candidates_tested': len(results), 'subblocks_per_candidate': 300,
                      'return_code_meanings': {'0': 'accepted', '1': 'packet loss concealment', '-1': 'invalid parameters'},
                      'audio_confirmed': False, 'pcm_saved': False,
                      'limitation': 'This finite screen cannot exclude LC3 at other boundaries, modes, transforms or frame aggregation. Acceptance alone does not identify audio.',
                      'results': results}, indent=2))


if __name__ == '__main__':
    main()
