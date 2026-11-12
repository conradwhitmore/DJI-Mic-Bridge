#!/usr/bin/env python3
"""Inspect the actual installer payload without installing or changing audio devices."""
from pathlib import Path
import argparse
import plistlib
import subprocess
import tarfile
import tempfile
import xml.etree.ElementTree as ET
from privacy_checks import inspect_directory

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--package', type=Path, default=root / 'dist/MicBridge-Installer.pkg')
parser.add_argument('--arch', choices=['arm64', 'x86_64'])
parser.add_argument('--signing', choices=['adhoc'], help='Require an unsigned installer and ad-hoc bundles')
args = parser.parse_args()
package = args.package.resolve()
expected_version = plistlib.loads((root / 'Resources/MicBridge/Info.plist').read_bytes())
if args.signing == 'adhoc':
    signature = subprocess.run(['pkgutil', '--check-signature', str(package)], capture_output=True, text=True)
    assert signature.returncode == 1 and 'Status: no signature' in signature.stdout, signature.stdout + signature.stderr

with tempfile.TemporaryDirectory(prefix='micbridge-package-check-') as directory:
    expanded = Path(directory) / 'expanded'
    subprocess.run(['pkgutil', '--expand-full', str(package), str(expanded)], check=True)
    privacy_findings = inspect_directory(expanded)
    assert not privacy_findings, '\n'.join(privacy_findings)
    distribution = ET.parse(expanded / 'Distribution').getroot()
    assert distribution.find('domains').attrib['enable_localSystem'] == 'true'
    assert distribution.find('domains').attrib['enable_currentUserHome'] == 'false'
    refs = distribution.findall('pkg-ref')
    assert any(ref.attrib.get('onConclusion') == 'RequireRestart' for ref in refs)
    component = expanded / 'MicBridgeComponent.pkg'
    info = ET.parse(component / 'PackageInfo').getroot()
    assert info.attrib['install-location'] == '/'
    payload = component / 'Payload'
    app = payload / 'Applications/MicBridge.app'
    driver = payload / 'Library/Audio/Plug-Ins/HAL/MicBridgeAudio.driver'
    for name in ('mic2.png', 'mini.png', 'mini2.png', 'mic3.png', 'SOURCES.json'):
        expected_artwork = root / 'Resources/MicBridge/Devices' / name
        packaged_artwork = app / 'Contents/Resources/Devices' / name
        assert packaged_artwork.read_bytes() == expected_artwork.read_bytes(), ('Device artwork mismatch', name)
    assert {p.name for p in (payload / 'Library/Audio/Plug-Ins/HAL').iterdir()} == {'MicBridgeAudio.driver'}
    for bundle, identifier in [(app, 'org.dji-mic-rxless.micbridge'), (driver, 'org.dji-mic-rxless.MicBridgeAudio')]:
        with (bundle / 'Contents/Info.plist').open('rb') as stream: plist = plistlib.load(stream)
        assert plist['CFBundleIdentifier'] == identifier
        executable = bundle / 'Contents/MacOS' / plist['CFBundleExecutable']
        archs = subprocess.check_output(['lipo', '-archs', str(executable)], text=True).split()
        if args.arch:
            assert archs == [args.arch], (bundle.name, archs, args.arch)
        if bundle == app:
            assert plist['CFBundleShortVersionString'] == expected_version['CFBundleShortVersionString']
            assert plist['CFBundleVersion'] == expected_version['CFBundleVersion']
            assert plist['LSMinimumSystemVersion'] == '13.0'
            assert set(distribution.find('options').attrib['hostArchitectures'].split(',')) == set(archs)
        # System libraries/frameworks only: no dependency on a developer's Homebrew or build tree.
        for architecture in archs:
            linked = subprocess.check_output(['otool', '-arch', architecture, '-L', str(executable)], text=True).splitlines()[1:]
            for line in linked:
                path = line.strip().split(' (')[0]
                assert path.startswith(('/System/Library/', '/usr/lib/')), (bundle.name, path)
        subprocess.run(['codesign', '--verify', '--strict', str(bundle)], check=True)
        if args.signing == 'adhoc':
            signature = subprocess.check_output(['codesign', '-dv', '--verbose=4', str(bundle)], stderr=subprocess.STDOUT, text=True)
            assert 'Signature=adhoc' in signature and 'Authority=' not in signature, signature
            assert 'TeamIdentifier=not set' in signature, signature
    with (driver / 'Contents/Info.plist').open('rb') as stream: plist = plistlib.load(stream)
    assert plist['CFPlugInFactories'] == {'916f08ef-fd7c-4c34-afc2-edd12a64cb56': 'BlackHole_Create'}
    archive = app / 'Contents/Resources/MicBridgeAudio-Source.tar.gz'
    with tarfile.open(archive) as source:
        if args.signing == 'adhoc':
            for member in source.getmembers():
                assert (member.uid, member.gid, member.uname, member.gname) == (0, 0, 'root', 'wheel'), member.name
                assert not any(part.startswith('._') for part in Path(member.name).parts), member.name
        names = set(source.getnames())
        assert {'Vendor/BlackHole/LICENSE', 'Vendor/BlackHole/BlackHole/BlackHole.c',
                'Vendor/BlackHole/BlackHole/MicBridgeAudioConfig.h',
                'Vendor/BlackHole/BlackHole.xcodeproj/project.pbxproj',
                'scripts/build-micbridge-audio-driver.sh'}.issubset(names)
        assert source.extractfile('Vendor/BlackHole/BlackHole/BlackHole.c').read() == (root / 'Vendor/BlackHole/BlackHole/BlackHole.c').read_bytes()
    subprocess.run(['bash', '-n', str(component / 'Scripts/preinstall')], check=True)
    assert (component / 'Scripts/preinstall').read_bytes() == (root / 'packaging/micbridge/scripts/preinstall').read_bytes()
    print(f'PASS: {package.name}: App + driver, device artwork, version, architectures, system-only libraries, signatures, restart, fixed paths, GPL source, preinstall guard')
