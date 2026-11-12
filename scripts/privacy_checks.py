"""Offline checks for public source and distributable metadata; never echo secrets."""
from pathlib import Path, PurePosixPath
import io
import re
import struct
import tarfile


PRIVATE_SUFFIXES = {'.pem', '.key', '.p12', '.p8', '.pfx', '.cer', '.der', '.crt',
                    '.mobileprovision', '.provisionprofile', '.keychain', '.keychain-db',
                    '.wav', '.m4a', '.mp3', '.aac', '.flac', '.aiff', '.caf', '.pklg',
                    '.pcap', '.pcapng', '.btsnoop', '.sqlite', '.sqlite3', '.db', '.log', '.jsonl'}
PRIVATE_PARTS = {'.git', '.local', '.agents', '.build', '.swiftpm', 'work', 'dist',
                 'xcuserdata', '__pycache__', '.DS_Store'}
PRIVATE_NAMES = {'HANDOFF.md', 'HANFOFF.md', 'START-HERE.txt', 'TRANSFER-MANIFEST.json',
                 'skills-lock.json', 'CURRENT-STATE.txt'}
EXAMPLE_MACS = {'00:00:00:00:00:00', 'FF:FF:FF:FF:FF:FF', 'AA:BB:CC:DD:EE:FF',
                '11:22:33:44:55:66', '77:88:99:AA:BB:CC', '00:11:22:33:44:55',
                '02:11:22:A1:B2:C3', '02:11:22:33:44:55'}
EMAIL = re.compile(rb'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')
MAC = re.compile(rb'(?<![0-9A-Fa-f])(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f])')
HOME_PATH = re.compile(rb'/(?:Users|home)/([A-Za-z0-9._-]+)')
SECRETS = (
    re.compile(rb'-----BEGIN (?:[A-Z ]*PRIVATE KEY|CERTIFICATE)-----'),
    re.compile(rb'gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}'),
    re.compile(rb'(?:AKIA|ASIA)[A-Z0-9]{16}'),
    re.compile(rb'sk-(?:proj-)?[A-Za-z0-9_-]{24,}|xox[baprs]-[A-Za-z0-9-]{20,}'),
    re.compile(rb'(?i)(?:api[_-]?key|client[_-]?secret|access[_-]?token|password)\s*[:=]\s*[\x22\x27]([A-Za-z0-9_+/=-]{20,})[\x22\x27]'),
)


def inspect_bytes(name, data, *, source=True, depth=0):
    """Return only rule/location descriptions, not matching personal values."""
    findings = []
    path = PurePosixPath(name)
    if path.suffix.lower() in PRIVATE_SUFFIXES:
        findings.append(f'{name}: private file type')
    if source and path.suffix.lower() in {'.pkg', '.dmg', '.zip', '.bin', '.dylib', '.ipa', '.bundle'}:
        findings.append(f'{name}: generated/binary artifact must not be committed')
    if source and (any(part in PRIVATE_PARTS or part.startswith('._') for part in path.parts)
                   or path.name in PRIVATE_NAMES or path.name.startswith('.env') and path.name != '.env.example'):
        findings.append(f'{name}: private/local file path')
    if name.endswith(('.tar.gz', '.tgz', '.tar')):
        if source:
            findings.append(f'{name}: generated archive must not be committed')
        if depth >= 4:
            return findings + [f'{name}: archive nesting exceeds inspection limit']
        try:
            with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                for member in archive:
                    member_path = PurePosixPath(member.name)
                    if member_path.is_absolute() or '..' in member_path.parts or member.issym() or member.islnk():
                        findings.append(f'{name}: unsafe archive member')
                        continue
                    if (member.uid, member.gid, member.uname, member.gname) != (0, 0, 'root', 'wheel'):
                        findings.append(f'{name}: non-normalized archive owner')
                    if member.isfile():
                        if member.size > 64 * 1024 * 1024:
                            findings.append(f'{name}: archive member exceeds inspection limit')
                            continue
                        findings.extend(inspect_bytes(member.name, archive.extractfile(member).read(), source=source, depth=depth + 1))
        except (tarfile.TarError, OSError):
            findings.append(f'{name}: unreadable archive')
        return findings
    # Pixel data needs a manual review. Inspect textual PNG metadata separately.
    if data.startswith(b'\x89PNG\r\n\x1a\n'):
        pos = 8
        while pos + 12 <= len(data):
            size = struct.unpack('>I', data[pos:pos + 4])[0]
            kind = data[pos + 4:pos + 8]
            body = data[pos + 8:pos + 8 + size]
            if kind in (b'tEXt', b'iTXt', b'zTXt', b'eXIf', b'iCCP'):
                findings.append(f'{name}: remove screenshot text/EXIF/color-profile metadata before publishing')
            pos += 12 + size
        # Third-party artwork may retain upstream metadata, checked manually.
        return [] if path.parts and path.parts[0] == 'Vendor' else findings
    if path.suffix.lower() == '.icns':
        pos = 8
        while pos + 8 <= len(data):
            kind = data[pos:pos + 4]
            size = int.from_bytes(data[pos + 4:pos + 8], 'big')
            if size < 8 or pos + size > len(data):
                return findings + [f'{name}: malformed icon container']
            body = data[pos + 8:pos + size]
            if body.startswith(b'\x89PNG\r\n\x1a\n'):
                # BlackHole's upstream icon uses a reviewed standard sRGB profile.
                label = f'{name}/{kind.decode("ascii", errors="replace")}.png'
                if path.name == 'BlackHole.icns':
                    label = 'Vendor/' + label
                findings.extend(inspect_bytes(label, body, source=source, depth=depth + 1))
            pos += size
        return findings
    for pattern in SECRETS:
        if pattern.search(data):
            findings.append(f'{name}: possible credential material')
    for match in HOME_PATH.finditer(data):
        if match.group(1) not in {b'user', b'example', b'username'}:
            findings.append(f'{name}: embedded build/user home path')
            break
    for match in MAC.finditer(data):
        normalized = match.group().decode().upper().replace('-', ':')
        if normalized not in EXAMPLE_MACS:
            findings.append(f'{name}: non-example hardware address')
            break
    # Keep upstream author/contact attribution; redact first-party personal mail.
    if not path.parts or path.parts[0] != 'Vendor':
        for match in EMAIL.finditer(data):
            value = match.group().lower()
            if value.endswith((b'@users.noreply.github.com', b'@example.com', b'@example.invalid', b'@ultra.png')):
                continue
            # The original BlackHole README is also bundled with the driver.
            if path.name == 'README.md' and value.rsplit(b'@', 1)[-1] == b'existential.audio':
                continue
            findings.append(f'{name}: personal/contact email needs review')
            break
    return findings


def inspect_directory(root):
    findings = []
    for path in sorted(Path(root).rglob('*')):
        if path.is_symlink():
            findings.append(f'{path.relative_to(root)}: unexpected symlink')
        elif path.is_file():
            findings.extend(inspect_bytes(path.relative_to(root).as_posix(), path.read_bytes(), source=False))
    return sorted(set(findings))
