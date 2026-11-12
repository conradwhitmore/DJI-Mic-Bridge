#!/usr/bin/env python3
"""Decode the observed Mic 2 SPP LC3plus candidate OFFLINE, without playback.

Experimental layout: five 125-byte units per AA14 block; each unit [13:124]
is a 111-byte, 5 ms, 48 kHz non-HR LC3plus candidate. This is not live support.
Output is private local audio for human verification, not a format guarantee.
"""
import argparse
from array import array
from collections import Counter
import hashlib
import json
import math
import os
from pathlib import Path
import random
import sys
import wave

from analyze_mic2_spp import envelopes
from probe_mic2_lc3_offline import Decoder, library


def dbfs(square_sum, n):
    return 10 * math.log10(square_sum / n) if square_sum > 0 else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--raw', type=Path, required=True)
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--output-directory', type=Path, required=True)
    args = parser.parse_args()
    data = args.raw.read_bytes()
    parts = [block[i:i+125] for _, block, _ in envelopes(data) if block for i in range(0, 625, 125)]
    if not parts or any(part[6:9] != bytes.fromhex('557705') or part[124] != 0 for part in parts):
        parser.error('unrecognized candidate subblock layout')
    if any((b[12] - a[12]) & 255 != 1 for a, b in zip(parts, parts[1:])):
        parser.error('sequence discontinuity: do not silently splice samples')
    lib = library(args.library)
    decoder = Decoder(lib, False, 5000, 48000)
    pcm = array('h')
    counts = Counter()
    clipped = 0
    peak = 0.0
    window_sum = 0.0
    window_samples = 0
    levels = []
    for index, part in enumerate(parts):
        status = decoder.decode(part[13:124])
        counts[status] += 1
        if status != 0:
            parser.error(f'frame {index}: decoder returned {status}; refusing a concealed/noise WAV')
        for value in decoder.pcm:
            if not math.isfinite(value):
                parser.error('non-finite output sample')
            peak = max(peak, abs(value))
            clipped += abs(value) >= 1.0
            window_sum += value * value
            window_samples += 1
            pcm.append(max(-32768, min(32767, round(value * 32768))))
        if (index + 1) % 200 == 0 or index == len(parts) - 1:
            levels.append({'start_seconds': index // 200,
                           'duration_seconds': window_samples / 48000,
                           'rms_dbfs': dbfs(window_sum, window_samples)})
            window_sum = 0.0
            window_samples = 0
    # Negative control preserves frame length but destroys content structure.
    rng = random.Random(20261108)
    negative = Counter()
    neg_decoder = Decoder(lib, False, 5000, 48000)
    for part in parts[:300]:
        shuffled = list(part[13:124])
        rng.shuffle(shuffled)
        negative[neg_decoder.decode(bytes(shuffled))] += 1
    os.umask(0o077)
    args.output_directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    output = args.output_directory / 'mic2-spp-lc3plus-candidate.wav'
    if sys.byteorder != 'little':
        pcm.byteswap()
    with wave.open(str(output), 'wb') as wav:
        wav.setparams((1, 2, 48000, 0, 'NONE', 'not compressed'))
        wav.writeframes(pcm.tobytes())
    report = {'mode': 'offline_candidate_decode', 'raw_sha256': hashlib.sha256(data).hexdigest(),
              'library_sha256': hashlib.sha256(args.library.read_bytes()).hexdigest(),
              'candidate_codec': 'LC3plus 5ms / 48kHz / non-HR / mono',
              'payload_slice': '[13:124] of each 125-byte subblock (111 bytes)',
              'encoded_bitrate': 177600, 'frames': len(parts), 'decoder_return_counts': dict(counts),
              'duration_seconds': len(pcm) / 48000, 'pcm_peak': peak,
              'clipped_samples': clipped, 'pcm_samples': len(pcm),
              'wav_sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
              'negative_control': {'method': 'deterministically shuffle all 111 bytes within each of first 300 payloads',
                                   'decoder_return_counts': dict(negative)},
              'levels': levels, 'human_speech_confirmation': 'pending',
              'limitations': ['Successful decoding alone is not human confirmation of speech.',
                              'No precise speech/silence markers, system input, live playback or device IO.',
                              'No SPP/HFP coexistence or long-term session stability claim.']}
    (args.output_directory / 'decode-report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'levels'}, indent=2))


if __name__ == '__main__':
    main()
