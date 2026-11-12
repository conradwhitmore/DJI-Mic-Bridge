"""Regression checks for source and release privacy boundaries, using synthetic data."""
import io
from pathlib import Path
import struct
import sys
import tarfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from privacy_checks import inspect_bytes


class PublicPrivacyTests(unittest.TestCase):
    def test_rejects_hardware_identifier_but_accepts_documented_examples(self):
        self.assertTrue(inspect_bytes('fixture.txt', b'14:25:36:47:' + b'58:69'))
        self.assertEqual(inspect_bytes('fixture.txt', b'02:11:22:33:44:55'), [])

    def test_rejects_personal_email_preserves_noreply_and_upstream_credit(self):
        self.assertTrue(inspect_bytes('fixture.txt', b'person' + b'@mail.invalid'))
        self.assertEqual(inspect_bytes('fixture.txt', b'123+example@users.noreply.github.com'), [])
        self.assertEqual(inspect_bytes('Vendor/Library/LICENSE', b'author' + b'@mail.invalid'), [])

    def test_rejects_debug_paths_in_binary_without_echoing_them(self):
        secret_path = b'/Users/' + b'builder/private-project/file.o'
        result = inspect_bytes('App/Contents/MacOS/App', b'\x00' + secret_path + b'\x00', source=False)
        self.assertTrue(result)
        self.assertNotIn(secret_path.decode(), '\n'.join(result))

    def test_rejects_credentials_in_vendor_files_too(self):
        token = b'ghp_' + b'A' * 36
        result = inspect_bytes('Vendor/Library/README.md', token)
        self.assertTrue(result)
        self.assertNotIn(token.decode(), '\n'.join(result))

    def test_rejects_signing_and_recording_files_even_if_empty(self):
        for name in ('certificate.p12', 'capture.wav', '.local/config', 'work/session.txt', 'build.pkg'):
            self.assertTrue(inspect_bytes(name, b''), name)

    def test_rejects_png_text_metadata_but_accepts_pixels_only(self):
        header = b'\x89PNG\r\n\x1a\n'
        def chunk(kind, data):
            return struct.pack('>I', len(data)) + kind + data + b'\x00' * 4
        self.assertTrue(inspect_bytes('screenshot.png', header + chunk(b'tEXt', b'Author\0Example')))
        self.assertTrue(inspect_bytes('screenshot.png', header + chunk(b'iCCP', b'Local display profile')))
        self.assertEqual(inspect_bytes('screenshot.png', header + chunk(b'IDAT', b'pixels')), [])

    def archive(self, name, data, owner='root'):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w:gz') as archive:
            member = tarfile.TarInfo(name)
            member.size = len(data)
            member.uname = owner
            member.gname = 'wheel'
            archive.addfile(member, io.BytesIO(data))
        return stream.getvalue()

    def test_recursively_checks_app_icon_png_profiles(self):
        body = b'Local display profile'
        png = b'\x89PNG\r\n\x1a\n' + struct.pack('>I', len(body)) + b'iCCP' + body + b'\x00' * 4
        entry = b'ic10' + struct.pack('>I', len(png) + 8) + png
        icon = b'icns' + struct.pack('>I', len(entry) + 8) + entry
        self.assertTrue(inspect_bytes('Resources/AppIcon.icns', icon))
        self.assertTrue(inspect_bytes('App/Contents/Resources/AppIcon.icns', icon, source=False))

    def test_recursively_checks_archive_contents_and_owner(self):
        safe = self.archive('Vendor/Library/source.c', b'int example;')
        self.assertEqual(inspect_bytes('source.tar.gz', safe, source=False), [])
        self.assertTrue(inspect_bytes('source.tar.gz', safe, source=True))
        personal = self.archive('Vendor/Library/source.c', b'int example;', owner='builder')
        self.assertTrue(inspect_bytes('source.tar.gz', personal, source=False))
        secret = self.archive('Vendor/Library/source.c', b'ghp_' + b'B' * 36)
        self.assertTrue(inspect_bytes('source.tar.gz', secret, source=False))

    def test_rejects_archive_traversal(self):
        unsafe = self.archive('../escape', b'')
        self.assertTrue(inspect_bytes('source.tar.gz', unsafe, source=False))


if __name__ == '__main__':
    unittest.main()
