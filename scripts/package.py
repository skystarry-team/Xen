# SPDX-License-Identifier: MIT OR Apache-2.0
"""Create binary or clean source demo archives with documentation and license notices."""
import argparse
import io
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FILES = ("README.md", "CONTRIBUTING.md", "LICENSE", "LICENSE-MIT",
         "LICENSE-APACHE", "NOTICE", "THIRD_PARTY.md", "VERSION")
DIRECTORIES = ("docs", "examples", "stdlib", "assets", "licenses")
SOURCE_FILES = ("Makefile", "dune-project", ".gitignore")
SOURCE_DIRECTORIES = ("compiler", "tests", "benchmarks", "scripts")
EXCLUDED = {"__pycache__", "found_bugs", "dist"}


def package(name: str, output: Path, *, source: bool = False, version: str | None = None) -> None:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", name):
        raise ValueError("package name must contain only letters, digits, '.', '_', '+' and '-'")
    version = version if version is not None else (ROOT / "VERSION").read_text().strip()
    if not re.fullmatch(r"[A-Za-z0-9._+-]+", version):
        raise ValueError("invalid package version")
    binary = ROOT / "compiler/dist/xen"
    if not source and (not binary.is_file() or not os.access(binary, os.X_OK)):
        raise FileNotFoundError("compiler executable not found; run make build first")
    if not source:
        embedded = subprocess.run([str(binary), "version"], check=True, capture_output=True, text=True).stdout.strip()
        if embedded != f"xen {version}":
            raise ValueError(f"compiler version mismatch ({embedded}); run make build VERSION={version}")
    entries = [] if source else [(binary, "bin/xen")]
    entries += [(ROOT / file, file) for file in FILES]
    if source:
        entries += [(ROOT / file, file) for file in SOURCE_FILES]
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
    parser.add_argument("--name", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", help="version embedded in the exported VERSION file")
    parser.add_argument("--source", action="store_true", help="export source without Git history or local artifacts")
    args = parser.parse_args()
    package(args.name, args.output, source=args.source, version=args.version)
