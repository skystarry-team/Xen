# SPDX-License-Identifier: MIT OR Apache-2.0
"""Win64 bridge checks. Native Windows execution is mandatory on Windows;
Linux x86-64 additionally exercises identical bytes against GCC ms_abi exports.
The Linux harness is an ABI check, not evidence of Windows loader behavior.
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

from windows_test import PE, NATIVE, REPO

FIXTURE = REPO / "_build/default/tests/windows_abi_fixture.exe"
AUXILIARY = sys.platform == "linux" and platform.machine().lower() in ("x86_64", "amd64")


class Win64Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.environment = tempfile.TemporaryDirectory(prefix="xen-win64-tools-")
        cls.addClassCleanup(cls.environment.cleanup)
        cls.tools = Path(cls.environment.name)
        if NATIVE or AUXILIARY:
            compiler = shutil.which("x86_64-w64-mingw32-gcc" if NATIVE else "gcc")
            if not compiler:
                raise RuntimeError("Win64 execution checks require the configured MinGW GCC (Windows) or GCC (Linux)")
            for delta, name in ((1, "xen-abi-first.dll"), (2, "xen-abi-second.dll")):
                subprocess.run([compiler, "-shared", "-O2", *( ["-static-libgcc"] if NATIVE else ["-fPIC"] ),
                                f"-DEXPORT_DELTA={delta}", str(REPO/"tests/fixtures/windows_abi.c"),
                                "-o", str(cls.tools/name)], check=True)
            if AUXILIARY:
                subprocess.run([compiler, "-O2", "-Wall", "-Wextra",
                                str(REPO/"tests/fixtures/windows_abi_runner.c"), "-ldl",
                                "-o", str(cls.tools/"abi-runner")], check=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xen-win64-공백 ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def fixture(self, alignment="aligned"):
        path = self.root/(alignment+".exe")
        subprocess.run([str(FIXTURE), alignment, str(path)], check=True, timeout=30)
        return PE(path)

    def functions(self, pe):
        rva, size = pe.directories[3]
        return [struct.unpack_from("<III", pe.data, pe.file_offset(rva+i, 12))
                for i in range(0, size, 12)]

    def execute(self, pe):
        for name in ("xen-abi-first.dll", "xen-abi-second.dll"):
            shutil.copy2(self.tools/name, self.root/name)
        command = [str(pe.path)] if NATIVE else [str(self.tools/"abi-runner"), str(pe.path),
            str(self.root/"xen-abi-first.dll"), str(self.root/"xen-abi-second.dll")]
        return subprocess.run(command, capture_output=True, timeout=30, cwd=self.root)

    def test_machine_ir_pe_import_and_frame_composition(self):
        pe = self.fixture()
        imports = pe.imports()
        self.assertEqual(set(imports), {"KERNEL32.dll", "xen-abi-first.dll", "xen-abi-second.dll"})
        self.assertEqual(imports["xen-abi-second.dll"][0], ["same_export"])
        self.assertIn("same_export", imports["xen-abi-first.dll"][0])
        self.assertNotEqual(imports["xen-abi-first.dll"][1], imports["xen-abi-second.dll"][1])
        functions = self.functions(pe)
        self.assertEqual(len(functions), 10)  # probed helper, nine call bridges
        for begin, end, unwind in functions:
            self.assertLess(begin, end)
            self.assertEqual(pe.data[pe.file_offset(begin, 4):][:4], b"\x55\x48\x89\xe5")
            self.assertEqual(pe.data[pe.file_offset(end-6, 6):][:6], b"\x48\x8d\x65\0\x5d\xc3")
            self.assertEqual(pe.data[pe.file_offset(unwind, 8):][:8], bytes([1, 4, 2, 5, 4, 3, 1, 0x50]))
        # The entry actually CALLs this rebased data pointer. This also proves
        # code-label relocation was not confused with the PE writer's IAT.
        data = pe.sections[".data"]
        self.assertEqual(pe.u64(data[2]), pe.base+functions[1][0])
        self.assertEqual(pe.dll_flags, 0x160)
        # Every reusable bridge must call through a real, loader-populated IAT
        # slot. CPU-created legacy .data import slots intentionally remain zero.
        slots = {iat+8*i for symbols, iat in imports.values() for i in range(len(symbols))}
        for begin, end, _ in functions[1:]:
            code = pe.data[pe.file_offset(begin, end-begin):][:end-begin]
            call = code.index(b"\xff\x15")
            displacement = struct.unpack_from("<i", code, call+2)[0]
            self.assertIn(begin+call+6+displacement, slots)
        for offset in range(8, data[1], 8):
            self.assertEqual(pe.u64(data[2]+offset), 0)

    def test_independent_binary_tool_reads_composed_unwind(self):
        pe = self.fixture()
        if llvm := shutil.which("llvm-readobj"):
            command = [llvm, "--coff-imports", "--coff-basereloc", "--unwind", str(pe.path)]
        elif objdump := shutil.which("objdump"):
            command = [objdump, "-x", str(pe.path)]
        else:
            self.skipTest("requires LLVM or objdump")
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ("xen-abi-first.dll", "xen-abi-second.dll", "same_export"):
            self.assertIn(name, result.stdout)
        self.assertRegex(result.stdout.lower(), r"frame[^\n]*rbp")

    @unittest.skipUnless(NATIVE or AUXILIARY, "execution needs native Windows or Linux x86-64 ABI harness")
    def test_positional_scalars_shadow_space_and_register_preservation(self):
        for alignment in ("aligned", "unaligned"):
            with self.subTest(alignment=alignment, native=NATIVE):
                pe = self.fixture(alignment)
                result = self.execute(pe)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))

    @unittest.skipUnless(NATIVE or AUXILIARY, "execution needs native Windows or Linux x86-64 ABI harness")
    def test_volatile_fp_preservation_check_detects_a_broken_bridge(self):
        pe = self.fixture()
        begin, end, _ = self.functions(pe)[1]
        offset = pe.file_offset(begin, end-begin)
        code = pe.data[offset:offset+end-begin]
        restore = code.index(b"\xf3\x0f\x6f\x85")  # MOVDQU xmm0, spill
        broken = bytearray(pe.data)
        broken[offset+restore:offset+restore+8] = b"\x90"*8
        pe.path.write_bytes(broken)
        result = self.execute(pe)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (91, b"", b""))

    @unittest.skipUnless(NATIVE, "guard-page probing requires a native Windows stack")
    def test_small_commit_stack_requires_the_emitted_page_probes(self):
        pe = self.fixture()
        self.assertEqual(self.execute(pe).returncode, 0)
        begin, end, _ = self.functions(pe)[0]
        offset = pe.file_offset(begin, end-begin)
        code = pe.data[offset:offset+end-begin]
        probe = b"\xf6\x04\x24\0"  # TEST byte ptr [rsp], 0
        self.assertEqual(code.count(probe), 2)  # loop and trailing fraction
        broken = bytearray(pe.data)
        for position in range(len(code)-len(probe)+1):
            if code[position:position+len(probe)] == probe:
                broken[offset+position:offset+position+len(probe)] = b"\x90"*len(probe)
        pe.path.write_bytes(broken)
        result = self.execute(pe)
        # Skipping the guard into reserved, uncommitted stack pages must fault.
        self.assertIn(result.returncode & 0xffffffff, (0xc0000005, 0xc00000fd))

    @unittest.skipUnless(NATIVE, "RtlVirtualUnwind requires native Windows x64")
    def test_actual_bridge_and_large_frame_virtual_unwind(self):
        pe = self.fixture()
        # DONT_RESOLVE_DLL_REFERENCES maps the EXE without loading the test DLLs.
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        load = kernel.LoadLibraryExW
        load.argtypes, load.restype = [ctypes.c_wchar_p, ctypes.c_void_p, ctypes.c_uint32], ctypes.c_void_p
        free = kernel.FreeLibrary
        free.argtypes, free.restype = [ctypes.c_void_p], ctypes.c_int
        base = load(str(pe.path), None, 1)
        self.assertTrue(base, ctypes.get_last_error())
        self.addCleanup(free, base)
        unwind = kernel.RtlVirtualUnwind
        unwind.argtypes = [ctypes.c_uint32, ctypes.c_uint64, ctypes.c_uint64, ctypes.c_void_p,
                           ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p),
                           ctypes.POINTER(ctypes.c_uint64), ctypes.c_void_p]
        unwind.restype = ctypes.c_void_p
        pdata, _ = pe.directories[3]
        for function_index, (begin, end, _) in enumerate(self.functions(pe)):
            code = pe.data[pe.file_offset(begin, end-begin):][:end-begin]
            large = function_index == 0
            allocation = 128*1024+32 if large else struct.unpack_from("<I", code, 7)[0]
            for entry_alignment in (0, 8):
                stack = ctypes.create_string_buffer(256*1024+32)
                entry_sp = (ctypes.addressof(stack)+256*1024) & ~15
                entry_sp += entry_alignment
                parent_rip, parent_rbp = 0x123456789, 0x1122334455
                ctypes.c_uint64.from_address(entry_sp).value = parent_rip
                ctypes.c_uint64.from_address(entry_sp-8).value = parent_rbp
                frame = entry_sp-8
                body_sp = frame-allocation if large else (frame-allocation) & ~15
                epilog = len(code)-6
                cases = [(0, entry_sp, parent_rbp), (1, frame, parent_rbp), (4, frame, frame),
                         (epilog, body_sp, frame), (epilog+4, frame, frame),
                         (epilog+5, entry_sp, parent_rbp)]
                if large:
                    # Stop within several iterations of the page-probing loop.
                    for pages in (0, 1, 16, 31):
                        cases += [(10, frame-pages*4096, frame),
                                  (17, frame-(pages+1)*4096, frame),
                                  (21, frame-(pages+1)*4096, frame)]
                    cases += [(30, frame-128*1024, frame), (37, body_sp, frame), (41, body_sp, frame)]
                else:
                    call = code.index(b"\xff\x15")
                    cases += [(11, frame-allocation, frame), (15, body_sp, frame),
                              (call, body_sp, frame), (call+6, body_sp, frame)]
                for pc, sp, bp in cases:
                    with self.subTest(function=function_index, alignment=entry_alignment, pc=pc, sp=sp):
                        storage = ctypes.create_string_buffer(1232+15)
                        context = (ctypes.addressof(storage)+15) & ~15
                        nonvolatile = [(144, 0x3333), (168, 0x6666), (176, 0x7777),
                                       (216, 0x1212), (224, 0x1313), (232, 0x1414), (240, 0x1515)]
                        for offset, value in [*nonvolatile, (152, sp), (160, bp), (248, base+begin+pc)]:
                            ctypes.c_uint64.from_address(context+offset).value = value
                        handler, establisher = ctypes.c_void_p(), ctypes.c_uint64()
                        unwind(0, base, base+begin+pc, base+pdata+12*function_index, context,
                               ctypes.byref(handler), ctypes.byref(establisher), None)
                        for offset, expected in [*nonvolatile, (152, entry_sp+8), (160, parent_rbp), (248, parent_rip)]:
                            self.assertEqual(ctypes.c_uint64.from_address(context+offset).value, expected)


if __name__ == "__main__":
    if "--require-native" in sys.argv:
        sys.argv.remove("--require-native")
        if not NATIVE:
            raise SystemExit("--require-native requires native Windows x64")
    if NATIVE:
        ctypes.WinDLL("kernel32").SetErrorMode(0x8003)
    unittest.main(verbosity=2)
