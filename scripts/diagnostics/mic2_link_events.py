#!/usr/bin/env python3
"""Offline Mic 2 candidate-event decoder. No Bluetooth or keyboard APIs."""
import argparse
from collections import Counter
from dataclasses import dataclass
from datetime import datetime
import json
from pathlib import Path
import re


def crc8(data):
    value = 0x77
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = (value >> 1) ^ (0x8C if value & 1 else 0)
    return value


def crc16(data):
    value = 0x3692
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = (value >> 1) ^ (0x8408 if value & 1 else 0)
    return value


@dataclass(frozen=True)
class Frame:
    raw: bytes

    @property
    def sequence(self):
        return int.from_bytes(self.raw[6:8], 'little')

    @property
    def command(self):
        return self.raw[9:11].hex()

    @property
    def payload(self):
        return self.raw[11:-2]

    @property
    def is_observed_status(self):
        return (self.raw[2] >> 2 == 1 and self.raw[4:6] == b'\x3a\x02'
                and self.raw[8] == 0 and self.command == '02ff'
                and len(self.payload) == 45)


class Decoder:
    def __init__(self, allow_extended=False):
        self.buffer = bytearray()
        self.stats = Counter()
        self.commands = Counter()
        self.allow_extended = allow_extended

    def reset(self):
        self.stats['discarded_session_bytes'] += len(self.buffer)
        self.buffer.clear()

    def feed(self, chunk):
        self.buffer.extend(chunk)
        frames = []
        while len(self.buffer) >= 3:
            tag, n = self.buffer[1:3]
            extended = self.allow_extended and tag == 0x14
            if self.buffer[0] != 0xAA or (tag != 0 and not extended) or (n < 13 and not (extended and n == 0)):
                del self.buffer[0]
                self.stats['discarded_bytes'] += 1
                continue
            # Two observed envelopes only. Meaning of tag 0x14 / its 625 bytes is unknown.
            offset = 628 if extended else 3
            total = offset + n + 1
            if n == 0:
                if len(self.buffer) < total:
                    break
                if self.buffer[total - 1] == 0xA5:
                    self.stats['extended_blocks_without_control_crc'] += 1
                    del self.buffer[:total]
                else:
                    self.stats['discarded_bytes'] += 1
                    del self.buffer[0]
                continue
            if len(self.buffer) < offset + 4:
                break
            header = self.buffer[offset:offset + 4]
            if (header[0] != 0x55
                    or (int.from_bytes(header[1:3], 'little') & 0x3FF) != n
                    or crc8(header[:3]) != header[3]):
                del self.buffer[0]
                self.stats['discarded_bytes'] += 1
                continue
            if len(self.buffer) < total:
                break
            raw = bytes(self.buffer[offset:offset + n])
            if self.buffer[total - 1] != 0xA5 or crc16(raw[:-2]) != int.from_bytes(raw[-2:], 'little'):
                del self.buffer[0]
                self.stats['bad_frame_checksum_or_trailer'] += 1
                continue
            del self.buffer[:total]
            frame = Frame(raw)
            frames.append(frame)
            self.stats['valid_frames'] += 1
            if extended:
                self.stats['valid_control_frames_in_extended_envelope'] += 1
            self.commands[frame.command] += 1
        return frames


class CandidateDetector:
    """Requires idle baseline, then a rising edge. Not a proven key discriminator."""
    def __init__(self, gap_seconds=3.0):
        self.gap_seconds = gap_seconds
        self.reset()

    def reset(self):
        self.last_time = None
        self.last_sequence = None
        self.pressed = None

    def observe(self, frame, timestamp):
        if not frame.is_observed_status:
            return False
        if self.last_time is not None:
            delta = (timestamp - self.last_time).total_seconds()
            if delta < 0 or delta > self.gap_seconds:
                self.reset()
        if self.last_sequence is not None:
            delta = (frame.sequence - self.last_sequence) & 0xFFFF
            if delta == 0 or delta >= 0x8000:
                return False  # Duplicate or out-of-order state cannot cause an edge.
        pressed = bool(frame.payload[9] & 0x08)
        trigger = self.pressed is False and pressed
        self.last_time = timestamp
        self.last_sequence = frame.sequence
        self.pressed = pressed
        return trigger


RX = re.compile(r'^RX (.+?) bytes=\d+ hex=([0-9a-fA-F ]+)$')


def analyze(lines, allow_extended=False):
    decoder = Decoder(allow_extended=allow_extended)
    detector = CandidateDetector()
    events = []
    for line in lines:
        line = line.strip()
        if (line.startswith(('OPEN_REQUEST', 'OPEN_COMPLETE', 'CHANNEL_CLOSED', 'FINISHED'))
                or (line.startswith('STATE ') and ('connected=false' in line or 'open=false' in line))):
            decoder.reset()
            detector.reset()
            continue
        match = RX.match(line)
        if not match:
            continue
        try:
            timestamp = datetime.strptime(match[1], '%Y-%m-%d %H:%M:%S %z')
            chunk = bytes.fromhex(match[2])
        except ValueError:
            decoder.stats['invalid_log_lines'] += 1
            decoder.reset()
            detector.reset()
            continue
        for frame in decoder.feed(chunk):
            if detector.observe(frame, timestamp):
                events.append({'time': timestamp.isoformat(), 'sequence': frame.sequence,
                               'event': 'link_button_candidate_rising_edge'})
    return {'mode': 'offline_only', 'extended_envelope_opt_in': allow_extended, 'stats': dict(decoder.stats),
            'commands': dict(decoder.commands), 'trailing_bytes': len(decoder.buffer),
            'candidate_event_count': len(events), 'candidate_events': events,
            'limitation': 'Other buttons, firmware and live coexistence are not yet validated.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--allow-extended-envelope', action='store_true',
                        help='Offline research: skip observed 625-byte blocks; their meaning/CRC is unknown.')
    args = parser.parse_args()
    with args.log.open() as source:
        result = analyze(source, allow_extended=args.allow_extended_envelope)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
