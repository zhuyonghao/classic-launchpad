#!/usr/bin/env python3
"""Regression tests for release preparation; no real applications are run."""

import hashlib
import importlib.util
import os
from pathlib import Path
import plistlib
import stat
import struct
import sys
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).with_name("prepare-release.py")
SPEC = importlib.util.spec_from_file_location("prepare_release", SCRIPT)
release = importlib.util.module_from_spec(SPEC)
# Keep the standalone test run from leaving source-tree bytecode artifacts.
sys.dont_write_bytecode = True
SPEC.loader.exec_module(release)


class PrepareReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.artifacts = self.root / "artifacts"
        self.artifacts.mkdir()
        self.output = self.root / "release"
        self.write_package("ARM64", 0x0100000C)

    def write_package(self, architecture, cpu, version="1.1.14", bundle=release.BUNDLE_IDENTIFIER,
                      magic=release.MACHO_64_MAGIC, binary=None):
        path = self.artifacts / f"ClassicLaunchpad-{architecture}.zip"
        metadata = {"CFBundleShortVersionString": version, "CFBundleIdentifier": bundle}
        if binary is None:
            binary = struct.pack("<IIIIIIII", magic, cpu, 0, 2, 0, 0, 0, 0) + b"synthetic binary payload"
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr(release.PLIST_PATH, plistlib.dumps(metadata))
            archive.writestr(release.BINARY_PATH, binary)
        return path

    def prepare(self, tag="v1.1.14"):
        return release.prepare_release(tag, self.artifacts, self.output)

    def clear_utf8_flags(self, path, selected_indexes=None):
        """Emulate ditto by changing only local and central ZIP name flags."""
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
            central_offset = archive.start_dir
        data = bytearray(path.read_bytes())
        for index, entry in enumerate(entries):
            self.assertEqual(data[central_offset:central_offset + 4], b"PK\x01\x02")
            if selected_indexes is None or index in selected_indexes:
                for flag_offset in (entry.header_offset + 6, central_offset + 8):
                    flags = struct.unpack_from("<H", data, flag_offset)[0]
                    struct.pack_into("<H", data, flag_offset, flags & ~0x800)
            name_length, extra_length, comment_length = struct.unpack_from("<HHH", data, central_offset + 28)
            central_offset += 46 + name_length + extra_length + comment_length
        path.write_bytes(data)

    def assert_rejected(self, tag="v1.1.14"):
        with self.assertRaises(release.ReleasePreparationError):
            self.prepare(tag)
        self.assertFalse(self.output.exists(), "invalid inputs must not expose output assets")

    def test_valid_archives_preserve_original_bytes_metadata_and_checksums(self):
        originals = {}
        for architecture, asset_architecture, _ in release.ARCHITECTURES:
            source = self.artifacts / f"ClassicLaunchpad-{architecture}.zip"
            os.chmod(source, 0o640)
            os.utime(source, ns=(1_600_000_000_000_000_000, 1_600_000_000_123_456_789))
            originals[asset_architecture] = (source.read_bytes(), source.stat())
        assets = self.prepare()
        expected_names = {"ClassicLaunchpad-v1.1.14-arm64.zip", "SHA256SUMS.txt"}
        self.assertEqual({asset.name for asset in assets}, expected_names)
        self.assertEqual({entry.name for entry in self.output.iterdir()}, expected_names)
        expected_checksums = []
        for _, asset_architecture, _ in release.ARCHITECTURES:
            filename = f"ClassicLaunchpad-v1.1.14-{asset_architecture}.zip"
            data, original_stat = originals[asset_architecture]
            asset = self.output / filename
            self.assertEqual(asset.read_bytes(), data)
            self.assertEqual(stat.S_IMODE(asset.stat().st_mode), stat.S_IMODE(original_stat.st_mode))
            self.assertEqual(asset.stat().st_mtime_ns, original_stat.st_mtime_ns)
            expected_checksums.append(f"{hashlib.sha256(data).hexdigest()}  {filename}\n")
        self.assertEqual((self.output / "SHA256SUMS.txt").read_text(encoding="utf-8"), "".join(expected_checksums))

    def test_ditto_utf8_names_without_flags_preserve_original_archive_bytes(self):
        originals = {}
        for architecture, asset_architecture, _ in release.ARCHITECTURES:
            source = self.artifacts / f"ClassicLaunchpad-{architecture}.zip"
            self.clear_utf8_flags(source)
            with zipfile.ZipFile(source) as archive:
                self.assertNotIn(release.PLIST_PATH, archive.namelist())
                self.assertTrue(all(not entry.flag_bits & 0x800 for entry in archive.infolist()))
            originals[asset_architecture] = source.read_bytes()
        assets = self.prepare()
        for _, asset_architecture, _ in release.ARCHITECTURES:
            asset = self.output / f"ClassicLaunchpad-v1.1.14-{asset_architecture}.zip"
            self.assertIn(asset, assets)
            self.assertEqual(asset.read_bytes(), originals[asset_architecture])
        expected_checksums = "".join(
            f"{hashlib.sha256(originals[asset_architecture]).hexdigest()}  ClassicLaunchpad-v1.1.14-{asset_architecture}.zip\n"
            for _, asset_architecture, _ in release.ARCHITECTURES
        )
        self.assertEqual((self.output / "SHA256SUMS.txt").read_text(encoding="utf-8"), expected_checksums)

    def test_canonical_name_duplicates_are_rejected(self):
        path = self.artifacts / "ClassicLaunchpad-ARM64.zip"
        with zipfile.ZipFile(path, "a") as archive:
            with self.assertWarns(UserWarning):
                archive.writestr(release.PLIST_PATH, b"duplicate plist")
        # The unflagged and flagged names decode differently in zipfile,
        # but both refer to the same application path after canonicalization.
        self.clear_utf8_flags(path, selected_indexes={0})
        with zipfile.ZipFile(path) as archive:
            self.assertEqual(archive.namelist().count(release.PLIST_PATH), 1)
        self.assert_rejected()

    def test_missing_architecture_fails_before_output(self):
        (self.artifacts / "ClassicLaunchpad-ARM64.zip").unlink()
        self.assert_rejected()

    def test_unexpected_input_fails_before_output(self):
        (self.artifacts / "extra.zip").write_bytes(b"unexpected")
        self.assert_rejected()

    def test_version_mismatch_fails_before_output(self):
        self.write_package("ARM64", 0x0100000C, version="1.1.13")
        self.assert_rejected()

    def test_intel_binary_in_arm64_archive_fails_before_output(self):
        self.write_package("ARM64", 0x01000007)
        self.assert_rejected()

    def test_intel_archive_is_rejected(self):
        self.write_package("X64", 0x01000007)
        self.assert_rejected()

    def test_invalid_tag_fails_before_output(self):
        for tag in ("1.1.14", "v1.1", "v1.1.14-rc1", "v1.1.14/extra"):
            with self.subTest(tag=tag):
                self.assert_rejected(tag)

    def test_bundle_mismatch_fails_before_output(self):
        self.write_package("ARM64", 0x0100000C, bundle="com.example.OtherApp")
        self.assert_rejected()

    def test_invalid_macho_magic_fails_before_output(self):
        self.write_package("ARM64", 0x0100000C, magic=0xCAFEBABE)
        self.assert_rejected()

    def test_truncated_binary_fails_before_output(self):
        self.write_package("ARM64", 0x0100000C, binary=b"short")
        self.assert_rejected()

    def test_outer_actions_wrapper_is_rejected(self):
        path = self.artifacts / "ClassicLaunchpad-ARM64.zip"
        inner = path.read_bytes()
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(path.name, inner)
        self.assert_rejected()

    def test_existing_release_assets_are_not_overwritten(self):
        self.output.mkdir()
        existing = self.output / "existing.zip"
        existing.write_bytes(b"preserve this release")
        with self.assertRaises(release.ReleasePreparationError):
            self.prepare()
        self.assertEqual(existing.read_bytes(), b"preserve this release")
        self.assertEqual(list(self.output.iterdir()), [existing])


if __name__ == "__main__":
    unittest.main()
