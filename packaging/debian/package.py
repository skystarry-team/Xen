# SPDX-License-Identifier: MIT OR Apache-2.0
"""Build rootless Debian binary packages with ELF-derived dependencies."""
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from packaging.common import ROOT, NOTICE_FILES, public_files, validate_binary, validate_version

ARCHITECTURES = {"x86_64": "amd64", "aarch64": "arm64"}
PACKAGE = "xen-lang"


def debian_version(version: str) -> str:
    validate_version(version)
    if not version[0].isdigit():
        raise ValueError("Debian package versions must start with a digit")
    # Xen's legacy '_' and SemVer '-' suffixes denote prereleases.
    # Keep the original version in the executable and installed VERSION file.
    return version.replace("_", "~").replace("-", "~") + "-1"


def filename(version: str, architecture: str) -> str:
    return f"{PACKAGE}_{debian_version(version)}_{ARCHITECTURES[architecture]}.deb"


def dependencies(binary: Path, architecture: str, directory: Path) -> str:
    debian = directory / "debian"
    debian.mkdir()
    (debian / "control").write_text(
        f"Source: {PACKAGE}\n\nPackage: {PACKAGE}\nArchitecture: any\n"
        "Description: Xen programming language compiler\n")
    result = subprocess.run(["dpkg-shlibdeps", "-O", f"-e{binary}"], cwd=directory,
                            env=dict(os.environ, DEB_HOST_ARCH=architecture), check=True,
                            capture_output=True, text=True, timeout=60)
    for line in result.stdout.splitlines():
        if line.startswith("shlibs:Depends="):
            return line.removeprefix("shlibs:Depends=")
    raise ValueError("dpkg-shlibdeps did not report dependencies")


def package(name: str | None, output: Path | None, *, version: str | None = None,
            binary: Path | None = None, platform: str = "linux",
            architecture: str | None = None, runner: list[str] | None = None,
            output_dir: Path | None = None) -> Path:
    if platform != "linux":
        raise ValueError("unsupported Debian package platform; deb supports linux only")
    version = version if version is not None else (ROOT / "VERSION").read_text().strip()
    deb_version = debian_version(version)
    binary = (binary if binary is not None else ROOT / "compiler/dist/xen").resolve()
    architecture = validate_binary(binary, version, platform, architecture, runner)
    if not shutil.which("dpkg-deb") or not shutil.which("dpkg-shlibdeps"):
        raise ValueError("Debian packaging requires dpkg-deb and dpkg-shlibdeps (install dpkg-dev)")
    if name is not None and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+~-]*", name):
        raise ValueError("invalid Debian output name")
    if output is None:
        output = (output_dir if output_dir is not None else ROOT / "dist") / (
            f"{name}.deb" if name else filename(version, architecture))
    output = output.absolute()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".xen-deb-", dir=output.parent) as temporary:
        work = Path(temporary)
        depends = dependencies(binary, ARCHITECTURES[architecture], work)
        stage = work / "root"
        doc = stage / "usr/share/doc" / PACKAGE
        doc.mkdir(parents=True)
        entries = [(binary, "usr/bin/xen")]
        entries += [(path, "usr/lib/xen/" + relative.removeprefix("stdlib/"))
                    for path, relative in public_files("stdlib", stdlib_only=True)]
        for directory in ("examples", "licenses"):
            entries += [(path, f"usr/share/doc/{PACKAGE}/{relative}")
                        for path, relative in public_files(directory)]
        entries += [(ROOT / file, f"usr/share/doc/{PACKAGE}/{file}") for file in NOTICE_FILES]
        entries += [(ROOT / "packaging/debian/README.md", f"usr/share/doc/{PACKAGE}/README.md"),
                    (ROOT / "LICENSE", f"usr/share/doc/{PACKAGE}/copyright")]
        for source, relative in entries:
            target = stage / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if relative.endswith("/VERSION"):
                target.write_text(version + "\n")
            else:
                shutil.copyfile(source, target)
            target.chmod(0o755 if relative == "usr/bin/xen" else 0o644)
        installed = sorted(path for path in stage.rglob("*") if path.is_file())
        size = (sum(path.stat().st_size for path in installed) + 1023) // 1024
        control = stage / "DEBIAN"
        control.mkdir()
        template = (ROOT / "packaging/debian/control.in").read_text()
        (control / "control").write_text(template.format(
            version=deb_version, architecture=ARCHITECTURES[architecture],
            installed_size=size, depends=f"Depends: {depends}\n" if depends else ""))
        (control / "md5sums").write_text("".join(
            f"{hashlib.md5(path.read_bytes()).hexdigest()}  {path.relative_to(stage).as_posix()}\n"
            for path in installed))
        for path in stage.rglob("*"):
            if path.is_dir():
                path.chmod(0o755)
        for path in control.iterdir():
            path.chmod(0o644)
        stage.chmod(0o755)
        artifact = work / "package.deb"
        subprocess.run(["dpkg-deb", "--root-owner-group", "-Zxz", "--build", str(stage), str(artifact)],
                       check=True, capture_output=True, text=True, timeout=120)
        artifact.replace(output)
    print(f"Created {output}")
    return output
