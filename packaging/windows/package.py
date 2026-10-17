# SPDX-License-Identifier: MIT OR Apache-2.0
"""Create a portable Windows x86_64 compiler ZIP from a native executable."""
from pathlib import Path
import re
import tempfile
import zipfile

from packaging.common import ROOT, NOTICE_FILES, public_files, validate_binary


def package(name: str | None, output: Path | None, *, binary: Path,
            platform: str = "windows", architecture: str | None = None,
            runner: list[str] | None = None, version: str,
            output_dir: Path | None = None) -> Path:
    if platform != "windows":
        raise ValueError("ZIP packages support Windows only")
    binary = binary.resolve()
    actual = validate_binary(binary, version, platform, architecture, runner)
    name = name if name is not None else f"xen-{version}-windows-{actual}"
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", name):
        raise ValueError("invalid package name")
    output = output if output is not None else (output_dir or ROOT / "dist") / f"{name}.zip"
    entries = [(binary, "bin/xen.exe"),
               (ROOT / "docs/compiler-build/distribution-readme.md", "README.md")]
    entries += [(ROOT / file, file) for file in NOTICE_FILES]
    for directory in ("stdlib", "examples", "licenses"):
        entries += list(public_files(directory, stdlib_only=directory == "stdlib"))
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=output.parent, suffix=".zip", delete=False) as file:
        temporary = Path(file.name)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path, relative in entries:
                data = (version+"\n").encode() if relative == "VERSION" else path.read_bytes()
                archive.writestr(f"{name}/{relative}", data)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    print(f"Created {output}")
    return output
