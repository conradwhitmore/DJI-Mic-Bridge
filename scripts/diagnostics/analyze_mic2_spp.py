#!/usr/bin/env python3
"""Strict offline SPP framing/statistics. No Bluetooth, audio IO or network APIs."""
import argparse
from collections import Counter
from datetime import datetime
import hashlib
import json
from math import log2
from pathlib import Path

from mic2_link_events import Frame, crc8, crc16


def envelopes(data):
    """Yield (offset, unknown block, control); fail closed, never resynchronize."""
    pos = 0
    while pos < len(data):
        if len(data) - pos < 3 or data[pos] != 0xAA:
            raise ValueError(f'invalid/truncated envelope at {pos}')
        tag, n = data[pos + 1:pos + 3]
        if tag not in (0, 0x14) or (n < 13 and not (tag == 0x14 and n == 0)):
            raise ValueError(f'unsupported envelope at {pos}')
        start = pos + (628 if tag == 0x14 else 3)
        end = start + n + 1
        if end > len(data) or data[end - 1] != 0xA5:
            raise ValueError(f'truncated envelope or invalid trailer at {pos}')
        control = data[start:start + n]
        if n and (control[0] != 0x55
                  or (int.from_bytes(control[1:3], 'little') & 0x3FF) != n
                  or crc8(control[:3]) != control[3]
                  or crc16(control[:-2]) != int.from_bytes(control[-2:], 'little')):
            raise ValueError(f'invalid DUML length/checksum at {pos}')
        yield pos, data[pos + 3:start], control
        pos = end


def entropy(data):
    n = len(data)
    return -sum(count / n * log2(count / n) for count in Counter(data).values()) if n else 0.0


def callback_summary(events, raw_size):
    rx = [event for event in events if event.get('kind') == 'rx']
    offset = 0
    times = []
    for event in rx:
        if event['offset'] != offset or event['count'] <= 0:
            raise ValueError('RX event coverage gap/overlap/invalid count')
        offset += event['count']
        times.append(datetime.fromisoformat(event['source_time'].replace('Z', '+00:00')).timestamp())
    if offset != raw_size:
        raise ValueError('RX events do not cover the complete raw file')
    if any(b < a for a, b in zip(times, times[1:])):
        raise ValueError('RX source timestamps run backwards')
    return {'count': len(rx), 'covered_bytes': offset,
            'first_to_last_seconds': times[-1] - times[0] if len(times) > 1 else None,
            'note': 'Receive callback timing includes buffering; not the acoustic onset or sample clock.'}


def analyze(data, events=None):
    parsed = list(envelopes(data))
    blocks = [block for _, block, _ in parsed if block]
    parts = [block[i:i + 125] for block in blocks for i in range(0, 625, 125)]
    controls = [Frame(control) for _, _, control in parsed if control]
    seq = Counter((b[12] - a[12]) & 255 for a, b in zip(parts, parts[1:]))
    ticks = Counter((int.from_bytes(b[:4], 'little') - int.from_bytes(a[:4], 'little')) & 0xFFFFFFFF
                    for a, b in zip(parts, parts[1:]))
    fields = []
    for i in range(125) if parts else []:
        values = bytes(part[i] for part in parts)
        counts = Counter(values)
        fields.append({'offset': i, 'distinct': len(counts), 'min': min(counts), 'max': max(counts),
                       'entropy_bits': round(entropy(values), 6)})
    result = {
        'mode': 'offline_only', 'raw_sha256': hashlib.sha256(data).hexdigest(), 'raw_bytes': len(data),
        'envelopes': len(parsed), 'unknown_625_byte_blocks': len(blocks),
        'valid_control_frames': len(controls), 'commands': dict(Counter(frame.command for frame in controls)),
        'control_crc_validates_unknown_block': False,
        'subblocks': len(parts), 'subblock_bytes': 125,
        'fixed_offsets': {str(i): f'{parts[0][i]:02x}' for i in range(125)
                          if parts and all(part[i] == parts[0][i] for part in parts)},
        'offset12_mod256_deltas': dict(sorted(seq.items())),
        'offset0_uint32le_deltas': dict(sorted(ticks.items())),
        'per_offset_statistics': fields,
        'audio_decoding_performed_by_this_analyzer': False,
        'limitations': ['Unknown block integrity/checksum and codec are not established.',
                        'A fixed cadence, continuous counter or high entropy does not establish audio.',
                        'Speech markers record operator interactions, not precisely synchronized acoustic boundaries.']}
    if events is not None:
        result['callbacks'] = callback_summary(events, len(data))
        span = result['callbacks']['first_to_last_seconds']
        if span and parts:
            result['approx_subblocks_per_second'] = (len(parts) - 5) / span
            result['rate_estimator'] = '(subblock count - first group of 5) / first-to-last RX callback span'
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--raw', type=Path, required=True)
    parser.add_argument('--events', type=Path)
    args = parser.parse_args()
    events = [json.loads(line) for line in args.events.read_text().splitlines()] if args.events else None
    print(json.dumps(analyze(args.raw.read_bytes(), events), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
