# SPDX-License-Identifier: MIT OR Apache-2.0
"""Portable ZIP payload/dependency checks, plus native installed execution."""
import os
from pathlib import Path
import platform
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
from packaging.common import validate_binary
from packaging.archive.package import package as tar_package
from packaging.debian.package import package as deb_package
from packaging.windows.package import package
from packaging.windows.pe import inspect
from packaging.windows.smoke import verify


def pe_image(dll="KERNEL32.dll", *, directory_size=128):
    data = bytearray(0x600)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3c, 0x80)
    data[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<HHIIIHH", data, 0x84, 0x8664, 1, 0, 0, 0, 240, 0x22)
    struct.pack_into("<H", data, 0x98, 0x20b)
    struct.pack_into("<I", data, 0x98+108, 16)
    struct.pack_into("<II", data, 0x98+120, 0x1000, directory_size)
    struct.pack_into("<8sIIIIIIHHI", data, 0x98+240,
                     b".idata", 0x400, 0x1000, 0x400, 0x200, 0, 0, 0, 0, 0x40000040)
    struct.pack_into("<5I", data, 0x200, 0x1100, 0, 0, 0x1040, 0x1120)
    encoded = dll.encode()+b"\0"
    data[0x240:0x240+len(encoded)] = encoded
    return data


class WindowsPackageTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="xen-zip-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.binary = self.root / "xen.exe"
        self.binary.write_bytes(pe_image())
        self.binary.chmod(0o755)

    def test_pe_import_extent_and_dependency_policy(self):
        # The directory may include names/thunks after the null descriptor.
        self.assertEqual(inspect(self.binary), {"kernel32.dll"})
        for dll in ("cygwin1.dll", "libwinpthread-1.dll", "libgcc_s_seh-1.dll", "evil/kernel32.dll"):
            self.binary.write_bytes(pe_image(dll))
            with self.subTest(dll=dll), self.assertRaisesRegex(ValueError, "unapproved DLL"):
                inspect(self.binary)
        data = pe_image()
        struct.pack_into("<II", data, 0x98+112+13*8, 0x1000, 32)
        self.binary.write_bytes(data)
        with self.assertRaisesRegex(ValueError, "delay imports"):
            inspect(self.binary)

    def test_invalid_images_reject_before_execution(self):
        cases = [b"", b"\x7fELF"+bytes(100), pe_image()[:100], pe_image(directory_size=20)]
        for offset, layout, value in ((0x84, "<H", 0xaa64), (0x98, "<H", 0x10b),
                                      (0x96, "<H", 0x2022), (0x98+108, "<I", 17),
                                      (0x98+120, "<I", 0x9999)):
            data = pe_image()
            struct.pack_into(layout, data, offset, value)
            cases.append(data)
        for data in cases:
            self.binary.write_bytes(data)
            with self.subTest(length=len(data)), patch("packaging.common.subprocess.run") as run:
                with self.assertRaises(ValueError):
                    validate_binary(self.binary, "1.2.3", "windows", "x86_64", [])
                run.assert_not_called()

    def test_payload_and_version_override(self):
        with patch("packaging.common.subprocess.run", return_value=subprocess.CompletedProcess([], 0, "xen 1.2.3\n")):
            output = package(None, None, binary=self.binary, version="1.2.3", output_dir=self.root)
        self.assertEqual(output.name, "xen-1.2.3-windows-x86_64.zip")
        prefix = output.stem+"/"
        with zipfile.ZipFile(output) as archive:
            names = archive.namelist()
            self.assertEqual(len(names), len(set(names)))
            self.assertEqual(archive.read(prefix+"bin/xen.exe"), self.binary.read_bytes())
            self.assertEqual(archive.read(prefix+"VERSION"), b"1.2.3\n")
            self.assertEqual(archive.read(prefix+"README.md"), (REPO / "docs/compiler-build/distribution-readme.md").read_bytes())
            expected = {p.relative_to(REPO).as_posix() for p in (REPO / "stdlib").rglob("*.xen") if not p.is_symlink()}
            self.assertEqual({n.removeprefix(prefix) for n in names if n.startswith(prefix+"stdlib/")}, expected)
            for relative in expected:
                self.assertEqual(archive.read(prefix+relative), (REPO / relative).read_bytes())
            for relative in ("licenses/OCaml.txt", "LICENSE", "LICENSE-APACHE", "NOTICE", "THIRD_PARTY.md", "examples/demo.xen"):
                self.assertEqual(archive.read(prefix+relative), (REPO / relative).read_bytes())
            self.assertFalse(any(Path(n).suffix in (".ml", ".mli", ".py", ".dll") for n in names))

    def test_failures_preserve_existing_zip(self):
        output = self.root / "release.zip"
        output.write_bytes(b"previous release")
        with patch("packaging.common.subprocess.run", return_value=subprocess.CompletedProcess([], 0, "xen other\n")):
            with self.assertRaisesRegex(ValueError, "version mismatch"):
                package(None, output, binary=self.binary, version="1.2.3")
        with patch("packaging.common.subprocess.run", return_value=subprocess.CompletedProcess([], 0, "xen 1.2.3\n")):
            with patch("packaging.windows.package.zipfile.ZipFile.writestr", side_effect=OSError("disk full")):
                with self.assertRaisesRegex(OSError, "disk full"):
                    package(None, output, binary=self.binary, version="1.2.3")
            with self.assertRaisesRegex(ValueError, "architecture mismatch"):
                package(None, output, binary=self.binary, version="1.2.3", architecture="aarch64")
        self.assertEqual(output.read_bytes(), b"previous release")
        self.assertEqual({p.name for p in self.root.iterdir()}, {"xen.exe", "release.zip"})

    def test_cli_rejects_mixed_platform_formats(self):
        for writer in (tar_package, deb_package):
            with self.assertRaisesRegex(ValueError, "unsupported.*platform"):
                writer(None, None, binary=self.binary, platform="windows", version="1.2.3")
        for args in (("windows", "deb"), ("windows", "tar.gz"), ("linux", "zip"), ("darwin", "zip")):
            result = subprocess.run([sys.executable, "-m", "packaging.cli", "--platform", args[0],
                                     "--formats", args[1], "--output-dir", str(self.root / "dist")],
                                    cwd=REPO, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("supported platform/formats", result.stderr)
            self.assertFalse((self.root / "dist").exists())
        result = subprocess.run([sys.executable, "-m", "packaging.cli", "--platform", "windows",
                                 "--binary", str(self.binary), "--binary-architecture"],
                                cwd=REPO, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "x86_64\n")

    @unittest.skipUnless(os.name == "nt" and platform.machine().lower() in ("amd64", "x86_64"),
                         "installed ZIP execution requires native Windows x86_64")
    def test_native_zip_installation(self):
        version = (REPO / "VERSION").read_text().strip()
        result = subprocess.run([sys.executable, "-m", "packaging.cli", "--platform", "windows",
                                 "--architecture", "x86_64", "--output-dir", str(self.root)],
                                cwd=REPO, capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        verify(self.root / f"xen-{version}-windows-x86_64.zip", version)


if __name__ == "__main__":
    unittest.main(verbosity=2)
