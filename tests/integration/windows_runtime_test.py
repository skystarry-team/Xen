# SPDX-License-Identifier: MIT OR Apache-2.0
"""Actual Xen CLI -> PE -> core runtime, with mandatory native Windows CI.
Linux x86-64 runs identical bytes against an explicit ms_abi service oracle.
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

from windows_test import PE, NATIVE, REPO, XEN

AUXILIARY = sys.platform == "linux" and platform.machine().lower() in ("x86_64", "amd64")
FIXTURE = REPO / "_build/default/tests/windows_runtime_fixture.exe"


class WindowsRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="xen-win-services-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.tools = Path(cls.temp.name)
        if AUXILIARY:
            for source, output, flags in (
                ("windows_runtime_api.c", "api.so", ["-shared", "-fPIC"]),
                ("windows_abi_runner.c", "runner", ["-ldl"]),
            ):
                subprocess.run(["gcc", "-O2", "-Wall", "-Wextra", str(REPO/"tests/fixtures"/source),
                                *flags, "-o", str(cls.tools/output)], check=True)
        if NATIVE:
            compiler = shutil.which("x86_64-w64-mingw32-gcc")
            if not compiler:
                raise RuntimeError("native unwind observer requires the configured MinGW GCC")
            subprocess.run([compiler, "-shared", "-O2", "-static-libgcc",
                            str(REPO/"tests/fixtures/windows_unwind_observer.c"),
                            "-o", str(cls.tools/"xen-unwind-observer.dll")], check=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xen-runtime-공백 😀 ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def invoke(self, *args, **kwargs):
        result = subprocess.run([str(XEN), *map(str, args)], cwd=self.root,
                                capture_output=True, timeout=60, **kwargs)
        result.stdout = result.stdout.replace(b"\r\n", b"\n")
        result.stderr = result.stderr.replace(b"\r\n", b"\n")
        return result

    def build(self, text, opt="off", name="app"):
        source = self.root/(name+".xen")
        source.write_text(text, encoding="utf-8")
        image = self.root/(name+".exe")
        result = self.invoke("build", source, "--target=x86_64-windows", f"--opt={opt}", "-o", image)
        self.assertEqual(result.returncode, 0, result.stderr)
        return source, PE(image)

    def execute(self, pe, *args, env=None):
        if not (NATIVE or AUXILIARY):
            self.skipTest("execution requires native Windows or Linux x86-64 service oracle")
        command = ([str(pe.path)] if NATIVE else
                   [str(self.tools/"runner"), str(pe.path), str(self.tools/"api.so"), "--runtime"])
        environment = dict(os.environ, **(env or {}))
        if AUXILIARY:
            environment["XEN_TEST_RESOURCE_CHECK"] = "1"
        return subprocess.run([*command, *map(str, args)], cwd=self.root, capture_output=True,
                              env=environment, timeout=30)

    def success(self, result, stdout=b""):
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, stdout, b""))

    def test_default_output_and_explicit_cross_target(self):
        source, pe = self.build('fn main(){println("Windows");}')
        self.assertEqual(pe.machine, 0x8664)
        self.assertEqual(set(pe.imports()), {"KERNEL32.dll", "SHELL32.dll"})
        self.assertIn("CreateFileW", pe.imports()["KERNEL32.dll"][0])
        result = self.invoke("build", source, "--target=x86_64-windows")
        self.success(result)
        self.assertTrue((self.root/"a.exe").is_file())
        if NATIVE:
            self.success(self.invoke("build", source))
            self.success(self.invoke("run", source), b"Windows\n")

    def test_unicode_arguments_and_quoting(self):
        args = ["", "공백 있는 값 😀", 'a"b', "C:\\tail\\", "--target=x86_64-linux"]
        text = 'fn main(){println(arg_count());println(arg(0));println(arg(1));println(arg(2));println(arg(3));println(arg(4));}'
        expected = ("5\n"+"\n".join(args)+"\n").encode()
        for opt in ("off", "basic"):
            source, pe = self.build(text, opt)
            self.success(self.execute(pe, *args), expected)
            if NATIVE:
                self.success(self.invoke("run", source, f"--opt={opt}", "--", *args), expected)

    def test_heap_collections_and_float_formatting(self):
        text = ('fn plus(value:Int)->Int{return value+1;} '
                'fn main(){let function=plus;assert(function(41)==42);'
                'let mut a=["하나","둘"];a.push("셋");let b=a;'
                'println(len(b));println("한"+"글");'
                'let mut bytes=[u8(1),u8(2)];bytes.push(u8(3));assert(bytes[2]==u8(3));'
                'println([-0.0,1.25,1e-7,1e17,4.9406564584124654e-324]);}')
        expected = "3\n한글\n[-0, 1.25, 9.9999999999999995e-08, 1e+17, 4.9406564584124654e-324]\n".encode()
        for opt in ("off", "basic"):
            _, pe = self.build(text, opt)
            self.success(self.execute(pe), expected)

    def test_unicode_file_creation_growth_parsing_and_cleanup(self):
        path = self.root/"데이터 😀.txt"
        text = ('fn main(){let mut f=open_write(arg(0));f.write("1 -.5 2. 1e2 -0.0");f.close();'
                'println(read_floats(arg(0)));let mut r=open_read(arg(0));print(r.read());r.close();}')
        for opt in ("off", "basic"):
            _, pe = self.build(text, opt)
            expected = b"[1, -0.5, 2, 100, -0]\n1 -.5 2. 1e2 -0.0"
            self.success(self.execute(pe, path), expected)
            self.assertEqual(path.read_bytes(), b"1 -.5 2. 1e2 -0.0")
            path.unlink()
            payload = b"1 " * 8193
            path.write_bytes(payload)
            _, pe = self.build('fn main(){println(len(read_ints(arg(0))));}', opt)
            self.success(self.execute(pe, path), b"8193\n")
            path.unlink()

    def test_errors_and_empty_file(self):
        for opt in ("off", "basic"):
            for text, message in (
                ('fn main(){read_text(arg(0));}', b"file open failed"),
                ('fn main(){arg(0);}', b"missing program argument"),
                ('fn main(){assert(false);}', b"assertion failed"),
            ):
                _, pe = self.build(text, opt)
                result = self.execute(pe, *([self.root/"missing"] if b"open" in message else []))
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(message, result.stderr)
            path = self.root/"empty"
            path.touch()
            _, pe = self.build('fn main(){println(len(read_text(arg(0))));}', opt)
            self.success(self.execute(pe, path), b"0\n")

    def test_unsupported_features_report_source_spans(self):
        examples = [
            ('#global[bb]\nfn main(){syscall0(1);}', b"raw syscall is not supported"),
            ('#global[bb]\nfn main(){extern_call<Int>("kernel32.dll","GetCurrentProcessId");}', b"extern_call is not implemented"),
        ]
        for text, message in examples:
            source = self.root/"unsupported.xen"
            source.write_text(text)
            output = self.root/"unsupported.exe"
            result = self.invoke("build", source, "--target=x86_64-windows", "-o", output)
            self.assertEqual(result.returncode, 1)
            self.assertIn(message, result.stderr)
            self.assertIn(str(source).encode(), result.stderr)
            self.assertFalse(output.exists())
        source.write_text('use std.fs;fn main(){}')
        result = self.invoke("build", source, "--target=x86_64-windows", "-o", output)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"std.platform", result.stderr)
        self.assertIn(b"x86_64-windows", result.stderr)
        self.assertFalse(output.exists())

    @unittest.skipUnless(NATIVE, "CLI run/test needs a native Windows host")
    def test_native_cli_tests_success_and_failure(self):
        for opt in ("off", "basic"):
            source = self.root/"checks.xen"
            source.write_text('test fn passes(){assert(true);} test fn fails(){assert(false);} fn main(){}')
            self.success(self.invoke("test", source, "--filter", "passes", f"--opt={opt}"),
                         b"PASS checks.passes\n1 passed; 0 failed\n")
            result = self.invoke("test", source, "--filter", "fails", f"--opt={opt}")
            self.assertEqual(result.returncode, 1)
            self.assertIn(b"assertion failed", result.stderr)
            self.assertIn(b"0 passed; 1 failed", result.stdout)

    @unittest.skipUnless(AUXILIARY, "fault injection uses the explicit Linux service oracle")
    def test_service_failures_partial_io_and_broken_pipe(self):
        source, pe = self.build('fn main(){println(len(read_text(arg(0))));}')
        path = self.root/"payload"
        path.write_bytes(b"hello")
        self.success(self.execute(pe, path, env={"XEN_TEST_BROKEN_PIPE":"1"}), b"5\n")
        result = self.execute(pe, path, env={"XEN_TEST_READ_FAIL":"1"})
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"file read failed", result.stderr)
        # Two startup allocations for argc=1: argv table and one UTF-8 string;
        # each conversion is queried and then executed.
        for env, message in (({"XEN_TEST_ALLOC_FAIL":"1"}, b"argument initialization failed"),
                             ({"XEN_TEST_ALLOC_FAIL":"2"}, b"argument initialization failed"),
                             ({"XEN_TEST_CONVERT_FAIL":"1"}, b"argument initialization failed"),
                             ({"XEN_TEST_ALLOC_FAIL":"3"}, b"allocation failed"),
                             ({"XEN_TEST_ALLOC_FAIL":"4"}, b"file open failed"),
                             ({"XEN_TEST_ALLOC_FAIL":"5"}, b"allocation failed"),
                             ({"XEN_TEST_PATH_CONVERT_FAIL":"1"}, b"file open failed"),
                             ({"XEN_TEST_PATH_CONVERT_FAIL":"2"}, b"file open failed"),
                             ({"XEN_TEST_CLOSE_FAIL":"1"}, b"file close failed")):
            result = self.execute(pe, path, env=env)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn(message, result.stderr)
        _, pe = self.build('fn main(){let mut f=open_write(arg(0));f.write("partial write");f.close();}')
        self.success(self.execute(pe, path, env={"XEN_TEST_PARTIAL":"1"}))
        self.assertEqual(path.read_bytes(), b"partial write")
        _, leaked = self.build('#global[bb]\nfn main(){let p=raw_alloc<Int>(1);raw_store(p,0,1);}')
        result = self.execute(leaked)
        self.assertEqual(result.returncode, 90)
        self.assertIn(b"1 allocations, 0 handles", result.stderr)

    def manifest(self, mode="normal", text=None):
        source = self.root/"observed.xen"
        source.write_text(text or 'fn inspect(path:String){print(read_text(path));} fn main(){inspect(arg(0));}')
        image, manifest = self.root/"observed.exe", self.root/"frames.tsv"
        subprocess.run([str(FIXTURE), mode, str(source), str(image), str(manifest)], check=True, timeout=60)
        labels, frames = {}, []
        for line in manifest.read_text().splitlines():
            kind, *values = line.split("\t")
            if kind == "label":
                labels[values[0]] = int(values[1])
            else:
                frames.append(tuple(map(int, values)))
        return PE(image), labels, frames

    def large_aggregate(self):
        # A 16 KiB value without thousands of source fields. This isolates
        # lowering/probing from the checker's cost for a very wide declaration.
        declarations = ['struct L0{value:Int}']
        values = ['let v0=L0{value:42};']
        for i in range(1, 12):
            declarations.append(f'struct L{i}{{left:L{i-1},right:L{i-1}}}')
            values.append(f'let v{i}=L{i}{{left:v{i-1},right:v{i-1}}};')
        return (''.join(declarations)+'fn take(value:L11)->Int{return value'+'.left'*11+'.value;} '
                'fn main(){'+''.join(values)+'let mut values=[v11,v11];'
                'values.push(v11);assert(take(values[2])==42);println(42);}')

    def test_large_aggregate_frames_and_argument_staging(self):
        _, pe = self.build(self.large_aggregate())
        self.success(self.execute(pe), b"42\n")

    @unittest.skipUnless(NATIVE, "actual lowering must probe a fresh native Windows stack")
    def test_native_large_lowered_frame_requires_probes(self):
        pe, labels, frames = self.manifest("thread", self.large_aggregate())
        shutil.copy2(self.tools/"xen-unwind-observer.dll", self.root)
        self.success(self.execute(pe), b"42\n")
        begin, end, _ = next(f for f in frames if f[0]==labels["fn_main"])
        start = pe.file_offset(pe.sections[".text"][0]+begin, end-begin)
        code = pe.data[start:start+end-begin]
        count = code.count(b"\xf6\x04\x24\0")
        self.assertGreater(count, 1)
        damaged = bytearray(pe.data)
        damaged[start:start+len(code)] = code.replace(b"\xf6\x04\x24\0", b"\x90"*4)
        pe.path.write_bytes(damaged)
        result = self.execute(pe)
        self.assertIn(result.returncode & 0xffffffff, (0xc0000005, 0xc00000fd))

    def test_real_lowering_frame_coverage(self):
        pe, labels, frames = self.manifest()
        text_rva = pe.sections[".text"][0]
        pdata, size = pe.directories[3]
        entries = [struct.unpack_from("<III", pe.data, pe.file_offset(pdata+i,12)) for i in range(0,size,12)]
        self.assertEqual([(a-text_rva,b-text_rva) for a,b,_ in entries], sorted((a,b) for a,b,_ in frames))
        by_begin = {a-text_rva:info for a,_,info in entries}
        for name in ("fn_main", "fn_inspect", "__xen_read_builtin", "__xen_file_read",
                     "__xen_print_float", "__xen_numeric_parse_float", "__xen_win_read"):
            self.assertIn(labels[name], by_begin, name)
        self.assertGreater(len(entries), 70)

    @unittest.skipUnless(NATIVE, "GP/XMM restoration requires Windows RtlVirtualUnwind")
    def test_native_source_and_helper_nonvolatile_register_unwind(self):
        pe, labels, frames = self.manifest()
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.LoadLibraryExW.argtypes = [ctypes.c_wchar_p, ctypes.c_void_p, ctypes.c_uint32]
        kernel.LoadLibraryExW.restype = ctypes.c_void_p
        kernel.FreeLibrary.argtypes = [ctypes.c_void_p]
        base = kernel.LoadLibraryExW(str(pe.path), None, 1)
        self.assertTrue(base, ctypes.get_last_error())
        self.addCleanup(kernel.FreeLibrary, base)
        unwind = ctypes.WinDLL("ntdll").RtlVirtualUnwind
        unwind.argtypes = [ctypes.c_uint32, ctypes.c_uint64, ctypes.c_uint64, ctypes.c_void_p,
                           ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
        text_rva = pe.sections[".text"][0]
        pdata, size = pe.directories[3]
        records = {pe.u32(pe.file_offset(pdata+i, 12))-text_rva:pdata+i for i in range(0, size, 12)}
        bounds = {a:(b,c) for a,b,c in frames}
        gp_offsets = [120,128,136,144,152,160,168,176,184,192,200,208,216,224,232,240]
        saved_gp = [5,3,7,6,12,13,14,15]
        for name in ("fn_main", "fn_inspect", "__xen_read_builtin", "__xen_file_read",
                     "__xen_print_int", "__xen_print_float", "__xen_numeric_parse_float"):
            begin = labels[name]
            end, prolog = bounds[begin]
            record = records[begin]
            info = pe.u32(pe.file_offset(record+8,4))
            frame_register = pe.data[pe.file_offset(info+3,1)] & 15
            # Independent contexts at every prolog operation, in the body,
            # during XMM restoration, and after every canonical epilog pop.
            cases = [(pc, count, False, False, 0, 10, 0, False)
                     for count,pc in enumerate((0,1,2,3,4,6,8,10,12))]
            cases += [(19,8,True,False,0,10,0,False), (22,8,True,True,0,10,0,False)]
            cases += [(22+10*n,8,True,True,n,10,0,False) for n in range(1,11)]
            cases += [(prolog,8,True,True,10,0,0,True)]
            load_size = 10 if frame_register==12 else 9
            lea_size = 8 if frame_register==12 else 7
            lea_pc = end-begin-13-lea_size
            cases += [(lea_pc-10*load_size+i*load_size,8,True,True,10,i,0,True)
                      for i in range(11)]
            pop_sizes = [2,2,2,2,1,1,1,1]
            cases += [(lea_pc+lea_size+sum(pop_sizes[:n]),8,True,True,10,10,n,True)
                      for n in range(9)]
            for pc,pushed,allocated,established,saved_fp,loaded_fp,popped,body in cases:
                with self.subTest(function=name, pc=pc):
                    stack = ctypes.create_string_buffer(0x20000)
                    fixed = (ctypes.addressof(stack)+0x10000) & ~15
                    ctypes.memset(fixed,0xdd,0x1000)
                    context_storage = ctypes.create_string_buffer(1232+15)
                    context = (ctypes.addressof(context_storage)+15) & ~15
                    ctypes.c_uint32.from_address(context+48).value = 0x10000b  # CONTEXT_AMD64 | FULL
                    popped_regs = list(reversed(saved_gp))[:popped]
                    for r in saved_gp:
                        value = 0x22220000+r if body else 0x11110000+r
                        if r in popped_regs:
                            value = 0x11110000+r
                        if established and r==frame_register and r not in popped_regs:
                            value = fixed
                        ctypes.c_uint64.from_address(context+gp_offsets[r]).value = value
                    for i,r in enumerate(saved_gp[:pushed]):
                        ctypes.c_uint64.from_address(fixed+224-8*i).value = 0x11110000+r
                    ctypes.c_uint64.from_address(fixed+232).value = 0x12345678
                    for i,r in enumerate(range(6,16)):
                        value = struct.pack("<QQ",0x33330000+r,0x44440000+r)
                        if i<saved_fp:
                            ctypes.memmove(fixed+16*i,value,16)
                        ctypes.memmove(context+416+16*r,value if i<loaded_fp else bytes([0x55])*16,16)
                    sp = fixed+232-8*pushed-(168 if allocated else 0)
                    if body:
                        sp = fixed+168+8*popped if pc>=lea_pc+lea_size else fixed-512
                    ctypes.c_uint64.from_address(context+152).value = sp
                    address = base+text_rva+begin+pc
                    ctypes.c_uint64.from_address(context+248).value = address
                    handler, establisher = ctypes.c_void_p(), ctypes.c_uint64()
                    unwind(0,base,address,base+record,context,ctypes.byref(handler),ctypes.byref(establisher),None)
                    for r in saved_gp:
                        self.assertEqual(ctypes.c_uint64.from_address(context+gp_offsets[r]).value,0x11110000+r)
                    self.assertEqual(ctypes.c_uint64.from_address(context+152).value,fixed+240)
                    self.assertEqual(ctypes.c_uint64.from_address(context+248).value,0x12345678)
                    for r in range(6,16):
                        self.assertEqual(ctypes.string_at(context+416+16*r,16),struct.pack("<QQ",0x33330000+r,0x44440000+r))


        # SAVE_NONVOL services use a different fixed area and FP+240. Check
        # their partial prolog, stores, dynamic body and canonical epilog too.
        begin = labels["__xen_win_read"]
        end, prolog = bounds[begin]
        record = records[begin]
        info = pe.u32(pe.file_offset(record+8,4))
        self.assertEqual(pe.data[pe.file_offset(info+3,1)],0xf5)
        stores = [2,3,6,7,8,9,10,12,13,14,15]
        nonvolatile = [3,5,6,7,12,13,14,15]
        cases = [(0,False,False,False,0,0,False,0),
                 (1,True,False,False,0,0,False,0),
                 (8,True,True,False,0,0,False,0),
                 (16,True,True,True,0,0,False,0)]
        cases += [(16+7*n,True,True,True,n,0,False,0) for n in range(1,12)]
        cases += [(prolog,True,True,True,11,0,True,0)]
        cases += [(end-begin-83+7*n,True,True,True,11,n,True,0) for n in range(12)]
        cases += [(end-begin-2,True,True,True,11,11,True,1),
                  (end-begin-1,True,True,True,11,11,True,2)]
        for pc,pushed,allocated,established,saved,loaded,body,epilog in cases:
            with self.subTest(function="__xen_win_read", pc=pc):
                stack = ctypes.create_string_buffer(0x20000)
                fixed = (ctypes.addressof(stack)+0x10000) & ~15
                ctypes.memset(fixed,0xdd,0x1000)
                storage = ctypes.create_string_buffer(1232+15)
                context = (ctypes.addressof(storage)+15) & ~15
                ctypes.c_uint32.from_address(context+48).value = 0x10000b
                for r in nonvolatile:
                    value = 0x22220000+r if body and r not in stores[:loaded] else 0x11110000+r
                    if r==5:
                        value = fixed+240 if established and epilog!=2 else 0x11110005
                    ctypes.c_uint64.from_address(context+gp_offsets[r]).value = value
                if pushed:
                    ctypes.c_uint64.from_address(fixed+256).value = 0x11110005
                for r in stores[:saved]:
                    ctypes.c_uint64.from_address(fixed+240-8*(r+1)).value = 0x11110000+r
                ctypes.c_uint64.from_address(fixed+264).value = 0x12345678
                for r in range(6,16):
                    ctypes.memmove(context+416+16*r,struct.pack("<QQ",0x33330000+r,0x44440000+r),16)
                sp = fixed+264-(8 if pushed else 0)-(256 if allocated else 0)
                if body:
                    sp = fixed-512 if epilog==0 else fixed+248+8*epilog
                ctypes.c_uint64.from_address(context+152).value = sp
                address = base+text_rva+begin+pc
                ctypes.c_uint64.from_address(context+248).value = address
                handler, establisher = ctypes.c_void_p(), ctypes.c_uint64()
                unwind(0,base,address,base+record,context,ctypes.byref(handler),ctypes.byref(establisher),None)
                for r in nonvolatile:
                    self.assertEqual(ctypes.c_uint64.from_address(context+gp_offsets[r]).value,0x11110000+r)
                self.assertEqual(ctypes.c_uint64.from_address(context+152).value,fixed+272)
                self.assertEqual(ctypes.c_uint64.from_address(context+248).value,0x12345678)
                for r in range(6,16):
                    self.assertEqual(ctypes.string_at(context+416+16*r,16),struct.pack("<QQ",0x33330000+r,0x44440000+r))

    @unittest.skipUnless(NATIVE, "actual runtime call-chain unwind requires Windows RtlVirtualUnwind")
    def test_native_unwind_through_file_runtime_and_service(self):
        pe, labels, frames = self.manifest("observe")
        shutil.copy2(self.tools/"xen-unwind-observer.dll", self.root)
        code_rva = pe.sections[".text"][0]
        # Identify the observer bridge through its independent IAT displacement.
        _, iat = pe.imports()["xen-unwind-observer.dll"]
        bridge = None
        for begin, end, _ in frames:
            code = pe.data[pe.file_offset(code_rva+begin, end-begin):][:end-begin]
            for at in range(len(code)-5):
                if code[at:at+2]==b"\xff\x15" and code_rva+begin+at+6+struct.unpack_from("<i",code,at+2)[0]==iat:
                    bridge = begin
        self.assertIsNotNone(bridge)
        expected = [bridge, *[labels[n] for n in
                    ("__xen_win_read", "__xen_read_builtin", "fn_inspect", "fn_main", "_start")]]
        path = self.root/"observe.txt"
        path.write_bytes(b"observed\n")
        self.success(self.execute(pe, path, env={"XEN_TEST_UNWIND_FRAMES":",".join(str(code_rva+n) for n in expected)}), b"observed\n")

    @unittest.skipUnless(NATIVE, "formatter frame alignment requires native Windows observation")
    def test_native_float_vector_call_alignment_and_unwind(self):
        pe, labels, _ = self.manifest("write-observe", 'fn main(){println([1.25,2.5]);}')
        shutil.copy2(self.tools/"xen-unwind-observer.dll", self.root)
        self.success(self.execute(pe, env={"XEN_TEST_FLOAT_FRAME":str(pe.sections[".text"][0]+labels["__xen_print_float"])}),
                     b"[1.25, 2.5]\n")


if __name__ == "__main__":
    if "--require-native" in sys.argv:
        sys.argv.remove("--require-native")
        if not NATIVE:
            raise SystemExit("native Windows AMD64 runtime execution is required")
    if NATIVE:
        ctypes.windll.kernel32.SetErrorMode(0x8003)
    unittest.main(verbosity=2)
