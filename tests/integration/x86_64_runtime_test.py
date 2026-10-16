# SPDX-License-Identifier: MIT OR Apache-2.0
"""Relocatable CPU formatting/parsing and inline service cleanup contracts."""
import os
from pathlib import Path
import platform
import re
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "_build/default/tests/x86_64_runtime_fixture.exe"
QEMU = shutil.which("qemu-x86_64")


class RuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(["dune", "build", "tests/x86_64_runtime_fixture.exe"], cwd=ROOT, check=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xen-x86-runtime-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def execute(self, source, payload=b"", mode="normal", opt="off", trace=False, arguments=None):
        path, data, output = (self.root / name for name in ("main.xen", "input", "program"))
        path.write_text(source)
        data.write_bytes(payload)
        # Xen generation itself must work without an assembler/disassembler/linker.
        built = subprocess.run([str(FIXTURE), mode, str(path), str(output), opt],
                               env=dict(os.environ, PATH=str(self.root / "no-tools")), capture_output=True)
        self.assertEqual(built.returncode, 0, built.stderr)
        command = []
        if trace or platform.machine() not in ("x86_64", "amd64"):
            if not QEMU:
                self.skipTest("execution/tracing requires qemu-x86_64")
            command = [QEMU, *(["-strace"] if trace else [])]
        return subprocess.run([*command, str(output), *(arguments if arguments is not None else [str(data)])],
                              capture_output=True, timeout=30)

    def balanced(self, trace):
        mappings, files = {}, set()
        allocations = 0
        for line in trace.decode().splitlines():
            if match := re.search(r"mmap\(NULL,(\d+),.*\) = (0x[0-9a-f]+)$", line):
                size, address = int(match[1]), match[2]
                self.assertNotIn(address, mappings)
                mappings[address] = size
                allocations += 1
            elif match := re.search(r"munmap\((0x[0-9a-f]+),(\d+)\) = 0$", line):
                address, size = match[1], int(match[2])
                self.assertEqual(mappings.pop(address, None), size, line)
            elif match := re.search(r"openat\(.*\) = (\d+)$", line):
                fd = int(match[1])
                self.assertNotIn(fd, files)
                files.add(fd)
            elif " close(" in line:
                match = re.search(r"close\((-?\d+)\) = (.*)$", line)
                self.assertIsNotNone(match, line)
                self.assertEqual(match[2], "0", "unexpected/repeated close: " + line)
                fd = int(match[1])
                self.assertIn(fd, files)
                files.remove(fd)
        self.assertEqual(mappings, {}, trace[-3000:])
        self.assertEqual(files, set(), trace[-3000:])
        return allocations

    def test_float_formatting_with_long_write_service(self):
        source = ('fn main(){println([-0.0,0.0,1.0,-1.5,1e-6,1e-7,1e16,1e17,'
                  '1.7976931348623157e308,4.9406564584124654e-324]);'
                  'println(1.0);println(1.0/0.0);println(-1.0/0.0);}')
        expected = (b"[-0, 0, 1, -1.5, 9.9999999999999995e-07, 9.9999999999999995e-08, 10000000000000000, 1e+17, "
                    b"1.7976931348623157e+308, 4.9406564584124654e-324]\n1.0\ninf\n-inf\n")
        for opt in ("off", "basic"):
            result = self.execute(source, opt=opt)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, expected, b""))

    def test_file_growth_numeric_parsing_and_cleanup(self):
        cases = [
            ('print(read_text(arg(0)));', bytes(range(256)) * 33, bytes(range(256)) * 33),
            ('println(read_ints(arg(0)));', b"-9223372036854775808 +9223372036854775807\t-0 +0 0001",
             b"[-9223372036854775808, 9223372036854775807, 0, 0, 1]\n"),
            ('println(len(read_ints(arg(0))));', b"1 " * 8193, b"8193\n"),
            ('let mut v=read_ints(arg(0));v.push(4);println(v);', b"1 2 3", b"[1, 2, 3, 4]\n"),
            ('println(read_floats(arg(0)));', b"1 -.5 2. 1e2 -0.0 4.9406564584124654e-324",
             b"[1, -0.5, 2, 100, -0, 4.9406564584124654e-324]\n"),
        ]
        for opt in ("off", "basic"):
            for body, payload, expected in cases:
                with self.subTest(opt=opt, body=body):
                    result = self.execute("fn main(){" + body + "}", payload, opt=opt, trace=True)
                    self.assertEqual((result.returncode, result.stdout), (0, expected), result.stderr[-2000:])
                    self.assertGreater(self.balanced(result.stderr), 2)

    def test_parsed_binary64_bits_and_relocated_constant(self):
        tokens = "-0.0 .5 2. 1e2 4.9406564584124654e-324 1.7976931348623157e308".split()
        source = ('#global[bb]\nfn main(){let values=read_floats(arg(0));let p=raw_alloc<F64>(1);'
                  'let mut i=0;while i<len(values){raw_store(p,0,values[i]);'
                  'syscall3(1,1,ptr_addr(p),8);i=i+1;}raw_free(p);}')
        expected = b"".join(struct.pack("<d", float(token)) for token in tokens)
        for opt in ("off", "basic"):
            result = self.execute(source, " ".join(tokens).encode(), opt=opt)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, expected, b""))

    def test_service_failures_release_inputs_and_close_once(self):
        for reader in ("read_text", "read_ints", "read_floats"):
            cases = [("alloc:1", b"1 2 3", b"allocation failed"),
                     ("alloc:2", b"1 2 3", b"allocation failed"),
                     ("alloc:3", b"1 2 3", b"allocation failed"),
                     ("alloc:3", b"1 " * 4097, b"allocation failed"),
                     ("read_error", b"1 2 3", b"file read failed"),
                     ("close_error", b"1 2 3", b"file close failed")]
            for opt in ("off", "basic"):
                for mode, payload, error in cases:
                    with self.subTest(reader=reader, mode=mode, size=len(payload), opt=opt):
                        result = self.execute("fn main(){" + reader + "(arg(0));}", payload,
                                              mode=mode, opt=opt, trace=True)
                        self.assertEqual((result.returncode, result.stdout), (1, b""), result.stderr[-2000:])
                        self.assertIn(error, result.stderr)
                        self.balanced(result.stderr)

    def test_empty_invalid_range_nul_and_open_failures(self):
        cases = [("read_ints", b"", b"[]\n", None),
                 ("read_floats", b" \t\r\n ", b"[]\n", None),
                 ("read_ints", b"0 7 9223372036854775808", b"", b"integer out of range"),
                 ("read_ints", b"0 7 -9223372036854775809", b"", b"integer out of range"),
                 ("read_ints", b"0 7 1\x002", b"", b"invalid integer token"),
                 ("read_floats", b"0 7 1e+", b"", b"invalid float token"),
                 ("read_floats", b"0 7 1e309", b"", b"float out of range"),
                 ("read_floats", b"0 7 1e-400", b"", b"float out of range")]
        for opt in ("off", "basic"):
            for reader, payload, expected, error in cases:
                result = self.execute("fn main(){println(" + reader + "(arg(0)));}", payload,
                                      opt=opt, trace=True)
                self.assertEqual((result.returncode, result.stdout), (int(error is not None), expected), result.stderr)
                if error:
                    self.assertIn(error, result.stderr)
                self.balanced(result.stderr)
            for path, error in [("a\x00b", b"embedded NUL"),
                                ("/definitely/missing/xen-runtime", b"file open failed")]:
                result = self.execute('fn main(){read_text("' + path + '");}', opt=opt, trace=True)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(error, result.stderr)
                self.balanced(result.stderr)


if __name__ == "__main__":
    unittest.main()
