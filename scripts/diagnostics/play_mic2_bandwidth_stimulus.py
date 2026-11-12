#!/usr/bin/env python3
"""Explicit bounded speaker playback during an already-running guarded SPP capture.

Does not connect Bluetooth or start any audio input. Temporarily sets output
volume to 25%, then restores it and mute status. Default is preview only.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import re
import subprocess
import time

from capture_mic2_spp import guard_state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device-address', required=True)
    parser.add_argument('--guard-status', type=Path, required=True)
    parser.add_argument('--capture-events', type=Path, required=True)
    parser.add_argument('--wav', type=Path, required=True)
    parser.add_argument('--play', action='store_true')
    args = parser.parse_args()
    if not args.play:
        print('PREVIEW: no playback, volume changes or device access.'); return
    def check():
        g = guard_state(args.guard_status, args.device_address)
        if g['routes']['output'] != 'Mac mini扬声器':
            raise RuntimeError('expected Mac mini built-in speaker route')
        if time.time() - args.capture_events.stat().st_mtime > 2:
            raise RuntimeError('capture status stale')
        with args.capture_events.open('rb') as f:
            f.seek(max(0, args.capture_events.stat().st_size - 32768))
            lines = f.read().splitlines()[1:]
        events = [json.loads(line) for line in lines if line.endswith(b'}')]
        if any(e.get('kind') in ('stopping', 'finished', 'receiver_closed') for e in events):
            raise RuntimeError('capture already stopping')
        if not any(e.get('kind') == 'rx' for e in events):
            raise RuntimeError('no recent SPP data')
    check()
    original = subprocess.check_output(['/usr/bin/osascript', '-e', 'get volume settings'], text=True)
    volume = re.search(r'output volume:(\d+)', original)
    muted = re.search(r'output muted:(true|false)', original)
    if not volume or not muted:
        raise RuntimeError('cannot preserve original volume settings')
    player = None
    markers = args.capture_events.parent / 'speaker-playback.jsonl'
    with markers.open('x') as log:
        def emit(kind, **fields):
            event = {'kind':kind, 'epoch':time.time(), 'monotonic':time.monotonic(),
                     'time':datetime.now().astimezone().isoformat(), **fields}
            log.write(json.dumps(event)+'\n'); log.flush()
            print(json.dumps(event), flush=True)
        emit('preflight', original_volume=int(volume[1]), original_muted=muted[1] == 'true')
        try:
            subprocess.run(['/usr/bin/osascript', '-e', 'set volume output volume 25',
                            '-e', 'set volume without output muted'], check=True, timeout=5)
            check()
            emit('play_requested', stimulus=str(args.wav), note='Request timestamp; hardware/acoustic onset has latency.')
            player = subprocess.Popen(['/usr/bin/afplay', str(args.wav)])
            started = time.monotonic()
            while player.poll() is None:
                check()
                if time.monotonic() - started > 45:
                    raise RuntimeError('playback time limit')
                time.sleep(0.2)
            emit('play_finished', exit_code=player.returncode)
        finally:
            if player is not None and player.poll() is None:
                player.terminate()
                try: player.wait(timeout=2)
                except subprocess.TimeoutExpired: player.kill(); player.wait(timeout=2)
            subprocess.run(['/usr/bin/osascript', '-e', f'set volume output volume {volume[1]}',
                            '-e', 'set volume with output muted' if muted[1] == 'true'
                            else 'set volume without output muted'], check=True, timeout=5)
            emit('volume_restored', volume=int(volume[1]), muted=muted[1] == 'true')


if __name__ == '__main__': main()
