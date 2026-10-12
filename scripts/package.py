# SPDX-License-Identifier: MIT OR Apache-2.0
"""Create binary or clean source demo archives with documentation and license notices."""
import argparse
import io
import json
import os
from pathlib import Path
import re
import subprocess
import struct
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FILES = ("README.md", "CONTRIBUTING.md", "LICENSE", "LICENSE-MIT",
         "LICENSE-APACHE", "NOTICE", "THIRD_PARTY.md", "VERSION")
DIRECTORIES = ("docs", "examples", "stdlib", "assets", "licenses")
COMPILER_DOCS = ("compiler/README.md", "compiler/cpu/arm64/README.md", "compiler/platform/README.md")
SOURCE_FILES = ("Makefile", "dune-project", ".gitignore")
SOURCE_DIRECTORIES = ("compiler", "tests", "benchmarks", "scripts")
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


def package(name: str | None, output: Path | None, *, source: bool = False,
            version: str | None = None, binary: Path | None = None,
            platform: str = "linux", architecture: str | None = None,
            runner: list[str] | None = None, output_dir: Path | None = None) -> None:
    version = version if version is not None else (ROOT / "VERSION").read_text().strip()
    if not re.fullmatch(r"[A-Za-z0-9._+-]+", version):
        raise ValueError("invalid package version")
    binary = (binary if binary is not None else ROOT / "compiler/dist/xen").resolve()
    if not source and (not binary.is_file() or not os.access(binary, os.X_OK)):
        raise FileNotFoundError("compiler executable not found; run make build first")
    if not source:
        # Linux is the supported compiler platform. ELF e_machine identifies
        # architecture, not OS: never infer an OS from the packaging host.
        if platform != "linux":
            raise ValueError("unsupported compiler package platform; supported: linux")
        actual_architecture = binary_architecture(binary)
        if architecture is not None and architecture != actual_architecture:
            raise ValueError(f"compiler architecture mismatch: requested {architecture}, ELF is {actual_architecture}")
        embedded = subprocess.run([*(runner or []), str(binary), "version"], check=True,
                                  capture_output=True, text=True, timeout=60).stdout.strip()
        if embedded != f"xen {version}":
            raise ValueError(f"compiler version mismatch ({embedded}); rebuild the selected compiler for version {version}")
    if name is None:
        name = f"xen-{version}-source" if source else f"xen-{version}-{platform}-{actual_architecture}"
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", name):
        raise ValueError("package name must contain only letters, digits, '.', '_', '+' and '-'")
    if output is None:
        output = (output_dir if output_dir is not None else ROOT / "dist") / f"{name}.tar.gz"
    entries = [] if source else [(binary, "bin/xen")]
    entries += [(ROOT / file, file) for file in FILES]
    if source:
        entries += [(ROOT / file, file) for file in SOURCE_FILES]
    else:
        entries += [(ROOT / file, file) for file in COMPILER_DOCS]
    directories = DIRECTORIES + (SOURCE_DIRECTORIES if source else ())
    for directory in directories:
        entries += [(path, path.relative_to(ROOT).as_posix())
                    for path in sorted((ROOT / directory).rglob("*"))
                    if path.is_file() and not path.is_symlink()
                    and not any(part.startswith(".") or part in EXCLUDED
                                for part in path.relative_to(ROOT).parts)]
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=output.parent, suffix=".tar.gz", delete=False) as file:
        temporary = Path(file.name)
    try:
        with tarfile.open(temporary, "w:gz") as archive:
            for path, relative in entries:
                arcname = f"{name}/{relative}"
                if relative == "VERSION":
                    data = (version + "\n").encode()
                    info = archive.gettarinfo(path, arcname=arcname)
                    info.size = len(data)
                    archive.addfile(info, io.BytesIO(data))
                else:
                    archive.add(path, arcname=arcname, recursive=False)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    print(f"Created {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--output-dir", type=Path, help="archive directory (default: dist)")
    parser.add_argument("--binary", type=Path, default=ROOT / "compiler/dist/xen", help="compiler executable to bundle")
    parser.add_argument("--platform", default="linux", help="compiler platform (currently linux only)")
    parser.add_argument("--architecture", choices=("x86_64", "aarch64"), help="require this compiler ELF architecture")
    parser.add_argument("--runner", default=os.getenv("PACKAGE_RUNNER", "[]"), help="JSON argument array for compiler execution (default: PACKAGE_RUNNER or [])")
    parser.add_argument("--binary-architecture", action="store_true", help="print the built compiler's ELF architecture")
    parser.add_argument("--version", help="version embedded in the exported VERSION file")
    parser.add_argument("--source", action="store_true", help="export source without Git history or local artifacts")
    args = parser.parse_args()
    try:
        if args.binary_architecture:
            print(binary_architecture(args.binary))
        else:
            package(args.name, args.output, source=args.source, version=args.version,
                    binary=args.binary, platform=args.platform, architecture=args.architecture,
                    runner=[] if args.source else parse_runner(args.runner), output_dir=args.output_dir)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        detail = error.stderr if isinstance(error, subprocess.CalledProcessError) else str(error)
        parser.exit(1, f"package: {detail or str(error)}\n")
