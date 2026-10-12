# SPDX-License-Identifier: MIT OR Apache-2.0
"""Compiler-host smoke checks. XEN_BIN and JSON XEN_HOST_RUNNER allow an
explicit emulated compiler; run/test then need native execution or binfmt.
Generated-program execution remains an independent check, never implicit in Xen.
"""
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
XEN = Path(os.getenv("XEN_BIN", str(REPO / "compiler/dist/xen"))).resolve()
RUNNER = json.loads(os.getenv("XEN_HOST_RUNNER", "[]"))
spec = importlib.util.spec_from_file_location("xen_package", REPO / "scripts/package.py")
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)
ARCH = package.binary_architecture(XEN)
HOST_ARCH = {"arm64": "aarch64", "amd64": "x86_64"}.get(platform.machine(), platform.machine())


class HostTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xen-host-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "app.xen"
        self.source.write_text('use std.string;test fn host(){assert(std.string.contains("abc","b"));}'
                               'fn main(){println(std.string.split_byte("a=b",u8(61))[1]);}')
        self.env = dict(os.environ, PATH=str(self.root / "no-tools"))
        self.env.pop("XEN_STDLIB_ROOT", None)

    def invoke(self, *args, binary=XEN):
        return subprocess.run([*RUNNER, str(binary), *map(str, args)], env=self.env,
                              cwd=self.root, capture_output=True, text=True, timeout=60)

    def success(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def execute_generated(self, output, expected="b\n", args=()):
        execution = [str(output), *map(str, args)]
        if ARCH != HOST_ARCH:
            emulator = shutil.which("qemu-aarch64" if ARCH == "aarch64" else "qemu-x86_64")
            self.assertIsNotNone(emulator, "generated execution requires an explicit emulator")
            execution.insert(0, emulator)
        actual = subprocess.run(execution, capture_output=True, text=True, timeout=30)
        self.assertEqual((actual.returncode, actual.stdout, actual.stderr), (0, expected, ""))

    def test_compiler_emits_managed_file_program(self):
        self.source.write_text('use std.string;fn main(){let mut f=open_write(arg(0));'
                               'f.write("file host\\n");f.close();'
                               'println(std.string.split_byte(read_text(arg(0)),u8(10))[0]);}')
        path = self.root / "host-file"
        binary = XEN
        if os.getenv("XEN_HOST_ARCHIVE"):
            with tarfile.open(Path(os.environ["XEN_HOST_ARCHIVE"]).resolve()) as bundle:
                name = bundle.getnames()[0].split("/")[0]
                bundle.extractall(self.root / "file-archive", filter="data")
            relocated = self.root / "file-package"
            (self.root / "file-archive" / name).rename(relocated)
            binary = relocated / "bin/xen"
        self.success(self.invoke("check", self.source, binary=binary))
        for opt in ("off", "basic"):
            output = self.root / ("file-"+opt)
            self.success(self.invoke("build", self.source, f"--opt={opt}", "-o", output, binary=binary))
            self.assertEqual(package.binary_architecture(output), ARCH)
            self.execute_generated(output, "file host\n", args=(path,))
            self.assertEqual(path.read_bytes(), b"file host\n")

    def test_compiler_emits_platform_stdlib_program(self):
        self.source.write_text('use std.fs;use std.env;use std.io;use std.process;fn main(){'
                               'assert(std.process.id()>0 && std.process.parent_id()>0);'
                               'assert(match std.env.cwd(){Result.Ok(p)=>p.len()>0,_=>false});'
                               'assert(match std.fs.write(arg(0),"platform host"){Result.Ok(13)=>true,_=>false});'
                               'assert(match std.fs.append(arg(0),"\\n"){Result.Ok(1)=>true,_=>false});'
                               'assert(match std.fs.metadata(arg(0)){Result.Ok(m)=>m.is_file && !m.is_directory && m.size==14,_=>false});'
                               'assert(match std.fs.read_dir("."){Result.Ok(names)=>names.len()>0,_=>false});'
                               'let text=match std.fs.read(arg(0)){Result.Ok(s)=>s,_=>"bad"};'
                               'std.io.write_stdout(text);'
                               'assert(match std.fs.write(arg(1),"-9223372036854775808 +7"){Result.Ok(_)=>true,_=>false});'
                               'let ints=read_ints(arg(1));assert(ints.len()==2 && ints[0]==(-9223372036854775807-1) && ints[1]==7);'
                               'assert(match std.fs.write(arg(1),"-.5 1e2 -0.0 4.9406564584124654e-324"){Result.Ok(_)=>true,_=>false});'
                               'let floats=read_floats(arg(1));assert(floats.len()==4 && floats[0]==-0.5 && floats[1]==100.0);}')
        binary = XEN
        if os.getenv("XEN_HOST_ARCHIVE"):
            with tarfile.open(Path(os.environ["XEN_HOST_ARCHIVE"]).resolve()) as bundle:
                name = bundle.getnames()[0].split("/")[0]
                bundle.extractall(self.root / "platform-archive", filter="data")
            relocated = self.root / "platform-package"
            (self.root / "platform-archive" / name).rename(relocated)
            binary = relocated / "bin/xen"
        # An ARM compiler must select x86 services when explicitly cross-building.
        for target in (ARCH, "x86_64" if ARCH == "aarch64" else "aarch64"):
            self.success(self.invoke("check", self.source, f"--target={target}-linux", binary=binary))
            for opt in ("off", "basic"):
                output = self.root / ("platform-"+target+"-"+opt)
                self.success(self.invoke("build", self.source, f"--target={target}-linux",
                                         f"--opt={opt}", "-o", output, binary=binary))
                self.assertEqual(package.binary_architecture(output), target)
                execution = [str(output), str(self.root / "host-file"), str(self.root / "host-numbers")]
                if target != HOST_ARCH:
                    emulator = shutil.which("qemu-aarch64" if target == "aarch64" else "qemu-x86_64")
                    self.assertIsNotNone(emulator)
                    execution.insert(0, emulator)
                actual = subprocess.run(execution, cwd=self.root, capture_output=True, text=True, timeout=30)
                self.assertEqual((actual.returncode, actual.stdout, actual.stderr), (0, "platform host\n", ""))

    def test_version_check_default_build_and_cross_build(self):
        self.assertEqual(self.success(self.invoke("version")), "xen "+(REPO / "VERSION").read_text().strip()+"\n")
        self.success(self.invoke("check", self.source))
        for opt in ("off", "basic"):
            output = self.root / opt
            self.success(self.invoke("build", self.source, f"--opt={opt}", "-o", output))
            self.assertEqual(package.binary_architecture(output), ARCH)
            explicit = self.root / (opt+"-explicit")
            self.success(self.invoke("build", self.source, f"--target={ARCH}-linux", f"--opt={opt}", "-o", explicit))
            self.assertEqual(output.read_bytes(), explicit.read_bytes())
            self.execute_generated(output)
        for target in ("x86_64", "aarch64"):
            output = self.root / target
            self.success(self.invoke("build", self.source, f"--target={target}-linux", "-o", output))
            self.assertEqual(package.binary_architecture(output), target)

    def test_native_run_and_test(self):
        if RUNNER and ARCH != HOST_ARCH:
            self.skipTest("QEMU user compiler execution does not supply binfmt for child exec")
        self.assertEqual(self.success(self.invoke("run", self.source)), "b\n")
        self.assertIn("1 passed; 0 failed", self.success(self.invoke("test", self.source)))

    def test_relocated_compiler_adjacent_stdlib(self):
        original = self.root / "original"
        (original / "bin").mkdir(parents=True)
        shutil.copy2(XEN, original / "bin/xen")
        shutil.copytree(REPO / "stdlib", original / "stdlib")
        moved = self.root / "relocated"
        original.rename(moved)
        binary = moved / "bin/xen"
        self.success(self.invoke("check", self.source, binary=binary))
        output = self.root / "relocated-app"
        self.success(self.invoke("build", self.source, "-o", output, binary=binary))
        self.assertEqual(package.binary_architecture(output), ARCH)

    def test_package_architecture_and_relocated_archive(self):
        # Architecture derives from the binary, including emulated/cross builds,
        # rather than uname, filename, or the target emitted by Xen.
        for machine, name in ((62, "x86_64"), (183, "aarch64")):
            fixture = self.root / name
            header = bytearray(64)
            header[:7] = b"\x7fELF\x02\x01\x01"
            struct.pack_into("<H", header, 18, machine)
            fixture.write_bytes(header)
            self.assertEqual(package.binary_architecture(fixture), name)
        version = (REPO / "VERSION").read_text().strip()
        name = f"xen-{version}-linux-{ARCH}"
        result = subprocess.run(["make", "package", f"PACKAGE_BINARY={XEN}",
                                 f"VERSION={version}", "PACKAGE_PLATFORM=linux", f"PACKAGE_ARCH={ARCH}",
                                 "PACKAGE_NAME=", "PACKAGE=", "DUNE_WORKSPACE=/nonexistent/workspace",
                                 f"PACKAGE_RUNNER={json.dumps(RUNNER)}", f"DIST_DIR={self.root}"],
                                cwd=REPO, capture_output=True, text=True, timeout=60)
        self.success(result)
        archive = self.root / (name+".tar.gz")
        def verify_archive(path):
            self.assertEqual(path.name, name+".tar.gz")
            with tarfile.open(path) as bundle:
                self.assertEqual({entry.split("/")[0] for entry in bundle.getnames()}, {name})
                self.assertEqual(bundle.extractfile(name+"/bin/xen").read(), XEN.read_bytes())
                self.assertEqual(bundle.extractfile(name+"/VERSION").read(), (version+"\n").encode())
        verify_archive(archive)
        # Optionally verify the actual context-built release artifact as well
        # as exercising the existing-binary make interface above.
        if os.getenv("XEN_HOST_ARCHIVE"):
            archive = Path(os.environ["XEN_HOST_ARCHIVE"]).resolve()
            verify_archive(archive)
        with tarfile.open(archive) as bundle:
            bundle.extractall(self.root / "unpacked", filter="data")
        relocated = self.root / "moved-package"
        (self.root / "unpacked" / name).rename(relocated)
        binary = relocated / "bin/xen"
        self.assertEqual(package.binary_architecture(binary), ARCH)
        self.assertEqual(self.success(self.invoke("version", binary=binary)), f"xen {version}\n")
        self.success(self.invoke("check", self.source, binary=binary))
        for opt in ("off", "basic"):
            output = self.root / ("packaged-"+opt)
            self.success(self.invoke("build", self.source, f"--opt={opt}", "-o", output, binary=binary))
            self.assertEqual(package.binary_architecture(output), ARCH)
            self.execute_generated(output)

    def test_package_rejects_mismatch_and_invalid_runner(self):
        archive = self.root / "must-not-exist.tar.gz"
        opposite = "aarch64" if ARCH == "x86_64" else "x86_64"
        with self.assertRaisesRegex(ValueError, "architecture mismatch"):
            package.package(None, archive, binary=XEN, architecture=opposite, runner=RUNNER)
        with self.assertRaisesRegex(ValueError, "unsupported.*platform"):
            package.package(None, archive, binary=XEN, platform="windows", runner=RUNNER)
        with self.assertRaisesRegex(ValueError, "version mismatch"):
            package.package(None, archive, binary=XEN, version="not-the-built-version", runner=RUNNER)
        with self.assertRaises(subprocess.CalledProcessError):
            package.package(None, archive, binary=XEN, runner=[shutil.which("false")])
        self.assertFalse(archive.exists())
        self.assertEqual(package.parse_runner(json.dumps(RUNNER)), RUNNER)
        for value in ('"qemu-aarch64"', '{}', '[1]', '[""]', '["\\u0000"]', 'invalid'):
            with self.subTest(runner=value), self.assertRaises(ValueError):
                package.parse_runner(value)
        result = subprocess.run(["python3", str(REPO / "scripts/package.py"), "--binary", str(XEN),
                                 "--runner", '"qemu-aarch64"', "--output", str(archive)],
                                capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("runner must be a JSON array", result.stderr)
        self.assertFalse(archive.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
