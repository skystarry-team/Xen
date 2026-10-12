# SPDX-License-Identifier: MIT OR Apache-2.0
"""Build and package Linux compiler architectures through Dune contexts."""
import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from package import ROOT, binary_architecture, package, parse_runner

ARCHITECTURES = ("x86_64", "aarch64")
OCAML_ARCHITECTURES = {"amd64": "x86_64", "arm64": "aarch64"}


@dataclass
class Build:
    architecture: str
    context: str
    prefix: Path | None
    runner: list[str]

    @property
    def binary(self) -> Path:
        return ROOT / "_build" / self.context / "compiler/main.exe"


def configuration(executable: Path) -> dict[str, str]:
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError(f"OCaml executable not found: {executable}")
    result = subprocess.run([str(executable), "-config"], check=True,
                            capture_output=True, text=True, timeout=30)
    return dict(line.split(": ", 1) for line in result.stdout.splitlines() if ": " in line)


def compiler_pair(directory: Path) -> dict[str, str]:
    bytecode = configuration(directory / "ocamlc")
    native = configuration(directory / "ocamlopt")
    for key in ("version", "architecture", "system", "word_size"):
        if not bytecode.get(key) or bytecode.get(key) != native.get(key):
            raise ValueError(f"OCaml compiler configuration mismatch for {key}: {directory}")
    if native.get("native_compiler") != "true" or native["word_size"] != "64":
        raise ValueError(f"a 64-bit native OCaml compiler is required: {directory}")
    return native


def load_toolchains(path: Path) -> dict:
    if not path.exists() and path.resolve() == ROOT / ".package-toolchains.json":
        # Without local configuration, cross prefixes use the documented /opt defaults.
        return {}
    value = json.loads(path.read_text())
    if not isinstance(value, dict) or any(key not in ARCHITECTURES for key in value):
        raise ValueError("toolchains must be an object keyed by x86_64 or aarch64")
    for architecture, entry in value.items():
        if (not isinstance(entry, dict) or set(entry) - {"prefix", "runner"}
                or not isinstance(entry.get("prefix"), str) or not entry["prefix"]
                or any(char in entry["prefix"] for char in "\0\r\n")):
            raise ValueError(f"invalid toolchain configuration for {architecture}: prefix required")
        if not Path(entry["prefix"]).is_absolute():
            raise ValueError(f"toolchain prefix must be absolute: {architecture}")
        parse_runner(json.dumps(entry.get("runner", [])))
    return value


def plan(architectures: list[str], toolchains: dict) -> tuple[Path, list[Build]]:
    if not architectures or len(set(architectures)) != len(architectures):
        raise ValueError("select one or more distinct compiler architectures")
    if any(architecture not in ARCHITECTURES for architecture in architectures):
        raise ValueError("supported compiler architectures: x86_64 aarch64")
    ocamlc = shutil.which("ocamlc")
    ocamlopt = shutil.which("ocamlopt")
    if not ocamlc or not ocamlopt or Path(ocamlc).parent != Path(ocamlopt).parent:
        raise ValueError("matching native ocamlc and ocamlopt must be on PATH")
    native_bin = Path(ocamlc).parent.absolute()
    native = compiler_pair(native_bin)
    host = OCAML_ARCHITECTURES.get(native["architecture"])
    if native["system"] != "linux" or host not in ARCHITECTURES:
        raise ValueError("compiler packaging requires a Linux x86_64 or AArch64 OCaml host")
    builds = []
    for architecture in architectures:
        if architecture == host:
            builds.append(Build(architecture, "default", None, []))
            continue
        entry = toolchains.get(architecture, {})
        prefix = Path(entry.get("prefix", f"/opt/ocaml-{architecture}")).resolve()
        if not (prefix / "bin/ocamlc").is_file() or not (prefix / "bin/ocamlopt").is_file():
            raise ValueError(f"missing {architecture} OCaml cross compiler: {prefix}; "
                             "configure prefix and runner in .package-toolchains.json "
                             "(see scripts/package-toolchains.example.json)")
        cross = compiler_pair(prefix / "bin")
        if cross["system"] != "linux" or OCAML_ARCHITECTURES.get(cross["architecture"]) != architecture:
            raise ValueError(f"cross compiler target mismatch: expected {architecture}-linux, "
                             f"got {cross['architecture']}-{cross['system']}: {prefix}")
        if cross["version"] != native["version"]:
            raise ValueError(f"OCaml version mismatch: native {native['version']}, "
                             f"{architecture} {cross['version']}")
        runner = parse_runner(json.dumps(entry.get("runner", [])))
        if runner and not shutil.which(runner[0]):
            raise ValueError(f"compiler runner not found: {runner[0]}")
        builds.append(Build(architecture, f"package_{architecture}", prefix, runner))
    return native_bin, builds


def workspace(native_bin: Path, builds: list[Build]) -> str:
    quote = lambda value: json.dumps(str(value), ensure_ascii=False)
    contexts = [f'(context (default (name default) (paths (PATH ({quote(native_bin)} :standard)))))']
    for build in builds:
        if build.prefix is not None:
            contexts.append(
                f'(context (default (name {build.context}) (host default) '
                f'(paths (PATH ({quote(build.prefix / "bin")} :standard))) '
                f'(env (_ (env-vars (OPAM_SWITCH_PREFIX {quote(build.prefix)}))))))')
    return "(lang dune 3.18)\n" + "\n".join(contexts) + "\n"


def build_packages(architectures: list[str], toolchains: Path, version: str,
                   output_dir: Path, *, build_only: bool = False) -> None:
    if not re.fullmatch(r"[A-Za-z0-9._+-]+", version):
        raise ValueError("invalid package version")
    native_bin, builds = plan(architectures, load_toolchains(toolchains))
    dune = shutil.which("dune")
    if not dune:
        raise ValueError("Dune must be on PATH")
    with tempfile.TemporaryDirectory(prefix="xen-package-build-") as directory:
        workspace_path = Path(directory) / "dune-workspace"
        workspace_path.write_text(workspace(native_bin, builds))
        subprocess.run([dune, "build", f"--workspace={workspace_path}",
                        *(str(build.binary.relative_to(ROOT)) for build in builds)],
                       cwd=ROOT, env=dict(os.environ, XEN_BUILD_VERSION=version), check=True)
    for build in builds:
        if binary_architecture(build.binary) != build.architecture:
            raise ValueError(f"built compiler architecture mismatch: {build.binary}")
    if build_only:
        return
    output_dir.mkdir(parents=True, exist_ok=True)
    # Complete every archive before replacing any existing release artifact.
    with tempfile.TemporaryDirectory(prefix=".xen-package-", dir=output_dir) as directory:
        staging = Path(directory)
        for build in builds:
            package(None, None, binary=build.binary, version=version, platform="linux",
                    architecture=build.architecture, runner=build.runner, output_dir=staging)
        for build in builds:
            name = f"xen-{version}-linux-{build.architecture}.tar.gz"
            (staging / name).replace(output_dir / name)
            print(f"Published {output_dir / name}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--architectures", nargs="+", choices=(*ARCHITECTURES, "arm64"), default=list(ARCHITECTURES))
    parser.add_argument("--toolchains", type=Path, default=ROOT / ".package-toolchains.json")
    parser.add_argument("--platform", default="linux")
    parser.add_argument("--version", default=(ROOT / "VERSION").read_text().strip())
    parser.add_argument("--output-dir", type=Path, default=ROOT / "dist")
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--name")
    parser.add_argument("--output")
    args = parser.parse_args()
    try:
        if args.platform != "linux":
            raise ValueError("unsupported compiler package platform; supported: linux")
        if args.name is not None or args.output is not None:
            raise ValueError("PACKAGE_NAME and PACKAGE require make package-one")
        build_packages(["aarch64" if arch == "arm64" else arch for arch in args.architectures],
                       args.toolchains, args.version, args.output_dir, build_only=args.build_only)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        detail = error.stderr if isinstance(error, subprocess.CalledProcessError) else str(error)
        parser.exit(1, f"package-build: {detail or str(error)}\n")


if __name__ == "__main__":
    main()
