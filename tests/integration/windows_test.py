# SPDX-License-Identifier: MIT OR Apache-2.0
"""PE foundation checks; --require-native makes Windows execution mandatory.

This fixture is independent of Xen lowering. Windows remains an unimplemented
CLI output target until the CPU ABI and runtime are ready.
"""
import ctypes
import os
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
FIXTURE = REPO / "_build/default/tests/windows_fixture.exe"
RUNNER = REPO / "_build/default/tests/windows_runner_fixture.exe"
XEN = REPO / ("compiler/dist/xen.exe" if os.name == "nt" else "compiler/dist/xen")
NATIVE = os.name == "nt" and platform.machine().lower() in ("amd64", "x86_64")


class PE:
    """Small independent reader: file offsets and RVAs are separate operations."""
    def __init__(self, path):
        self.path = path
        self.data = path.read_bytes()
        assert self.data[:2] == b"MZ"
        self.pe = self.u32(0x3c)
        assert self.data[self.pe:self.pe+4] == b"PE\0\0"
        self.machine, count, _, _, _, size, self.flags = struct.unpack_from("<HHIIIHH", self.data, self.pe+4)
        self.opt = self.pe+24
        assert self.u16(self.opt) == 0x20b and size == 240
        self.base = self.u64(self.opt+24)
        self.entry = self.u32(self.opt+16)
        self.image_size = self.u32(self.opt+56)
        self.headers_size = self.u32(self.opt+60)
        self.dll_flags = self.u16(self.opt+70)
        self.directories = [struct.unpack_from("<II", self.data, self.opt+112+i*8) for i in range(16)]
        self.sections = {}
        for i in range(count):
            name, size, rva, raw_size, offset, _, _, _, _, flags = struct.unpack_from(
                "<8sIIIIIIHHI", self.data, self.opt+240+i*40)
            self.sections[name.rstrip(b"\0").decode()] = (rva, size, offset, raw_size, flags)

    def u16(self, offset):
        return struct.unpack_from("<H", self.data, offset)[0]

    def u32(self, offset):
        return struct.unpack_from("<I", self.data, offset)[0]

    def u64(self, offset):
        return struct.unpack_from("<Q", self.data, offset)[0]

    def file_offset(self, rva, length=1):
        for start, size, offset, raw_size, _ in self.sections.values():
            if start <= rva and rva+length <= start+min(size, raw_size):
                return offset+rva-start
        raise ValueError("RVA is not backed by file data")

    def cstring(self, rva):
        offset = self.file_offset(rva)
        return self.data[offset:self.data.index(b"\0", offset)].decode("ascii")

    def imports(self):
        rva, size = self.directories[1]
        result = {}
        if (rva, size) == (0, 0):
            return result
        if not rva or size < 20:
            raise ValueError("invalid PE import directory")
        at = self.file_offset(rva, size)
        # Some linkers include thunks/names in the directory extent. The null
        # descriptor terminates the table, wherever it lies within that extent.
        for offset in range(at, at+size-19, 20):
            lookup, stamp, chain, name, iat = struct.unpack_from("<5I", self.data, offset)
            if not any((lookup, stamp, chain, name, iat)):
                return result
            assert stamp == chain == 0
            symbols = []
            while True:
                hint = self.u64(self.file_offset(lookup+8*len(symbols), 8))
                slot = self.u64(self.file_offset(iat+8*len(symbols), 8))
                assert hint == slot
                if not hint:
                    break
                assert hint >> 63 == 0
                symbols.append(self.cstring(hint+2))
            result[self.cstring(name)] = (symbols, iat)
        raise ValueError("unterminated PE import directory")


class PETests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xen-windows-공백 ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def fixture(self, mode="smoke"):
        path = self.root / (mode+".exe")
        subprocess.run([str(FIXTURE), mode, str(path)], check=True, timeout=30)
        return PE(path)

    def test_layout_imports_relocations_and_unwind(self):
        pe = self.fixture()
        again = self.root / "again.exe"
        subprocess.run([str(FIXTURE), "smoke", str(again)], check=True, timeout=30)
        self.assertEqual(pe.data, again.read_bytes())
        self.assertEqual(pe.machine, 0x8664)
        self.assertEqual(pe.u32(pe.opt+32), 0x1000)
        self.assertEqual(pe.u32(pe.opt+36), 0x200)
        self.assertEqual(pe.u16(pe.opt+68), 3)  # console
        self.assertEqual(pe.dll_flags, 0x160)  # NX, dynamic base, high entropy
        self.assertFalse(pe.flags & 1)  # relocations not stripped
        self.assertEqual(pe.u64(pe.opt+72), 0x100000)
        self.assertEqual(pe.u64(pe.opt+80), 0x1000)
        self.assertEqual(pe.u32(pe.opt+108), 16)
        self.assertEqual(set(pe.sections), {".text", ".rdata", ".data", ".idata", ".pdata", ".xdata", ".reloc"})
        last_rva, last_file = 0x1000, pe.headers_size
        for rva, size, offset, raw_size, flags in pe.sections.values():
            self.assertEqual(rva % 4096, 0)
            self.assertEqual(offset % 512, 0)
            self.assertEqual(raw_size % 512, 0)
            self.assertGreaterEqual(rva, last_rva)
            self.assertGreaterEqual(offset, last_file)
            self.assertLessEqual(offset+raw_size, len(pe.data))
            self.assertFalse(flags & 0x80000000 and flags & 0x20000000)
            last_rva = rva+(max(size, raw_size)+4095)//4096*4096
            last_file = offset+raw_size
        self.assertEqual(last_rva, pe.image_size)
        self.assertEqual(last_file, len(pe.data))
        text, const, data = (pe.sections[name] for name in (".text", ".rdata", ".data"))
        self.assertEqual(pe.entry, text[0])
        self.assertEqual(pe.u64(data[2]), pe.base+const[0])
        self.assertGreater(data[1], data[3])
        with self.assertRaises(ValueError):
            pe.file_offset(data[0]+0x1000)
        imports = pe.imports()
        self.assertEqual(pe.directories[1][1], 20*(len(imports)+1))
        self.assertEqual(set(imports), {"SHELL32.dll", "KERNEL32.dll"})
        self.assertEqual(imports["SHELL32.dll"][0], ["CommandLineToArgvW"])
        self.assertEqual(set(imports["KERNEL32.dll"][0]), {"ExitProcess", "GetStdHandle", "ReadFile", "WriteFile", "GetModuleHandleW"})
        iat, iat_size = pe.directories[12]
        self.assertEqual(iat, imports["SHELL32.dll"][1])
        self.assertEqual(iat_size, (2+6)*8)
        reloc, length = pe.directories[5]
        at = pe.file_offset(reloc, length)
        self.assertEqual(struct.unpack_from("<IIHH", pe.data, at), (data[0], 12, 0xa000, 0))
        pdata, size = pe.directories[3]
        self.assertEqual(size, 24)
        ranges = [struct.unpack_from("<III", pe.data, pe.file_offset(pdata+12*i, 12)) for i in range(2)]
        self.assertEqual(ranges[0][0], text[0])
        self.assertEqual(ranges[0][1], ranges[1][0])
        self.assertEqual(ranges[1][1], text[0]+text[1])
        self.assertEqual(pe.data[pe.file_offset(ranges[0][2], 8):][:8], bytes([1, 4, 1, 0, 4, 0x62, 0, 0]))
        self.assertEqual(pe.data[pe.file_offset(ranges[1][2], 12):][:12],
                         bytes([1, 11, 4, 0x25, 11, 3, 6, 0x42, 2, 0x30, 1, 0x50]))

    def test_independent_binary_tools(self):
        pe = self.fixture()
        llvm = shutil.which("llvm-readobj")
        objdump = shutil.which("objdump")
        if llvm:
            args = [llvm, "--file-headers", "--sections", "--coff-imports", "--coff-basereloc", "--unwind"]
        elif objdump:
            args = [objdump, "-x"]
        else:
            self.fail("PE validation requires llvm-readobj or objdump")
        result = subprocess.run([*args, str(pe.path)], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        for value in ("WriteFile", "ExitProcess", ".pdata", ".reloc"):
            self.assertIn(value, result.stdout)

    def test_import_directory_extent_can_include_lookup_tables_and_names(self):
        pe = self.fixture()
        expected = pe.imports()
        image = bytearray(pe.data)
        # Reproduce MinGW's directory size, which covers the import payload
        # beyond the descriptor terminator instead of only the descriptor array.
        struct.pack_into("<I", image, pe.opt+112+8+4, pe.sections[".idata"][1])
        path = self.root/"extended-import-directory.exe"
        path.write_bytes(image)
        self.assertEqual(PE(path).imports(), expected)

    def test_import_directory_must_contain_a_complete_null_descriptor(self):
        pe = self.fixture()
        for size in (0, 19, 40, 59):
            with self.subTest(size=size):
                image = bytearray(pe.data)
                struct.pack_into("<I", image, pe.opt+112+8+4, size)
                path = self.root/"truncated-import-directory.exe"
                path.write_bytes(image)
                with self.assertRaisesRegex(ValueError, "PE import directory"):
                    PE(path).imports()

    def test_relocation_blocks_across_code_constants_and_zero_fill_targets(self):
        pe = self.fixture("layout")
        text, const, data = (pe.sections[name] for name in (".text", ".rdata", ".data"))
        expected = {text[0]+8: text[0], const[0]+0xff8: data[0]+8,
                    const[0]+0x1000: const[0], data[0]: text[0]+1}
        rva, length = pe.directories[5]
        at, end = pe.file_offset(rva, length), pe.file_offset(rva, length)+length
        found = []
        while at < end:
            page, size = struct.unpack_from("<II", pe.data, at)
            self.assertEqual(size % 4, 0)
            self.assertGreaterEqual(size, 8)
            for entry, in struct.iter_unpack("<H", pe.data[at+8:at+size]):
                if entry >> 12 == 0:
                    self.assertEqual(entry, 0)
                    continue
                self.assertEqual(entry >> 12, 10)
                source = page+(entry & 0xfff)
                found.append(source)
                self.assertEqual(pe.u64(pe.file_offset(source, 8)), pe.base+expected[source])
            at += size
        self.assertEqual(at, end)
        self.assertEqual(found, sorted(expected))
        self.assertEqual(pe.directories[1], (0, 0))
        self.assertEqual(pe.imports(), {})
        self.assertEqual(pe.directories[3], (0, 0))

    @unittest.skipUnless(NATIVE, "requires native Windows x64")
    def test_native_loader_and_host_runner(self):
        pe = self.fixture()
        for _ in range(2):
            result = subprocess.run([str(pe.path)], stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
            self.assertEqual((result.returncode, result.stderr), (0, b""))
            self.assertEqual(result.stdout[:-8], b"xen-pe-fixture\n")
            actual_base, = struct.unpack("<Q", result.stdout[-8:])
            self.assertNotEqual(actual_base, pe.base, "fixture must exercise real rebasing")
        temporary = self.root / "runner temporary"
        temporary.mkdir()
        for mode in ("smoke", "missing-dll", "missing-symbol"):
            image = self.fixture(mode)
            stdout, stderr = self.root / "stdout", self.root / "stderr"
            env = dict(os.environ, TEMP=str(temporary), TMP=str(temporary), TMPDIR=str(temporary))
            result = subprocess.run([str(RUNNER), str(image.path), str(stdout), str(stderr)],
                                    env=env, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            status = int(result.stdout)
            if mode == "smoke":
                self.assertEqual(status, 0)
                self.assertEqual(stdout.read_bytes()[:-8], b"xen-pe-fixture\n")
            else:
                expected = 0xc0000135 if mode == "missing-dll" else 0xc0000139
                self.assertEqual(status & 0xffffffff, expected,
                                 f"{mode}: exit {status & 0xffffffff:#x}, stdout={stdout.read_bytes()!r}")
                self.assertEqual(stdout.read_bytes(), b"")  # no user code ran
            self.assertEqual(stderr.read_bytes(), b"")
            self.assertEqual(list(temporary.iterdir()), [])

    @unittest.skipUnless(NATIVE, "requires native Windows x64")
    def test_native_relocation_protection_and_virtual_unwind(self):
        pe = self.fixture()
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.LoadLibraryExW.argtypes = [ctypes.c_wchar_p, ctypes.c_void_p, ctypes.c_uint32]
        kernel.LoadLibraryExW.restype = ctypes.c_void_p
        kernel.FreeLibrary.argtypes = [ctypes.c_void_p]
        kernel.VirtualAlloc.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint32]
        kernel.VirtualAlloc.restype = ctypes.c_void_p
        kernel.VirtualFree.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32]
        kernel.VirtualFree.restype = ctypes.c_int
        # Occupy the preferred range when free so this test cannot accidentally
        # pass without the Windows loader applying DIR64 relocations.
        reservation = kernel.VirtualAlloc(pe.base, pe.image_size, 0x2000, 1)
        if reservation:
            self.addCleanup(kernel.VirtualFree, reservation, 0, 0x8000)
        else:
            self.assertEqual(ctypes.get_last_error(), 487)  # already occupied
        # An EXE loaded as an image is rebased but its startup/imports aren't run.
        base = kernel.LoadLibraryExW(str(pe.path), None, 1)
        self.assertTrue(base, ctypes.get_last_error())
        self.addCleanup(kernel.FreeLibrary, base)
        self.assertNotEqual(base, pe.base)
        self.assertEqual(ctypes.c_uint64.from_address(base+pe.sections[".data"][0]).value,
                         base+pe.sections[".rdata"][0])
        self.assertEqual(ctypes.string_at(base+pe.sections[".data"][0]+0x1000, 32), bytes(32))
        class MemoryInfo(ctypes.Structure):
            _fields_ = [("BaseAddress", ctypes.c_void_p), ("AllocationBase", ctypes.c_void_p),
                        ("AllocationProtect", ctypes.c_uint32), ("PartitionId", ctypes.c_uint16),
                        ("RegionSize", ctypes.c_size_t), ("State", ctypes.c_uint32),
                        ("Protect", ctypes.c_uint32), ("Type", ctypes.c_uint32)]
        kernel.VirtualQuery.argtypes = [ctypes.c_void_p, ctypes.POINTER(MemoryInfo), ctypes.c_size_t]
        kernel.VirtualQuery.restype = ctypes.c_size_t
        for name, expected in ((".text", 0x20), (".rdata", 2), (".data", 4)):
            info = MemoryInfo()
            self.assertEqual(kernel.VirtualQuery(base+pe.sections[name][0], ctypes.byref(info),
                                                ctypes.sizeof(info)), ctypes.sizeof(info))
            self.assertIn(info.Protect & 0xff, (expected, 8) if name == ".data" else (expected,))
        ntdll = ctypes.WinDLL("ntdll")
        unwind = ntdll.RtlVirtualUnwind
        unwind.argtypes = [ctypes.c_uint32, ctypes.c_uint64, ctypes.c_uint64, ctypes.c_void_p,
                           ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p),
                           ctypes.POINTER(ctypes.c_uint64), ctypes.c_void_p]
        unwind.restype = ctypes.c_void_p
        pdata, _ = pe.directories[3]
        helper, end, _ = struct.unpack_from("<III", pe.data, pe.file_offset(pdata+12, 12))
        stack = ctypes.create_string_buffer(4096)
        entry_sp = (ctypes.addressof(stack)+2047) & ~15
        entry_sp += 8  # return address makes entry RSP = 8 modulo 16
        parent_rip, parent_rbp, parent_rbx = 0x12345678, 0x11112222, 0x33334444
        ctypes.c_uint64.from_address(entry_sp).value = parent_rip
        ctypes.c_uint64.from_address(entry_sp-8).value = parent_rbp
        ctypes.c_uint64.from_address(entry_sp-16).value = parent_rbx
        # Each PC is an instruction boundary, including partially executed
        # prologs, a temporary aligned body allocation, and each epilog step.
        for pc, sp, bp, bx in (
                (0, entry_sp, parent_rbp, parent_rbx),
                (1, entry_sp-8, parent_rbp, parent_rbx),
                (2, entry_sp-16, parent_rbp, parent_rbx),
                (6, entry_sp-56, parent_rbp, parent_rbx),
                (11, entry_sp-56, entry_sp-24, parent_rbx),
                (15, entry_sp-72, entry_sp-24, parent_rbx),
                (19, entry_sp-72, entry_sp-24, parent_rbx),
                (24, entry_sp-72, entry_sp-24, 42),
                (28, entry_sp-72, entry_sp-24, 42),
                (32, entry_sp-56, entry_sp-24, 42),
                (34, entry_sp-56, entry_sp-24, 42),
                (38, entry_sp-16, entry_sp-24, 42),
                (39, entry_sp-8, entry_sp-24, parent_rbx),
                (40, entry_sp, parent_rbp, parent_rbx)):
            with self.subTest(pc=pc):
                self.assertLess(helper+pc, end)
                context_storage = ctypes.create_string_buffer(1232+15)
                context = (ctypes.addressof(context_storage)+15) & ~15
                def put(offset, value):
                    ctypes.c_uint64.from_address(context+offset).value = value
                put(144, bx); put(152, sp); put(160, bp); put(248, base+helper+pc)
                handler = ctypes.c_void_p()
                establisher = ctypes.c_uint64()
                unwind(0, base, base+helper+pc, base+pdata+12, context,
                       ctypes.byref(handler), ctypes.byref(establisher), None)
                for offset, expected in ((144, parent_rbx), (152, entry_sp+8),
                                         (160, parent_rbp), (248, parent_rip)):
                    self.assertEqual(ctypes.c_uint64.from_address(context+offset).value, expected)


class CompilerHostTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xen-host-공백 ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "app.xen"
        self.source.write_text('use std.string; fn main(){assert(std.string.contains("abc","b"));}', encoding="utf-8")

    def invoke(self, *args, binary=XEN, env=None):
        return subprocess.run([str(binary), *map(str, args)], cwd=self.root,
                              env=env, capture_output=True, text=True, encoding="utf-8", timeout=60)

    def success(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_version_and_explicit_linux_targets(self):
        self.assertEqual(self.success(self.invoke("version")), "xen "+(REPO/"VERSION").read_text().strip()+"\n")
        for arch, machine in (("x86_64", 62), ("aarch64", 183)):
            output = self.root / (arch+"-linux")
            self.success(self.invoke("build", self.source, "--target="+arch+"-linux", "-o", output))
            data = output.read_bytes()
            self.assertEqual(data[:7], b"\x7fELF\x02\x01\x01")
            self.assertEqual(struct.unpack_from("<H", data, 18)[0], machine)
        if NATIVE:
            pe = PE(XEN)
            self.assertEqual(pe.machine, 0x8664)
            print("Native compiler imports:", sorted(pe.imports()))
            result = self.invoke("build", self.source)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("x86_64-windows' is not implemented", result.stderr)

    def test_relocated_stdlib_and_path_launch(self):
        original = self.root / "original"
        (original/"bin").mkdir(parents=True)
        name = XEN.name
        shutil.copy2(XEN, original/"bin"/name)
        shutil.copytree(REPO/"stdlib", original/"lib/xen")
        moved = self.root / "moved 공백"
        original.rename(moved)
        env = dict(os.environ, PATH=str(moved/"bin"))
        env.pop("XEN_STDLIB_ROOT", None)
        self.success(self.invoke("check", self.source, "--target=x86_64-linux", binary=moved/"bin"/name, env=env))
        # Windows CreateProcess searches the parent's PATH, independently of the
        # environment supplied to the child. Exercise a genuine PATH launch.
        with mock.patch.dict(os.environ, {"PATH": str(moved/"bin")}):
            self.success(self.invoke("check", self.source, "--target=x86_64-linux", binary=name, env=env))

    def test_nested_modules_and_root_boundary(self):
        self.source.write_text("module app;import lib.math; test fn host(){assert(lib.math.value()==7);}", encoding="utf-8")
        (self.root/"lib").mkdir()
        (self.root/"lib/math.xen").write_text("module lib.math;fn value()->Int{return 7;}", encoding="utf-8")
        # Discovery compiles each project test before attempting execution. On
        # Windows the generated ELF can't run, but path/module loading must pass.
        result = self.invoke("test", self.root, "--target=x86_64-linux")
        if NATIVE:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("cannot execute target", result.stderr)
        else:
            self.success(result)

    def test_run_cleans_temporary_files_on_error(self):
        temporary = self.root/"temporary"
        temporary.mkdir()
        env = dict(os.environ, TEMP=str(temporary), TMP=str(temporary), TMPDIR=str(temporary))
        for source in ("fn main(){panic(\"expected\");}", "fn main(){let n:Int=false;}"):
            self.source.write_text(source, encoding="utf-8")
            result = self.invoke("run", self.source, "--target=x86_64-linux", env=env)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(list(temporary.iterdir()), [])


if __name__ == "__main__":
    if NATIVE:
        # Missing DLL/export fixtures must terminate without a modal error box.
        ctypes.WinDLL("kernel32").SetErrorMode(0x8003)
    if "--require-native" in sys.argv:
        sys.argv.remove("--require-native")
        if not NATIVE:
            raise SystemExit("--require-native requires a native Windows x64 host")
    unittest.main(verbosity=2)
