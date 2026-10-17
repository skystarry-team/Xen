# SPDX-License-Identifier: MIT OR Apache-2.0
"""Package an existing compiler, or export clean source."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

from packaging.archive.package import package as archive_package
from packaging.common import ROOT, binary_architecture, parse_runner
from packaging.debian.package import package as deb_package
from packaging.windows.package import package as windows_package
from packaging.windows.pe import inspect as inspect_pe


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "dist")
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--platform", default="linux")
    parser.add_argument("--architecture", choices=("x86_64", "aarch64"))
    parser.add_argument("--runner", default=os.getenv("PACKAGE_RUNNER", "[]"))
    parser.add_argument("--binary-architecture", action="store_true")
    parser.add_argument("--version", default=(ROOT / "VERSION").read_text().strip())
    parser.add_argument("--source", action="store_true")
    parser.add_argument("--formats", nargs="+", choices=("tar.gz", "deb", "zip"))
    args = parser.parse_args()
    try:
        args.binary = args.binary or ROOT / ("compiler/dist/xen.exe" if args.platform == "windows" else "compiler/dist/xen")
        args.formats = args.formats or (["zip"] if args.platform == "windows" and not args.source else ["tar.gz"])
        if args.binary_architecture:
            if args.platform == "windows":
                inspect_pe(args.binary)
                print("x86_64")
            elif args.platform == "linux":
                print(binary_architecture(args.binary))
            else:
                raise ValueError("unsupported compiler package platform")
            return
        if len(set(args.formats)) != len(args.formats):
            raise ValueError("select distinct package formats")
        if args.source:
            if args.formats != ["tar.gz"]:
                raise ValueError("source exports support tar.gz only")
            archive_package(args.name, args.output, source=True, version=args.version, output_dir=args.output_dir)
            return
        allowed = {"linux": {"tar.gz", "deb"}, "windows": {"zip"}}.get(args.platform)
        if allowed is None or set(args.formats) - allowed:
            raise ValueError("supported platform/formats: linux with tar.gz/deb; windows with zip")
        if len(args.formats) > 1 and (args.output or args.name):
            raise ValueError("custom output/name requires a single package format")
        runner = parse_runner(args.runner)
        destination = args.output.parent if args.output else args.output_dir
        destination.mkdir(parents=True, exist_ok=True)
        # Finish every format before replacing existing artifacts, including single mode.
        with tempfile.TemporaryDirectory(prefix=".xen-package-", dir=destination) as directory:
            for format in args.formats:
                writer = {"tar.gz": archive_package, "deb": deb_package, "zip": windows_package}[format]
                writer(args.name, None, binary=args.binary, platform=args.platform,
                       architecture=args.architecture, runner=runner, version=args.version,
                       output_dir=Path(directory))
            for artifact in sorted(Path(directory).iterdir()):
                artifact.replace(args.output if args.output else destination / artifact.name)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        detail = error.stderr if isinstance(error, subprocess.CalledProcessError) else str(error)
        parser.exit(1, f"package: {detail or str(error)}\n")


if __name__ == "__main__":
    main()
