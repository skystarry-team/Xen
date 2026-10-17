# SPDX-License-Identifier: MIT OR Apache-2.0
"""Shared distribution payload and compiler validation."""
import json
import os
from pathlib import Path
import re
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
NOTICE_FILES = ("LICENSE", "LICENSE-MIT", "LICENSE-APACHE", "NOTICE", "THIRD_PARTY.md", "VERSION")
EXCLUDED = {"__pycache__", "found_bugs", "dist"}


def binary_architecture(binary: Path) -> str:
    with binary.open("rb") as file:
        header = file.read(64)
    if len(header) < 64 or header[:7] != b"\x7fELF\x02\x01\x01":
        raise ValueError("compiler must be a little-endian ELF64 executable")
    architecture = {62: "x86_64", 183: "aarch64"}.get(struct.unpack_from("<H", header, 18)[0])
    if architecture is None:
        raise ValueError("unsupported compiler ELF architecture")
    return architecture


def parse_runner(value: str) -> list[str]:
    try:
        runner = json.loads(value)
    except json.JSONDecodeError as error:
        raise ValueError("runner must be a JSON array of strings") from error
    if not isinstance(runner, list) or any(not isinstance(arg, str) or not arg or "\0" in arg for arg in runner):
        raise ValueError("runner must be a JSON array of nonempty strings")
    return runner


def validate_version(version: str) -> None:
    if not re.fullmatch(r"[A-Za-z0-9._+-]+", version):
        raise ValueError("invalid package version")


def validate_binary(binary: Path, version: str, platform: str,
                    architecture: str | None, runner: list[str] | None) -> str:
    validate_version(version)
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise FileNotFoundError("compiler executable not found; run make build first")
    if platform == "windows":
        from packaging.windows.pe import inspect
        inspect(binary)
        actual = "x86_64"
    elif platform == "linux":
        actual = binary_architecture(binary)
    else:
        raise ValueError("unsupported compiler package platform; supported: linux windows")
    if architecture is not None and architecture != actual:
        raise ValueError(f"compiler architecture mismatch: requested {architecture}, image is {actual}")
    embedded = subprocess.run([*(runner or []), str(binary), "version"], check=True,
                              capture_output=True, text=True, timeout=60).stdout.strip()
    if embedded != f"xen {version}":
        raise ValueError(f"compiler version mismatch ({embedded}); rebuild the selected compiler for version {version}")
    return actual


def public_files(directory: str, *, stdlib_only: bool = False):
    for path in sorted((ROOT / directory).rglob("*")):
        if (path.is_file() and not path.is_symlink()
                and (not stdlib_only or path.suffix == ".xen")
                and not any(part.startswith(".") or part in EXCLUDED
                            for part in path.relative_to(ROOT / directory).parts)):
            yield path, path.relative_to(ROOT).as_posix()
