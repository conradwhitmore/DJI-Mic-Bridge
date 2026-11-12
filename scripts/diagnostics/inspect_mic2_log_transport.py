#!/usr/bin/env python3
"""Offline forensic scan of saved logs. Unknown framing never generates key events."""
import argparse
from collections import Counter
import json
from pathlib import Path
from mic2_link_events import RX, Frame, Decoder, crc8, crc16


def inspect(lines):
    segments = []
    current = bytearray()
    lengths = Counter()
    prefixes = Counter()
    for line in lines:
        line = line.strip()
        if (line.startswith(('OPEN_REQUEST', 'OPEN_COMPLETE', 'CHANNEL_CLOSED', 'FINISHED'))
                or (line.startswith('STATE ') and 'connected=false' in line)):
            if current:
                segments.append(bytes(current))
                current.clear()
            continue
        match = RX.match(line)
        if match:
            chunk = bytes.fromhex(match[2])
            current.extend(chunk)
            lengths[len(chunk)] += 1
            prefixes[chunk[:3].hex()] += 1
    if current:
        segments.append(bytes(current))
    valid = Counter()
    status_bits = Counter()
    known_envelopes = 0
    extended_decoder = Decoder(allow_extended=True)
    for stream in segments:
        extended_decoder.reset()
        extended_decoder.feed(stream)
        i = 0
        while i + 13 <= len(stream):
            header = stream[i:i + 4]
            n = int.from_bytes(header[1:3], 'little') & 0x3FF
            if (header[0] == 0x55 and 13 <= n <= 1023 and i + n <= len(stream)
                    and crc8(header[:3]) == header[3]):
                raw = stream[i:i + n]
                if crc16(raw[:-2]) == int.from_bytes(raw[-2:], 'little'):
                    frame = Frame(raw)
                    valid[frame.command] += 1
                    if frame.is_observed_status:
                        status_bits[str(bool(frame.payload[9] & 8)).lower()] += 1
                    if (i >= 3 and stream[i - 3:i] == b'\xaa' + n.to_bytes(2, 'big')
                            and stream[i + n:i + n + 1] == b'\xa5'):
                        known_envelopes += 1
                    i += n
                    continue
            i += 1
    return {'mode': 'offline_forensics_no_events', 'segments': len(segments),
            'received_bytes': sum(map(len, segments)),
            'frequent_callback_lengths': lengths.most_common(6),
            'frequent_callback_prefixes_3_bytes': prefixes.most_common(6),
            'embedded_crc_valid_duml_commands': dict(valid),
            'embedded_frames_with_known_outer_envelope': known_envelopes,
            'embedded_status_candidate_bit_values': dict(status_bits),
            'observed_extended_envelope_decode': dict(extended_decoder.stats),
            'observed_extended_envelope_trailing_bytes': len(extended_decoder.buffer),
            'limitation': 'CRC-valid embedded frames do not establish the unknown outer protocol or its cause.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--log', required=True, type=Path)
    args = parser.parse_args()
    with args.log.open() as f:
        report = inspect(f)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
