#!/usr/bin/env python3
"""Verify the reviewed MicBridge-only ACK teardown and model-specific Mini 2 transport patch against the original Demo."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory() as directory:
    source = Path(directory) / 'MicSession.swift'
    source.write_bytes((root / 'Sources/RXlessDemo/MicSession.swift').read_bytes())
    result = Path(directory) / 'expected.swift'
    subprocess.run(['/usr/bin/patch', '-s', '-F', '0', '-o', str(result), str(source)],
                   input=(root / 'scripts/micbridge-session.patch').read_bytes(), check=True)
    assert (root / 'Sources/MicBridge/MicSession.swift').read_bytes() == result.read_bytes(), 'Unreviewed transport change'
with tempfile.TemporaryDirectory() as directory:
    source = Path(directory) / 'AudioRoutes.swift'
    source.write_bytes((root / 'Sources/RXlessDemo/AudioRoutes.swift').read_bytes())
    result = Path(directory) / 'expected.swift'
    subprocess.run(['/usr/bin/patch', '-s', '-F', '0', '-o', str(result), str(source)],
                   input=(root / 'scripts/micbridge-routes.patch').read_bytes(), check=True)
    assert (root / 'Sources/MicBridge/AudioRoutes.swift').read_bytes() == result.read_bytes(), 'Unreviewed route change' 
print('Transport verified against ACK-exit, audio-gap and Mini 2 adapter patches; Demo query extensions isolated; route patch permits verified MicBridge Audio/BlackHole inputs and excludes loopback outputs.')
