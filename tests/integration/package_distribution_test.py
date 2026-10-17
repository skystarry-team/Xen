# SPDX-License-Identifier: MIT OR Apache-2.0
"""Real Debian payload, relocated execution and complete release asset checks."""
import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
from packaging import build
from packaging.common import binary_architecture
from packaging.debian import package as debian
from packaging.github.release import prepare


class DistributionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="xen-distribution-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def test_versions_sort_prereleases_before_stable(self):
        dpkg = shutil.which("dpkg")
        for original, expected in (("0.1.0_1-demo", "0.1.0~1~demo-1"),
                                   ("1.2.3-rc.1", "1.2.3~rc.1-1"),
                                   ("1.2.3", "1.2.3-1")):
            actual = debian.debian_version(original)
            self.assertEqual(actual, expected)
            if dpkg:
                subprocess.run([dpkg, "--validate-version", actual], check=True)
        if dpkg:
            for prerelease in ("0.1.0_1-demo", "0.1.0_2-demo"):
                subprocess.run([dpkg, "--compare-versions", debian.debian_version(prerelease),
                                "lt", debian.debian_version("0.1.0")], check=True)
            subprocess.run([dpkg, "--compare-versions", debian.debian_version("0.1.0_1-demo"),
                            "lt", debian.debian_version("0.1.0_2-demo")], check=True)
        self.assertTrue(debian.filename("1.2.3", "x86_64").endswith("_amd64.deb"))
        self.assertTrue(debian.filename("1.2.3", "aarch64").endswith("_arm64.deb"))
        for invalid in ("demo", "../1", "", "1\nDepends: bad"):
            with self.assertRaises(ValueError):
                debian.debian_version(invalid)

    @unittest.skipUnless(shutil.which("dpkg-shlibdeps") and shutil.which("dpkg-deb"), "dpkg-dev required")
    def test_real_debian_package_and_relocated_execution(self):
        binary = REPO / "compiler/dist/xen"
        version = subprocess.check_output([str(binary), "version"], text=True).strip().removeprefix("xen ")
        architecture = binary_architecture(binary)
        output = debian.package(None, None, binary=binary, version=version, output_dir=self.root)
        fields = subprocess.check_output(["dpkg-deb", "-f", str(output),
                                          "Package", "Version", "Architecture", "Depends"], text=True)
        self.assertIn("Package: xen-lang\n", fields)
        self.assertIn(f"Version: {debian.debian_version(version)}\n", fields)
        self.assertIn(f"Architecture: {debian.ARCHITECTURES[architecture]}\n", fields)
        self.assertRegex(fields, r"Depends: .*libc6 \(>= [0-9.]+\)")
        payload = subprocess.check_output(["dpkg-deb", "--fsys-tarfile", str(output)])
        with tarfile.open(fileobj=io.BytesIO(payload)) as archive:
            names = {entry.name.removeprefix("./") for entry in archive if entry.isfile()}
            expected = {"usr/lib/xen/" + path.relative_to(REPO / "stdlib").as_posix()
                        for path in (REPO / "stdlib").rglob("*.xen") if not path.is_symlink()}
            self.assertEqual({name for name in names if name.startswith("usr/lib/xen/")}, expected)
            for relative in ("usr/bin/xen", "usr/share/doc/xen-lang/copyright",
                             "usr/share/doc/xen-lang/licenses/OCaml.txt",
                             "usr/share/doc/xen-lang/LICENSE-APACHE",
                             "usr/share/doc/xen-lang/examples/demo.xen"):
                self.assertIn(relative, names)
            for entry in archive:
                self.assertEqual((entry.uid, entry.gid), (0, 0))
                self.assertEqual(entry.mode & 0o777, 0o755 if entry.isdir() or entry.name == "./usr/bin/xen" else 0o644)
        extracted = self.root / "relocated"
        subprocess.run(["dpkg-deb", "-x", str(output), str(extracted)], check=True)
        installed = extracted / "usr/bin/xen"
        self.assertEqual((extracted / "usr/share/doc/xen-lang/VERSION").read_text(), version + "\n")
        environment = dict(os.environ, PATH="/no-external-tools")
        environment.pop("XEN_STDLIB_ROOT", None)
        source = self.root / "hello.xen"
        source.write_text('use std.string;fn main(){assert(std.string.contains("abc","b"));println("deb-ok");}')
        def invoke(*arguments):
            return subprocess.check_output([str(installed), *map(str, arguments)],
                                           cwd=self.root, env=environment, text=True)
        self.assertEqual(invoke("version"), f"xen {version}\n")
        invoke("check", source)
        self.assertEqual(invoke("run", source), "deb-ok\n")
        executable = self.root / "hello"
        invoke("build", source, "-o", executable)
        self.assertEqual(subprocess.check_output([str(executable)], text=True), "deb-ok\n")
        for target in ("x86_64", "aarch64"):
            invoke("build", source, f"--target={target}-linux", "-o", executable)
            self.assertEqual(binary_architecture(executable), target)
        self.assertIn("1 passed; 0 failed", invoke("test", "std.fs", "--filter", "null"))

    def test_debian_failure_preserves_all_existing_formats(self):
        binary = REPO / "_build/default/compiler/main.exe"
        builds = [build.Build("x86_64", "default", None, [])]
        toolchains = self.root / "toolchains.json"
        toolchains.write_text("{}")
        output = self.root / "dist"
        output.mkdir()
        names = ("xen-1.2.3-linux-x86_64.tar.gz", debian.filename("1.2.3", "x86_64"))
        for name in names:
            (output / name).write_bytes(b"previous release")
        def archive(*args, **kwargs):
            (kwargs["output_dir"] / names[0]).write_bytes(b"new archive")
        with patch.object(build, "plan", return_value=(binary.parent, builds)), \
                patch.object(build.shutil, "which", return_value="/dune"), \
                patch.object(build.subprocess, "run"), \
                patch.object(build, "binary_architecture", return_value="x86_64"), \
                patch.object(build, "package", side_effect=archive), \
                patch.object(build, "deb_package", side_effect=ValueError("missing target libraries")), \
                self.assertRaisesRegex(ValueError, "missing target libraries"):
            build.build_packages(["x86_64"], toolchains, "1.2.3", output, formats=("tar.gz", "deb"))
        self.assertEqual(set(path.name for path in output.iterdir()), set(names))
        for name in names:
            self.assertEqual((output / name).read_bytes(), b"previous release")

    def test_release_requires_exact_assets_and_matching_tag(self):
        version = "0.1.0_1-demo"
        names = {f"xen-{version}-source.tar.gz", f"xen-{version}-windows-x86_64.zip",
                 f"xen-{version}-macos-aarch64.tar.gz"}
        for architecture in ("x86_64", "aarch64"):
            names.add(f"xen-{version}-linux-{architecture}.tar.gz")
            names.add(debian.filename(version, architecture))
        for name in names:
            (self.root / name).write_bytes(name.encode())
        with self.assertRaisesRegex(ValueError, "tag must equal"):
            prepare(self.root, version, "vwrong")
        artifacts = prepare(self.root, version, f"v{version}")
        self.assertEqual(len(artifacts), 8)
        manifest = (self.root / "SHA256SUMS").read_text()
        for name in names:
            self.assertIn(f"{hashlib.sha256(name.encode()).hexdigest()}  {name}\n", manifest)
        if shutil.which("sha256sum"):
            command = ["sha256sum", "--check", "SHA256SUMS"]
            subprocess.run(command, cwd=self.root, check=True, capture_output=True)
            tampered = next(self.root.glob("*.deb"))
            original = tampered.read_bytes()
            tampered.write_bytes(original + b"corrupt")
            result = subprocess.run(command, cwd=self.root, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            tampered.write_bytes(original)
        stale = self.root / "old.deb"
        stale.write_bytes(b"stale")
        with self.assertRaisesRegex(ValueError, "unexpected=.*old.deb"):
            prepare(self.root, version)
        stale.unlink()
        windows = self.root / f"xen-{version}-windows-x86_64.zip"
        windows.unlink()
        with self.assertRaisesRegex(ValueError, "missing=.*windows-x86_64.zip"):
            prepare(self.root, version)
        windows.write_bytes(windows.name.encode())
        next(self.root.glob("*.deb")).unlink()
        with self.assertRaisesRegex(ValueError, "missing="):
            prepare(self.root, version)


if __name__ == "__main__":
    unittest.main(verbosity=2)
