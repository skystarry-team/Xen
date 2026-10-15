# SPDX-License-Identifier: MIT OR Apache-2.0
"""Validate a complete release asset set and write its SHA-256 manifest."""
import argparse
import hashlib
from pathlib import Path

from packaging.common import ROOT, validate_version
from packaging.debian.package import filename


def checksum(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def prepare(directory: Path, version: str, tag: str | None = None) -> list[Path]:
    validate_version(version)
    if tag is not None and tag != f"v{version}":
        raise ValueError(f"release tag must equal v{version}, got {tag}")
    names = {f"xen-{version}-source.tar.gz"}
    for architecture in ("x86_64", "aarch64"):
        names.add(f"xen-{version}-linux-{architecture}.tar.gz")
        names.add(filename(version, architecture))
    actual = {path.name for path in directory.iterdir()}
    if actual - {"SHA256SUMS"} != names:
        raise ValueError(f"incorrect release assets; missing={sorted(names - actual)}, "
                         f"unexpected={sorted(actual - names - {'SHA256SUMS'})}")
    artifacts = [directory / name for name in sorted(names)]
    for path in artifacts:
        if not path.is_file() or path.is_symlink() or not path.stat().st_size:
            raise ValueError(f"invalid release asset: {path}")
    manifest = directory / "SHA256SUMS"
    manifest.write_text("".join(
        f"{checksum(path)}  {path.name}\n"
        for path in artifacts))
    return [*artifacts, manifest]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=ROOT / "dist")
    parser.add_argument("--version", default=(ROOT / "VERSION").read_text().strip())
    parser.add_argument("--tag")
    args = parser.parse_args()
    try:
        for path in prepare(args.directory, args.version, args.tag):
            print(path)
    except (OSError, ValueError) as error:
        parser.exit(1, f"release: {error}\n")


if __name__ == "__main__":
    main()
