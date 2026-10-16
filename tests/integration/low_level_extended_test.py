# SPDX-License-Identifier: MIT OR Apache-2.0
"""Multiple asm outputs, C ABI/linking and atomics under real contention."""
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
import low_level_test as low


class ExtendedLowLevelTests(unittest.TestCase):
    build = low.LowLevelTests.build
    success = low.LowLevelTests.success

    @classmethod
    def setUpClass(cls):
        cls.fixtures = tempfile.TemporaryDirectory(prefix="xen-ffi-fixtures-")
        cls.addClassCleanup(cls.fixtures.cleanup)
        cls.libraries = {}
        fixture = low.ROOT / "tests/fixtures/ffi"
        for target in low.TARGETS:
            root = Path(cls.fixtures.name) / target
            root.mkdir()
            output = root / "libxen_ffi_test.so"
            if target.startswith("x86"):
                if not shutil.which("gcc"):
                    continue
                command = ["gcc", "-shared", "-fPIC", "-O2", "-pthread", str(fixture / "interop.c"),
                           "-Wl,-soname,libxen_ffi_test.so", "-o", str(output)]
                subprocess.run(command, check=True, capture_output=True, text=True)
            else:
                if (not shutil.which("aarch64-linux-gnu-as") or not shutil.which("aarch64-linux-gnu-ld")
                        or not Path("/usr/lib/aarch64-linux-gnu/libc.so.6").exists()):
                    continue
                obj = root / "interop.o"
                subprocess.run(["aarch64-linux-gnu-as", str(fixture / "interop_aarch64.s"), "-o", str(obj)],
                               check=True, capture_output=True, text=True)
                subprocess.run(["aarch64-linux-gnu-ld", "-shared", str(obj), "-o", str(output),
                                "-soname", "libxen_ffi_test.so", "-L/usr/lib/aarch64-linux-gnu", "-l:libc.so.6"],
                               check=True, capture_output=True, text=True)
            cls.libraries[target] = output

    def setUp(self):
        low.LowLevelTests.setUp(self)

    def run_binary(self, output, target):
        if target.startswith("aarch64"):
            if 3 not in self.program_headers(output):
                return low.LowLevelTests.run_binary(self, output, target)
            loader = Path("/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1")
            if not loader.exists() or not shutil.which("qemu-aarch64"):
                self.skipTest("AArch64 execution requires qemu and the target dynamic loader")
            command = [shutil.which("qemu-aarch64"), str(loader), "--library-path", str(loader.parent), str(output)]
            return subprocess.run(command, capture_output=True, text=True, timeout=30)
        return low.LowLevelTests.run_binary(self, output, target)

    def use_library(self, target):
        if target not in self.libraries:
            self.skipTest("C ABI fixture toolchain is unavailable for " + target)
        link = self.root / "libxen_ffi_test.so"
        link.unlink(missing_ok=True)
        link.symlink_to(self.libraries[target])

    @staticmethod
    def program_headers(output):
        data = output.read_bytes()
        offset = struct.unpack_from("<Q", data, 32)[0]
        size, count = struct.unpack_from("<HH", data, 54)
        return [struct.unpack_from("<I", data, offset + i * size)[0] for i in range(count)]

    def test_asm_multiple_outputs_aliases_and_flags(self):
        for target in low.TARGETS:
            if target.startswith("x86"):
                body = ('let (a,b,c,d)=id(asm<U8,I16,U32,U64>('
                        '"mov al,255;mov cx,-128;mov r8d,4294967295;mov rdi,42",'
                        'out("al"),out("cx"),out("r8d"),out("rdi")));'
                        'assert(a==u8(255));assert(b==i16(-128));assert(c==u32(4294967295));assert(d==u64(42));'
                        'let (e,f,g)=asm<Int,Int,Int>("mov rcx,44;mov rax,43;mov rdi,42",'
                        'out("rdi"),out("rax"),out("rcx"));assert(e==42 && f==43 && g==44);'
                        'assert(asm<U64>("mov eax,4294967295;mov r8,rax",out("r8"),clobber("rax"))==u64(4294967295));'
                        'let (lo,hi)=asm<U32,U32>("rdtsc",out("eax"),out("edx"));assert(lo>=u32(0) && hi>=u32(0));')
                for condition, lhs, rhs, expected in [("l", -1, 1, 1), ("a", -1, 1, 1), ("e", 1, 1, 1), ("ne", 1, 1, 0)]:
                    body += (f'assert(asm<U8>("cmp r8d,r9d;set{condition} al",in("r8d",i32({lhs})),'
                             f'in("r9d",i32({rhs})),out("al"))==u8({expected}));')
            else:
                body = ('let (a,b,c,d)=id(asm<U8,I16,U32,U64>('
                        '"mov w0,#255;mov w1,#-128;mov w8,#4294967295;mov x14,#42",'
                        'out("w0"),out("w1"),out("w8"),out("x14")));'
                        'assert(a==u8(255));assert(b==i16(-128));assert(c==u32(4294967295));assert(d==u64(42));'
                        'let (e,f,g)=asm<Int,Int,Int>("mov x1,#44;mov x0,#43;mov x14,#42",'
                        'out("x14"),out("x0"),out("x1"));assert(e==42 && f==43 && g==44);'
                        'assert(asm<U64>("mov w0,#4294967295;mov x8,x0",out("x8"),clobber("x0"))==u64(4294967295));')
                for condition, lhs, rhs, expected in [("lt", -1, 1, 1), ("hi", -1, 1, 1), ("eq", 1, 1, 1), ("ne", 1, 1, 0)]:
                    body += (f'assert(asm<U32>("cmp w8,w9;cset w0,{condition}",in("w8",i32({lhs})),'
                             f'in("w9",i32({rhs})),out("w0"))==u32({expected}));')
            for opt in ("off", "basic"):
                with self.subTest(target=target, opt=opt):
                    self.success('fn id<T>(x:T)->T{return x;}fn main(){#scope[bb,opt]{asm<Unit>("nop");' +
                                 body + "println(42);}}", target, opt=opt)

    def test_asm_small_memory_and_integer_widths(self):
        for target in low.TARGETS:
            if target.startswith("x86"):
                body = ('assert(asm<U8>("add r8b,r9b",inout("r8b",u8(17)),in("r9b",u8(25)))==u8(42));'
                        'assert(asm<I16>("add r8w,50",inout("r8w",i16(-8)))==i16(42));'
                        'assert(asm<U32>("shl r8d,1",inout("r8d",u32(21)))==u32(42));'
                        'assert(asm<U32>("mov byte [rdi+1],r8b;movzx eax,byte [rdi+1]",'
                        'in("rdi",ptr_addr(p)),in("r8b",u8(42)),out("eax"))==u32(42));'
                        'assert(asm<Int>("mov word [rdi+3],r8w;movsx rax,word [rdi+3]",'
                        'in("rdi",ptr_addr(p)),in("r8w",i16(-32768)),out("rax"))==-32768);'
                        'assert(asm<I32>("mov dword [rdi+8],r8d;mov eax,[rdi+8]",'
                        'in("rdi",ptr_addr(p)),in("r8d",i32(-2147483648)),out("eax"))==i32(-2147483648));')
            else:
                body = ('assert(asm<U8>("add w8,w8,w9",inout("w8",u8(17)),in("w9",u8(25)))==u8(42));'
                        'assert(asm<I16>("add w8,w8,#50",inout("w8",i16(-8)))==i16(42));'
                        'assert(asm<U32>("lsl w8,w8,#1",inout("w8",u32(21)))==u32(42));'
                        'assert(asm<U32>("strb w8,[x14,#1];ldrb w0,[x14,#1]",'
                        'in("x14",ptr_addr(p)),in("w8",u8(42)),out("w0"))==u32(42));'
                        'assert(asm<Int>("sturh w8,[x14,#3];ldurh w0,[x14,#3];sxth x0,w0",'
                        'in("x14",ptr_addr(p)),in("w8",i16(-32768)),out("x0"))==-32768);'
                        'assert(asm<I32>("str w8,[x14,#8];ldr w0,[x14,#8]",'
                        'in("x14",ptr_addr(p)),in("w8",i32(-2147483648)),out("w0"))==i32(-2147483648));')
            for opt in ("off", "basic"):
                with self.subTest(target=target, opt=opt):
                    self.success("fn main(){#scope[bb,opt]{let p=raw_alloc<U8>(32);" + body +
                                 "assert(raw_load(p,1)==u8(42));raw_free(p);println(42);}}", target, opt=opt)

    def test_atomic_all_integer_widths_and_wrapping(self):
        body = ""
        for typ, minimum, maximum in [("I8", -128, 127), ("U8", 0, 255), ("I16", -32768, 32767),
                                      ("U16", 0, 65535), ("I32", -2147483648, 2147483647),
                                      ("U32", 0, 4294967295), ("I64", -9223372036854775808, 9223372036854775807),
                                      ("U64", 0, 18446744073709551615)]:
            body += (f"{{let p=raw_alloc<{typ}>(2);atomic_store(p,1,1,\"release\");"
                     "assert(atomic_load(p,1,\"acquire\")==1);assert(atomic_fetch_add(p,1,41)==1);"
                     "assert(atomic_exchange(p,1,7)==42);assert(atomic_compare_exchange(p,1,8,9,\"acq_rel\",\"acquire\")==7);"
                     "assert(atomic_compare_exchange(p,1,7,42)==7);assert(atomic_fetch_sub(p,1,2)==42);"
                     "assert(atomic_fetch_or(p,1,2)==40);assert(atomic_fetch_and(p,1,15)==42);"
                     "assert(atomic_fetch_xor(p,1,32)==10);assert(atomic_load(p,1)==42);"
                     f"atomic_store(p,1,{maximum});assert(atomic_fetch_add(p,1,1)=={maximum});"
                     f"assert(atomic_load(p,1)=={minimum});atomic_store(p,1,{minimum});"
                     f"assert(atomic_compare_exchange(p,1,{minimum},42)=={minimum});"
                     "assert(atomic_load(p,1)==42);raw_free(p);}")
        source = ("#global[bb]\nfn get<T>(p:Ptr<T>)->T{return atomic_load<T>(p,1,\"relaxed\");}"
                  "fn main(){#scope[opt]{" + body + "let p=raw_alloc<Int>(2);atomic_store(p,1,42);"
                  "assert(get(p)==42);raw_free(p);println(42);}}")
        for target in low.TARGETS:
            for opt in ("off", "basic"):
                with self.subTest(target=target, opt=opt):
                    self.success(source, target, opt=opt)

    def test_c_abi_libraries_scalars_pointer_and_lifecycle(self):
        library = '"libxen_ffi_test.so"'
        calls = ('assert(extern_call<I32>(' + library + ',"init_value")==i32(42));'
                 'assert(extern_call<Int>(' + library + ',"sum6",1,2,3,4,5,27)==42);'
                 'assert(extern_call<F64>(' + library + ',"mixed",i8(-2),f32(1.5),u32(30),4.5,5,f32(3.0))==42.0);'
                 'assert(extern_call<F32>(' + library + ',"small_float",f32(44.5),i16(-2))==f32(42.5));')
        for typ, symbol, expected in [("I8", "signed_byte", -128), ("U8", "unsigned_byte", 255),
                                      ("I16", "signed_half", -32768), ("U16", "unsigned_half", 65535),
                                      ("I32", "signed_word", -2147483648), ("U32", "unsigned_word", 4294967295)]:
            calls += f'assert(extern_call<{typ}>({library},"{symbol}")=={typ.lower()}({expected}));'
        calls += ('let p=raw_alloc<Int>(1);extern_call<Unit>(' + library + ',"store_value",p,42);'
                  'assert(volatile_load(p,0)==42);raw_free(p);'
                  'let address=extern_call<Int>("libc.so.6","malloc",u64(8));assert(address!=0);'
                  'let bytes=ptr_from_addr<U8>(address,8);'
                  'assert(extern_call<Int>("libc.so.6","memset",bytes,i32(42),u64(8))==address);'
                  'assert(volatile_load(bytes,7)==u8(42));extern_call<Unit>("libc.so.6","free",bytes);'
                  'assert(extern_call<F64>("libm.so.6","sqrt",1764.0)==42.0);'
                  'let text=raw_alloc<U8>(3);raw_store(text,0,u8(52));raw_store(text,1,u8(50));raw_store(text,2,u8(0));'
                  'extern_call<I32>("libc.so.6","puts",text);raw_free(text);'
                  'extern_call<Unit>(' + library + ',"mark_exit");')
        for target in low.TARGETS:
            self.use_library(target)
            for opt in ("off", "basic"):
                with self.subTest(target=target, opt=opt):
                    # DSO finalization writes directly; libc flushes buffered puts at exit.
                    self.success("fn main(){#scope[bb,opt]{" + calls + "}}", target, expected="bye\n42\n", opt=opt)

    def test_atomic_access_instructions_and_unused_results(self):
        # Fixed reference bytes from GNU as, not derived from the Xen emitter.
        x86 = {
            1: ("8607", "f00fc00f", "f00fb017"),
            2: ("668707", "66f00fc10f", "66f00fb117"),
            4: ("8707", "f00fc10f", "f00fb117"),
            8: ("488707", "f0480fc10f", "f0480fb117"),
        }
        arm = {
            1: ("20fddf08", "21fd9f08", "20fd5f08", "21fd0308"),
            2: ("20fddf48", "21fd9f48", "20fd5f48", "21fd0348"),
            4: ("20fddf88", "21fd9f88", "20fd5f88", "21fd0388"),
            8: ("20fddfc8", "21fd9fc8", "20fd5fc8", "21fd03c8"),
        }
        for target in low.TARGETS:
            marker = ('asm("mov r11,123456789",clobber("r11"));' if target.startswith("x86")
                      else 'asm("mov x14,#123456789",clobber("x14"));')
            boundary = bytes.fromhex("49bb15cd5b0700000000" if target.startswith("x86")
                                     else "aea299d26eeba0f20e00c0f20e00e0f2")
            for typ, width in [("U8", 1), ("U16", 2), ("U32", 4), ("U64", 8)]:
                source = (f"fn main(){{#scope[bb,opt]{{let p=raw_alloc<{typ}>(1);" + marker +
                          "atomic_store(p,0,1);atomic_load(p,0);atomic_exchange(p,0,2);"
                          "atomic_fetch_add(p,0,1);atomic_compare_exchange(p,0,3,4);atomic_fetch_or(p,0,1);" + marker +
                          "assert(atomic_load(p,0)==5);raw_free(p);println(42);}}")
                for opt in ("off", "basic"):
                    with self.subTest(target=target, width=width, opt=opt):
                        built, output = self.build(source, target, opt)
                        self.assertEqual(built.returncode, 0, built.stderr)
                        pieces = output.read_bytes().split(boundary)
                        self.assertEqual(len(pieces), 3)
                        code = pieces[1]
                        if target.startswith("x86"):
                            exchange, add, cas = map(bytes.fromhex, x86[width])
                            # Include the opcode prefix to distinguish narrower instructions.
                            self.assertEqual(code.count(add), 1)
                            self.assertEqual(code.count(cas), 2)
                            self.assertGreaterEqual(code.count(exchange), 2)
                        else:
                            load, store, exclusive, exchange = map(bytes.fromhex, arm[width])
                            self.assertEqual(code.count(load), 1)
                            self.assertEqual(code.count(store), 1)
                            self.assertEqual(code.count(exclusive), 4)
                            self.assertEqual(code.count(exchange), 1)
                            self.assertEqual(code.count(bytes.fromhex("5f3f03d5")), 1)
                        actual = self.run_binary(output, target)
                        self.assertEqual((actual.returncode, actual.stdout, actual.stderr), (0, "42\n", ""))

    def test_atomic_contention_and_release_acquire_with_c_threads(self):
        source = ('fn main(){#scope[bb,opt]{let p=raw_alloc<U64>(2);'
                  'atomic_store(p,0,0);assert(extern_call<I32>("libxen_ffi_test.so","start_worker",p,u64(20000),i32(0))==i32(0));'
                  'let mut i=0;while i<20000{atomic_fetch_add(p,0,1,"relaxed");i=i+1;}'
                  'assert(extern_call<Int>("libxen_ffi_test.so","join_worker")==0);assert(atomic_load(p,0)==40000);'
                  'atomic_store(p,0,0);assert(extern_call<I32>("libxen_ffi_test.so","start_worker",p,u64(20000),i32(0))==i32(0));'
                  'i=0;while i<20000{let mut old=atomic_load(p,0,"relaxed");let mut done=false;while !done{'
                  'let seen=atomic_compare_exchange(p,0,old,old+1,"acq_rel","acquire");'
                  'if seen==old{done=true;}else{old=seen;}}i=i+1;}'
                  'assert(extern_call<Int>("libxen_ffi_test.so","join_worker")==0);assert(atomic_load(p,0)==40000);'
                  'atomic_store(p,0,0);assert(extern_call<I32>("libxen_ffi_test.so","start_worker",p,u64(0),i32(1))==i32(0));'
                  'volatile_store(p,1,42);atomic_store(p,0,1,"release");'
                  'assert(extern_call<Int>("libxen_ffi_test.so","join_worker")==42);'
                  'atomic_store(p,0,0);volatile_store(p,1,0);'
                  'assert(extern_call<I32>("libxen_ffi_test.so","start_worker",p,u64(0),i32(2))==i32(0));'
                  'while atomic_load(p,0,"acquire")==0{cpu_relax();}assert(volatile_load(p,1)==42);'
                  'assert(extern_call<Int>("libxen_ffi_test.so","join_worker")==0);raw_free(p);println(42);}}')
        for target in low.TARGETS:
            self.use_library(target)
            for opt in ("off", "basic"):
                with self.subTest(target=target, opt=opt):
                    self.success(source, target, opt=opt)

    def test_dynamic_elf_metadata_and_static_compatibility(self):
        for target in low.TARGETS:
            built, output = self.build('fn main(){#scope[bb]{println(extern_call<I32>("libc.so.6","abs",i32(-42)));}}', target)
            self.assertEqual(built.returncode, 0, built.stderr)
            self.assertTrue({3, 6, 2}.issubset(set(self.program_headers(output))))
            if shutil.which("readelf"):
                result = subprocess.run(["readelf", "-W", "-d", "-l", str(output)], capture_output=True, text=True, check=True)
                self.assertIn("libc.so.6", result.stdout)
                for tag in ("SYMTAB", "STRTAB", "HASH", "RELA", "BIND_NOW", "RUNPATH"):
                    self.assertIn(tag, result.stdout)
            self.success('fn main(){#scope[bb]{let p=raw_alloc<Int>(1);atomic_store(p,0,42);'
                         'println(atomic_load(p,0));raw_free(p);}}', target)
            self.assertNotIn(3, self.program_headers(self.root / "program"))
            self.assertNotIn(2, self.program_headers(self.root / "program"))

    def test_interpreter_entry_program_arguments_and_evaluation_order(self):
        source = ('#global[bb]\nfn value(n:Int)->Int{println(n);return n;}'
                  'fn main(){assert(extern_call<I32>("libxen_ffi_test.so","init_value")==i32(42));'
                  'println(extern_call<Int>("libxen_ffi_test.so","sum6",'
                  'value(1),value(2),value(3),value(4),value(5),value(27)));'
                  'println(arg_count());println(arg(0));println(arg(1));'
                  'extern_call<Unit>("libxen_ffi_test.so","mark_exit");}')
        expected = "1\n2\n3\n4\n5\n27\n42\n2\nhello\ntwo words\nbye\n"
        for target in low.TARGETS:
            self.use_library(target)
            if target.startswith("aarch64"):
                qemu = shutil.which("qemu-aarch64")
                loader = Path("/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1")
                if not qemu or not loader.exists():
                    self.skipTest("PT_INTERP execution requires qemu and target glibc")
                lib = self.root / "sysroot/lib"
                lib.mkdir(parents=True)
                (lib / "ld-linux-aarch64.so.1").symlink_to(loader)
                runner = [qemu, "-L", str(lib.parent), "-E", "LD_LIBRARY_PATH=" + str(loader.parent)]
            else:
                runner = []
            for opt in ("off", "basic"):
                with self.subTest(target=target, opt=opt):
                    built, output = self.build(source, target, opt)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    actual = subprocess.run([*runner, str(output), "hello", "two words"],
                                            capture_output=True, text=True, timeout=30)
                    self.assertEqual((actual.returncode, actual.stdout, actual.stderr), (0, expected, ""))

    def test_rejected_atomic_and_c_abi_contracts(self):
        cases = [
            ('fn main(){let p=1;atomic_load(p,0);}', "requires #![bb]"),
            ('fn main(){extern_call<I32>("libc.so.6","getpid");}', "requires #![bb]"),
            ('let p=raw_alloc<F32>(1);atomic_load(p,0);', "integer scalar"),
            ('let p=raw_alloc<Bool>(1);atomic_store(p,0,true);', "integer scalar"),
            ('let p=raw_alloc<Int>(1);atomic_load(p,0,"release");', "cannot be release"),
            ('let p=raw_alloc<Int>(1);atomic_store(p,0,1,"acquire");', "cannot be acquire"),
            ('let p=raw_alloc<Int>(1);atomic_compare_exchange(p,0,1,2,"relaxed","acquire");', "stronger than success"),
            ('let p=raw_alloc<Int>(1);atomic_compare_exchange(p,0,1,2,"seq_cst","release");', "failure order cannot"),
            ('let p=raw_alloc<Int>(1);atomic_load(p,0,"consume");', "unknown atomic memory order"),
            ('let p=raw_alloc<Int>(1);let order="relaxed";atomic_load(p,0,order);', "string literal"),
            ('extern_call("libc.so.6","getpid");', "explicit result type"),
            ('extern_call<String>("libc.so.6","getpid");', "numeric scalar or Unit"),
            ('extern_call<I32>("libc.so.6","puts","x");', "numeric scalars or Ptr"),
            ('extern_call<I32>("libc.so.6","bad-name");', "C symbol"),
            ('extern_call<I32>("libc.so.6","getpid",1,2,3,4,5,6,7);', "six"),
            ('extern_call<I32>("libc.so.6","abs",i32(1));extern_call<I64>("libc.so.6","abs",i32(1));', "conflicting"),
            ('extern_call<I32>("libc.so.6","abs",i32(1));extern_call<I32>("other.so","abs",i32(1));', "conflicting"),
        ]
        for target in low.TARGETS:
            for body, message in cases:
                with self.subTest(target=target, body=body):
                    source = body if body.startswith("fn ") else "fn main(){#scope[bb]{" + body + "}}"
                    built, _ = self.build(source, target)
                    self.assertNotEqual(built.returncode, 0)
                    self.assertIn(message, built.stderr)
                    self.assertIn("app.xen:", built.stderr)
            for op in ("atomic_load(p,-1);", "atomic_store(p,1,1);", "atomic_compare_exchange(p,1,1,2);"):
                built, output = self.build("fn main(){#scope[bb]{let p=raw_alloc<Int>(1);" + op + "}}", target)
                self.assertEqual(built.returncode, 0, built.stderr)
                actual = self.run_binary(output, target)
                self.assertNotEqual(actual.returncode, 0)
                self.assertIn("bounds", actual.stderr)

    def test_rejected_asm_alias_initialization_and_flags(self):
        cases = {
            "x86_64-linux": [
                ('asm("nop",in("rax",1),in("eax",i32(2)));', "overlapping register aliases"),
                ('asm<U8,U64>("mov rax,1",out("al"),out("rax"));', "overlapping register aliases"),
                ('asm<U64>("mov al,1;mov r8,rax",out("r8"),clobber("rax"));', "uninitialized register"),
                ('asm<U64>("mov ax,1;mov r8,rax",out("r8"),clobber("rax"));', "uninitialized register"),
                ('asm<U8>("sete al",out("al"));', "condition flags"),
                ('asm<U8>("add r8,1;sete al",inout("r8",1),out("al"));', "output type count"),
                ('asm<U8>("mov al,1",inout("al",1));', "input type exceeds"),
                ('asm<U64>("mov al,1",out("al"));', "output type exceeds"),
                ('asm<U8>("mov ah,1",out("al"));', "unsupported"),
                ('asm<U32>("mov eax,ax",inout("eax",u32(1)));', "widths differ"),
                ('asm<U8>("mov al,byte [ecx]",in("ecx",u32(0)),out("al"));', "64-bit register"),
                ('asm<I64,U8>("add r8,1;sete al",inout("r8",1),out("al"));', "condition flags"),
                ('asm<I64,U8>("imul r8,2;sete al",inout("r8",1),out("al"));', "condition flags"),
            ],
            "aarch64-linux": [
                ('asm("nop",in("x0",1),in("w0",i32(2)));', "overlapping register aliases"),
                ('asm<U32,U64>("mov x0,#1",out("w0"),out("x0"));', "overlapping register aliases"),
                ('asm<U64>("mov x8,x0",in("w0",u32(1)),out("x8"));', "uninitialized register"),
                ('asm<U32>("cset w0,eq",out("w0"));', "condition flags"),
                ('asm<U32>("mov w0,w1",in("w1",1),out("w0"));', "input type exceeds"),
                ('asm<U64>("mov w0,#1",out("w0"));', "output type exceeds"),
                ('asm<U32>("add w0,w1,x2",in("w1",u32(1)),in("x2",2),out("w0"));', "widths differ"),
                ('asm<U32>("ldrb w0,[w1]",in("w1",u32(0)),out("w0"));', "x register"),
            ],
        }
        for target, examples in cases.items():
            for body, message in examples:
                with self.subTest(target=target, body=body):
                    built, _ = self.build("fn main(){#scope[bb]{" + body + "}}", target)
                    self.assertNotEqual(built.returncode, 0)
                    self.assertIn(message, built.stderr)
                    self.assertIn("app.xen:", built.stderr)


if __name__ == "__main__":
    unittest.main()
