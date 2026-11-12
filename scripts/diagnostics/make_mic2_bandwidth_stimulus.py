#!/usr/bin/env python3
"""Generate a local acoustic bandwidth test WAV and exact timeline. Never plays it."""
import argparse
from array import array
import hashlib
import json
import math
import os
from pathlib import Path
import sys
import wave


def generate(profile='bandwidth'):
    if profile not in ('bandwidth', 'codec-edge'):
        raise ValueError('unknown stimulus profile')
    rate = 48000
    pcm = array('h')
    timeline = []
    def segment(seconds, frequency=None, kind='silence'):
        start = len(pcm)
        n = round(seconds * rate)
        fade = round(0.02 * rate)
        for i in range(n):
            envelope = min(1.0, i / fade, (n - 1 - i) / fade)
            sample = math.sin(2 * math.pi * frequency * i / rate) if frequency else 0.0
            pcm.append(round(32767 * 10**(-18/20) * envelope * sample))
        timeline.append({'kind': kind, 'start_sample': start, 'end_sample_exclusive': len(pcm),
                         'start_seconds': start / rate, 'end_seconds': len(pcm) / rate,
                         'frequency_hz': frequency,
                         'alias_if_sampled_at_16khz': abs((frequency + 8000) % 16000 - 8000) if frequency else None})
    segment(3)
    for _ in range(3):
        segment(0.4, 997, 'alignment_tone'); segment(0.4)
    frequencies = ([997, 9173, 6101, 13931, 11369, 17417, 17417, 11369, 997, 13931, 6101, 9173]
                   if profile == 'bandwidth' else
                   [997, 17417, 19001, 19873, 20507, 21701, 22943,
                    22943, 20507, 19873, 17417, 21701, 19001, 997])
    for frequency in frequencies:
        segment(1.6, frequency, 'test_tone'); segment(0.8)
    segment(2)
    return pcm, {'profile': profile, 'sample_rate': rate, 'channels': 1, 'pcm_bits': 16, 'peak_dbfs': -18,
                 'fade_seconds': 0.02, 'duration_seconds': len(pcm)/rate, 'timeline': timeline,
                 'limitations': ['Speaker frequency response is uncalibrated.',
                                 'Presence of an expected high tone must be checked against aliases, harmonics and silence.',
                                 'Absence of a high tone does not identify which device limits bandwidth.',
                                 'The observed non-HR LC3plus mode limits coded bandwidth to about 20 kHz even at 48 kHz sampling.']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-directory', type=Path, required=True)
    parser.add_argument('--profile', choices=['bandwidth', 'codec-edge'], default='bandwidth')
    args = parser.parse_args()
    pcm, metadata = generate(args.profile)
    os.umask(0o077)
    args.output_directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    if sys.byteorder != 'little': pcm.byteswap()
    wav_path = args.output_directory / 'bandwidth-test-48k.wav'
    with wave.open(str(wav_path), 'wb') as wav:
        wav.setparams((1, 2, 48000, 0, 'NONE', 'not compressed'))
        wav.writeframes(pcm.tobytes())
    metadata['wav_sha256'] = hashlib.sha256(wav_path.read_bytes()).hexdigest()
    (args.output_directory / 'stimulus.json').write_text(json.dumps(metadata, indent=2)+'\n')
    print(json.dumps({'wav': str(wav_path.resolve()), 'seconds': metadata['duration_seconds'],
                      'playback_performed': False}))


if __name__ == '__main__': main()
