#!/usr/bin/env python3
"""Validate CI app archives and prepare versioned Release assets unchanged."""

import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import tempfile
import zipfile
from xml.parsers.expat import ExpatError


APP_ROOT = "启动台.app/Contents"
PLIST_PATH = f"{APP_ROOT}/Info.plist"
BINARY_PATH = f"{APP_ROOT}/MacOS/ClassicLaunchpad"
BUNDLE_IDENTIFIER = "com.local.ClassicLaunchpad"
MACHO_64_MAGIC = 0xFEEDFACF
ARCHITECTURES = (
    ("ARM64", "arm64", 0x0100000C),
)


class ReleasePreparationError(Exception):
    """The inputs cannot be safely published as this version's Release."""


def canonical_zip_name(entry):
    name = entry.filename
    if not entry.flag_bits & 0x800:
        # macOS ditto writes UTF-8 names without setting the ZIP UTF-8 flag.
        # zipfile decodes those bytes as CP437; recover the original name when valid.
        try:
            name = name.encode("cp437").decode("utf-8")
        except UnicodeError:
            pass
    return name


def validate_archive(path, version, expected_cpu):
    try:
        with zipfile.ZipFile(path) as archive:
            entries = {}
            for entry in archive.infolist():
                name = canonical_zip_name(entry)
                if name in entries:
                    raise ReleasePreparationError(f"{path.name}: duplicate ZIP entry: {name}")
                entries[name] = entry
            for required in (PLIST_PATH, BINARY_PATH):
                if required not in entries:
                    raise ReleasePreparationError(
                        f"{path.name}: expected exactly one {required}; "
                        "supply the inner application ZIP, not the Actions wrapper"
                    )
            metadata = plistlib.loads(archive.read(entries[PLIST_PATH]))
            if not isinstance(metadata, dict):
                raise ReleasePreparationError(f"{path.name}: Info.plist must contain a dictionary")
            if metadata.get("CFBundleIdentifier") != BUNDLE_IDENTIFIER:
                raise ReleasePreparationError(f"{path.name}: application bundle identifier does not match")
            if metadata.get("CFBundleShortVersionString") != version:
                raise ReleasePreparationError(f"{path.name}: application version does not match v{version}")
            with archive.open(entries[BINARY_PATH]) as binary:
                header = binary.read(32)
            if len(header) != 32:
                raise ReleasePreparationError(f"{path.name}: application has a truncated Mach-O header")
            magic, cpu = struct.unpack_from("<II", header)
            if magic != MACHO_64_MAGIC:
                raise ReleasePreparationError(f"{path.name}: application is not a little-endian 64-bit Mach-O")
            if cpu != expected_cpu:
                raise ReleasePreparationError(f"{path.name}: application CPU does not match the archive architecture")
            bad_entry = archive.testzip()
            if bad_entry is not None:
                raise ReleasePreparationError(f"{path.name}: ZIP integrity check failed for {bad_entry}")
    except (OSError, zipfile.BadZipFile, RuntimeError, plistlib.InvalidFileException, ExpatError, ValueError) as error:
        raise ReleasePreparationError(f"{path.name}: cannot read application archive: {error}") from error


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def prepare_release(tag, artifacts_dir, output_dir):
    match = re.fullmatch(r"v([0-9]+\.[0-9]+\.[0-9]+)", tag)
    if match is None:
        raise ReleasePreparationError("tag must have the form vMAJOR.MINOR.PATCH")
    version = match.group(1)
    artifacts_dir = Path(artifacts_dir)
    output_dir = Path(output_dir)
    if not artifacts_dir.is_dir():
        raise ReleasePreparationError("artifacts directory does not exist")
    expected_names = {f"ClassicLaunchpad-{architecture}.zip" for architecture, _, _ in ARCHITECTURES}
    actual_names = {entry.name for entry in artifacts_dir.iterdir()}
    if actual_names != expected_names:
        missing = sorted(expected_names - actual_names)
        unexpected = sorted(actual_names - expected_names)
        raise ReleasePreparationError(f"expected exactly the Apple Silicon ZIP; missing={missing}, unexpected={unexpected}")

    assets = []
    for architecture, asset_architecture, cpu in ARCHITECTURES:
        source = artifacts_dir / f"ClassicLaunchpad-{architecture}.zip"
        if not source.is_file():
            raise ReleasePreparationError(f"{source.name}: expected an application ZIP file")
        validate_archive(source, version, cpu)
        assets.append((source, f"ClassicLaunchpad-{tag}-{asset_architecture}.zip"))

    if output_dir.exists() and (not output_dir.is_dir() or any(output_dir.iterdir())):
        raise ReleasePreparationError("output directory must be absent or empty")
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    # Stage the entire set before exposing any Release assets at the output path.
    with tempfile.TemporaryDirectory(prefix=".prepare-release-", dir=output_dir.parent) as temporary:
        staged = Path(temporary) / "assets"
        staged.mkdir()
        checksums = []
        for source, filename in assets:
            destination = staged / filename
            shutil.copy2(source, destination)
            checksums.append(f"{sha256_file(destination)}  {filename}\n")
        (staged / "SHA256SUMS.txt").write_text("".join(checksums), encoding="utf-8")
        if output_dir.exists():
            output_dir.rmdir()
        os.replace(staged, output_dir)
    return [output_dir / filename for _, filename in assets] + [output_dir / "SHA256SUMS.txt"]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--artifacts-dir", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    arguments = parser.parse_args(argv)
    try:
        assets = prepare_release(arguments.tag, arguments.artifacts_dir, arguments.output_dir)
    except (ReleasePreparationError, OSError) as error:
        parser.exit(1, f"error: {error}\n")
    for asset in assets:
        print(asset)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
