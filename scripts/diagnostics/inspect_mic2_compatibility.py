#!/usr/bin/env python3
"""Inspect saved OS SPP registrations only. Never opens a Bluetooth/serial channel."""
import argparse
import json
from pathlib import Path
import plistlib
import re

PREFERENCES = Path('/Library/Preferences/com.apple.Bluetooth.plist')


def candidates(preferences, selected_address=None, dev_root=Path('/dev')):
    result = []
    for address, port in preferences.get('PersistentPorts', {}).items():
        if not isinstance(port, dict):
            continue
        name = port.get('BSDName', '')
        named_mic2 = isinstance(name, str) and re.fullmatch(r'DJI-MIC2-[A-Z0-9]+', name.upper()) is not None
        selected = selected_address is not None and address.upper().replace('-', ':') == selected_address
        if selected_address is not None and not selected:
            continue
        if not named_mic2 and not selected:
            continue
        channel = port.get('RFCOMMChannel')
        safe_name = isinstance(name, str) and re.fullmatch(r'[A-Za-z0-9_.-]+', name) is not None
        result.append({'name': name, 'device_family': 'DJI Mic 2' if named_mic2 else 'user-selected, unverified',
                       'registered_rfcomm_channel': channel,
                       'matches_observed_channel': type(channel) is int and channel == 10,
                       'callout_node_exists': bool(safe_name and (dev_root / ('cu.' + name)).exists()),
                       'dialin_node_exists': bool(safe_name and (dev_root / ('tty.' + name)).exists()),
                       'live_connection': 'not queried', 'button_support': 'candidate only'})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device-address', help='Explicitly select a renamed device; does not prove its model.')
    args = parser.parse_args()
    selected = args.device_address.upper().replace('-', ':') if args.device_address else None
    if selected and not re.fullmatch(r'[0-9A-F]{2}(?::[0-9A-F]{2}){5}', selected):
        parser.error('Invalid Bluetooth address')
    data = plistlib.loads(PREFERENCES.read_bytes()) if PREFERENCES.exists() else {}
    print(json.dumps({'mode': 'saved_metadata_only', 'source': str(PREFERENCES),
                      'candidates': candidates(data, selected),
                      'note': 'A saved port is not an open channel or verified button support.'},
                     ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
