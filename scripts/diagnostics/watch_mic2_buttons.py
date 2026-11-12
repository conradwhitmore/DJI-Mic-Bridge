#!/usr/bin/env python3
"""Manual, bounded RFCOMM test with a CPU watchdog. Default is preview, not live."""
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
from mic2_link_events import Decoder, CandidateDetector

REPO = Path(__file__).resolve().parents[2]


def cpu_percent():
    output = subprocess.check_output(['/bin/ps', '-axo', 'pcpu,comm'], text=True, timeout=3)
    values = [float(line.split(None, 1)[0]) for line in output.splitlines()
              if line.rstrip().endswith('/usr/sbin/coreaudiod')]
    if len(values) != 1:
        raise RuntimeError('Expected one coreaudiod process; refusing to guess CPU state.')
    return values[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device-address', required=True)
    parser.add_argument('--seconds', type=int, default=90)
    parser.add_argument('--listen', action='store_true')
    parser.add_argument('--allow-extended-envelope', action='store_true',
                        help='Explicit research opt-in for the offline-verified AA14/625-byte layout.')
    args = parser.parse_args()
    address = args.device_address.upper().replace('-', ':')
    if not re.fullmatch(r'[0-9A-F]{2}(?::[0-9A-F]{2}){5}', address):
        parser.error('Invalid Bluetooth address')
    if not 10 <= args.seconds <= 120:
        parser.error('Duration must be 10–120 seconds')
    if not args.listen:
        print('PREVIEW: no connection. Live mode is receive-only, time-limited, with CPU and framing guards.')
        return
    preferences = plistlib.loads(PREFERENCES.read_bytes())
    found = candidates(preferences, address)
    if len(found) != 1 or found[0]['device_family'] != 'DJI Mic 2' or not found[0]['matches_observed_channel']:
        raise RuntimeError('Expected one saved DJI Mic 2 / RFCOMM 10 candidate; refusing fallback ports.')
    for _ in range(3):
        if cpu_percent() >= 20:
            raise RuntimeError('Audio CPU is not at a stable baseline. No channel opened.')
        time.sleep(0.5)
    binary = REPO / 'work/diagnostics/mic2-receive-probe'
    if not binary.is_file():
        raise RuntimeError('Build Mic2ReceiveProbe.swift first, following the diagnostics README.')
    work = REPO / 'work/diagnostics'
    log = work / ('button-validation-' + datetime.now().strftime('%Y%m%d-%H%M%S') + '.jsonl')
    decoder = Decoder(allow_extended=args.allow_extended_envelope)
    detector = CandidateDetector()
    child = None
    stopping = False
    stop_at = None
    stop_reason = None
    opened_at = None
    ready = False
    status_count = 0
    last_payload = None
    buffer = bytearray()
    peak_cpu = 0.0
    candidate_events = 0
    transport_seen = set()
    os.umask(0o077)
    with log.open('x') as sink:
        def emit(kind, **fields):
            item = {'time': datetime.now().astimezone().isoformat(), 'kind': kind, **fields}
            line = json.dumps(item, ensure_ascii=False)
            sink.write(line + '\n')
            sink.flush()
            print(line, flush=True)

        def stop(reason):
            nonlocal stopping, stop_at, stop_reason
            if not stopping:
                stopping, stop_at, stop_reason = True, time.monotonic(), reason
                emit('watchdog_stopping', reason=reason)
                if child is not None and child.poll() is None:
                    child.send_signal(signal.SIGTERM)

        def cancel(signum, frame):
            stop('user_cancelled')

        signal.signal(signal.SIGINT, cancel)
        signal.signal(signal.SIGTERM, cancel)
        emit('starting', limit_seconds=args.seconds, cpu_stop_percent=50, raw_payload_saved=False,
             extended_envelope_opt_in=args.allow_extended_envelope)
        started = time.monotonic()
        next_cpu = started
        next_summary = started
        try:
            if stopping:
                return
            child = subprocess.Popen([str(binary), '--listen', address, str(args.seconds)],
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            selector = selectors.DefaultSelector()
            selector.register(child.stdout, selectors.EVENT_READ)
            while True:
                now = time.monotonic()
                if now >= next_cpu:
                    cpu = cpu_percent()
                    peak_cpu = max(peak_cpu, cpu)
                    if cpu >= 50:
                        stop('audio_cpu_limit')
                    if now >= next_summary:
                        emit('health', cpu_percent=cpu, valid_frames=decoder.stats['valid_frames'],
                             statuses=status_count, ready=ready)
                        next_summary = now + 5
                    next_cpu = now + 0.5
                if now - started >= args.seconds:
                    stop('time_limit')
                if opened_at is not None and not ready and now - opened_at > 8:
                    stop('no_verified_idle_status')
                if stopping and child.poll() is None and now - stop_at > 3:
                    emit('forced_exit', reason='close_did_not_finish')
                    child.kill()
                if child.poll() is not None:
                    # Drain remaining stdout before leaving; it can include close status.
                    tail = child.stdout.read()
                    if tail:
                        buffer.extend(tail)
                    ended = True
                else:
                    ended = False
                    for key, _ in selector.select(timeout=0.1):
                        chunk = os.read(key.fd, 65536)
                        if chunk:
                            buffer.extend(chunk)
                while b'\n' in buffer:
                    line, _, remaining = buffer.partition(b'\n')
                    buffer = bytearray(remaining)
                    message = json.loads(line)
                    kind = message.get('kind')
                    if kind != 'rx':
                        emit('receiver_' + str(kind), **{k: v for k, v in message.items() if k not in ('kind', 'time')})
                        if kind == 'opened':
                            opened_at = time.monotonic()
                            decoder.reset()
                            detector.reset()
                        if kind in ('stopping', 'closed', 'refused'):
                            stop(message.get('reason', kind))
                        continue
                    if stopping:
                        continue
                    timestamp = datetime.fromisoformat(message['time'].replace('Z', '+00:00'))
                    chunk = base64.b64decode(message['data'], validate=True)
                    # Prefix/length are framing diagnostics; payload is neither printed nor saved.
                    signature = (len(chunk), chunk[:3].hex())
                    if signature not in transport_seen:
                        transport_seen.add(signature)
                        emit('transport_shape', callback_bytes=signature[0], prefix_3_bytes=signature[1])
                    frames = decoder.feed(chunk)
                    if decoder.stats['discarded_bytes'] > 32 or decoder.stats['bad_frame_checksum_or_trailer']:
                        stop('unverified_transport_or_crc')
                        continue
                    for frame in frames:
                        event = detector.observe(frame, timestamp)
                        if frame.is_observed_status:
                            status_count += 1
                            if last_payload is not None and frame.payload != last_payload:
                                emit('status_changes', offsets=[i for i, (a, b) in enumerate(zip(last_payload, frame.payload)) if a != b],
                                     candidate_bit=bool(frame.payload[9] & 8))
                            last_payload = frame.payload
                        if event:
                            candidate_events += 1
                            emit('candidate_button_event', sequence=frame.sequence, test_ready=ready)
                    if (not ready and status_count >= 3 and detector.pressed is False
                            and opened_at is not None and time.monotonic() - opened_at >= 3):
                        ready = True
                        emit('READY', message='Verified idle status received; no keyboard action will be sent.')
                if ended:
                    break
            selector.close()
        finally:
            if child is not None and child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=3)
            emit('finished', reason=stop_reason or 'receiver_exit', peak_cpu_percent=peak_cpu,
                 candidate_events=candidate_events, commands=dict(decoder.commands), stats=dict(decoder.stats))
    print('Sanitized log: ' + str(log), flush=True)


if __name__ == '__main__':
    main()
