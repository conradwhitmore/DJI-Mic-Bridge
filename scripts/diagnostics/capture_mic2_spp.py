#!/usr/bin/env python3
"""Bounded raw SPP capture for offline audio research; requires an independent audio guard.

No audio capture APIs, device commands, decoding or automatic reconnection. Raw bytes
may contain audio and identifiers: keep the output private and outside Git.
"""
import argparse
import base64
from datetime import datetime
import json
import os
from pathlib import Path
import plistlib
import re
import selectors
import signal
import subprocess
import time

from inspect_mic2_compatibility import PREFERENCES, candidates
from mic2_link_events import Decoder
from watch_mic2_buttons import cpu_percent

REPO = Path(__file__).resolve().parents[2]
MAX_BYTES = 8 * 1024 * 1024


def guard_state(path, address, require_present=True):
    value = json.loads(path.read_text())
    if value.get('target_address') != address.upper().replace(':', '').replace('-', ''):
        raise RuntimeError('audio_guard_wrong_target')
    age = time.time() - value['epoch']
    if not 0 <= age <= 2:
        raise RuntimeError('audio_guard_stale')
    if not value.get('safe') or value.get('target_running') or value.get('contaminated'):
        raise RuntimeError('audio_guard_unsafe')
    if require_present and not value.get('target_present'):
        raise RuntimeError('target_audio_device_disappeared')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device-address', required=True)
    parser.add_argument('--guard-status', type=Path, required=True)
    parser.add_argument('--seconds', type=int, default=60)
    parser.add_argument('--listen', action='store_true')
    args = parser.parse_args()
    address = args.device_address.upper()
    if not re.fullmatch(r'[0-9A-F]{2}(?::[0-9A-F]{2}){5}', address):
        parser.error('Invalid device address')
    if not 10 <= args.seconds <= 90:
        parser.error('Duration must be 10–90 seconds')
    if not args.listen:
        print('PREVIEW: no device access. Live capture requires safe audio guard and --listen.')
        return
    candidate = candidates(plistlib.loads(PREFERENCES.read_bytes()), address)
    if len(candidate) != 1 or candidate[0]['device_family'] != 'DJI Mic 2' or not candidate[0]['matches_observed_channel']:
        raise RuntimeError('Expected saved Mic 2 RFCOMM 10 registration')
    guard_state(args.guard_status, address)
    if cpu_percent() >= 20:
        raise RuntimeError('Audio CPU baseline too high')
    binary = REPO / 'work/diagnostics/mic2-receive-probe'
    if not binary.is_file():
        raise RuntimeError('Build the receiver helper first')
    os.umask(0o077)
    folder = REPO / 'work/diagnostics' / ('spp-stream-' + datetime.now().strftime('%Y%m%d-%H%M%S'))
    folder.mkdir(mode=0o700)
    decoder = Decoder(allow_extended=True)
    child = None
    start = time.monotonic()
    stop_at = None
    reason = None
    total = 0
    peak = 0.0
    last_rx = None
    buffer = bytearray()
    selector = selectors.DefaultSelector()
    with (folder / 'received.bin').open('xb') as raw, (folder / 'events.jsonl').open('x') as events:
        def emit(kind, display=False, **fields):
            item = {'time': datetime.now().astimezone().isoformat(), 'monotonic': time.monotonic(),
                    'kind': kind, **fields}
            line = json.dumps(item, ensure_ascii=False)
            events.write(line + '\n'); events.flush()
            if display:
                print(line, flush=True)

        def stop(why):
            nonlocal reason, stop_at
            if reason is None:
                reason, stop_at = why, time.monotonic()
                emit('stopping', display=True, reason=why)
                if child is not None and child.poll() is None:
                    child.terminate()

        signal.signal(signal.SIGINT, lambda *_: stop('user_cancelled'))
        signal.signal(signal.SIGTERM, lambda *_: stop('user_cancelled'))
        emit('starting', display=True, seconds=args.seconds, folder=str(folder),
             raw_payload_saved_locally=True, audio_IO_requested=False,
             guard_status=str(args.guard_status))
        next_health = next_summary = start
        try:
            child = subprocess.Popen([str(binary), '--listen', address, str(args.seconds)],
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            selector.register(child.stdout, selectors.EVENT_READ)
            while True:
                now = time.monotonic()
                if now >= next_health and reason is None:
                    guard = guard_state(args.guard_status, address)
                    cpu = cpu_percent(); peak = max(peak, cpu)
                    if cpu >= 50:
                        stop('audio_cpu_limit')
                    if now >= next_summary:
                        emit('health', display=True, cpu_percent=cpu, bytes=total,
                             target_running=guard['target_running'], stats=dict(decoder.stats))
                        next_summary = now + 5
                    next_health = now + 0.5
                if now - start >= args.seconds:
                    stop('time_limit')
                if last_rx is not None and now - last_rx > 5:
                    stop('receive_stalled')
                if reason is not None and child.poll() is None and now - stop_at > 3:
                    child.kill()
                for key, _ in selector.select(timeout=0.1):
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                    buffer.extend(chunk)
                if len(buffer) > 262144:
                    raise RuntimeError('helper_message_too_large')
                while b'\n' in buffer:
                    line, _, rest = buffer.partition(b'\n'); buffer = bytearray(rest)
                    message = json.loads(line)
                    kind = message.get('kind')
                    if kind != 'rx':
                        emit('receiver_' + str(kind), display=True,
                             source_time=message.get('time'),
                             **{k: v for k, v in message.items() if k not in ('kind', 'time')})
                        if kind in ('closed', 'stopping', 'refused'):
                            stop(message.get('reason', kind))
                        continue
                    if reason is not None:
                        continue
                    data = base64.b64decode(message['data'], validate=True)
                    if not data or len(data) > 65536 or total + len(data) > MAX_BYTES:
                        stop('capture_size_limit'); continue
                    raw.write(data); raw.flush()
                    emit('rx', source_time=message['time'], offset=total, count=len(data))
                    total += len(data); last_rx = time.monotonic()
                    decoder.feed(data)
                    if decoder.stats['bad_frame_checksum_or_trailer'] or decoder.stats['discarded_bytes'] > 32:
                        stop('unverified_transport_or_crc')
                if child.poll() is not None and not selector.get_map():
                    break
        except Exception as exc:
            stop('error:' + str(exc))
        finally:
            if child is not None and child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill(); child.wait(timeout=3)
            selector.close()
            emit('finished', display=True, reason=reason or 'receiver_exit', bytes=total,
                 peak_cpu_percent=peak, stats=dict(decoder.stats), trailing_bytes=len(decoder.buffer),
                 limitation='No audio decoding. Absence of observed CoreAudio activity needs historical eSCO log verification.')


if __name__ == '__main__':
    main()
