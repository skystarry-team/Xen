# SPDX-License-Identifier: MIT OR Apache-2.0
"""Create binary or clean source tar.gz archives."""
import io
from pathlib import Path
import re
import tarfile
import tempfile

from packaging.common import (ROOT, NOTICE_FILES, binary_architecture, parse_runner,
                              public_files, validate_binary, validate_version)

FILES = ("README.md", "CONTRIBUTING.md", *NOTICE_FILES)
DIRECTORIES = ("docs", "examples", "stdlib", "assets", "licenses")
BINARY_DIRECTORIES = ("stdlib", "examples", "licenses")
SOURCE_FILES = ("Makefile", "dune-project", ".gitignore")
SOURCE_DIRECTORIES = ("compiler", "tests", "benchmarks", "scripts", "packaging", ".github")


def package(name: str | None, output: Path | None, *, source: bool = False,
            version: str | None = None, binary: Path | None = None,
            platform: str = "linux", architecture: str | None = None,
            runner: list[str] | None = None, output_dir: Path | None = None) -> Path:
    version = version if version is not None else (ROOT / "VERSION").read_text().strip()
    validate_version(version)
    binary = (binary if binary is not None else ROOT / "compiler/dist/xen").resolve()
    if not source:
        actual_architecture = validate_binary(binary, version, platform, architecture, runner)
    if name is None:
        name = f"xen-{version}-source" if source else f"xen-{version}-{platform}-{actual_architecture}"
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", name):
        raise ValueError("package name must contain only letters, digits, '.', '_', '+' and '-'")
    if output is None:
        output = (output_dir if output_dir is not None else ROOT / "dist") / f"{name}.tar.gz"
    if source:
        entries = [(ROOT / file, file) for file in FILES + SOURCE_FILES]
        directories = DIRECTORIES + SOURCE_DIRECTORIES
    else:
        entries = [(binary, "bin/xen"),
                   (ROOT / "docs/compiler-build/distribution-readme.md", "README.md")]
        entries += [(ROOT / file, file) for file in NOTICE_FILES]
        directories = BINARY_DIRECTORIES
    for directory in directories:
        entries += list(public_files(directory, stdlib_only=not source and directory == "stdlib"))
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
    return output
