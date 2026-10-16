# SPDX-License-Identifier: MIT OR Apache-2.0
"""bb low-level contracts, effect preservation and target-owned encodings."""
import os
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
XEN = ROOT / "compiler/dist/xen"
TARGETS = ("x86_64-linux", "aarch64-linux")
REGS = {"x86_64-linux": ("rax", "rcx", "r8", "r11"),
        "aarch64-linux": ("x0", "x1", "x8", "x14")}


class LowLevelTests(unittest.TestCase):
    def test_asm_stack_and_extended_registers(self):
        subprocess.run(["dune", "build", "tests/asm_abi_fixture.exe"], cwd=ROOT, check=True,
                       capture_output=True, text=True)
        for target in TARGETS:
            if target.startswith("x86"):
                calculate = ('let (a,b,c)=asm<Int,Int,Int>('
                             '"sub rsp,32;mov [rsp],rbx;mov [rsp+8],r12;'
                             'lea r13,[rsp+8];mov r14,[r13];mov r15,[rsp];'
                             'add r15,r14;mov rax,rsp;sub rax,r13;'
                             'push r15;pop rbx;add rsp,32",'
                             'inout("rbx",x),in("r12",x+1),out("r15"),out("rax"),'
                             'clobber("r13"),clobber("r14"));')
                registers = ("rbx", "r12", "r13", "r14", "r15")
                reg_cases = ''.join(f'assert(asm<Int>("add {r},1",inout("{r}",x))==x+1);' for r in registers)
                for r, aliases in (("rbx", ("bl", "bx", "ebx")),
                                   *((f"r{i}", (f"r{i}b", f"r{i}w", f"r{i}d")) for i in range(12, 16))):
                    for alias, typ, cast in zip(aliases, ("U8", "U16", "U32"), ("u8", "u16", "u32")):
                        reg_cases += f'assert(asm<{typ}>("add {alias},1",inout("{alias}",{cast}(41)))=={cast}(42));'
                reg_cases += 'asm("' + ';'.join(f'mov {r},0' for r in registers) + '",' + ','.join(
                    f'clobber("{r}")' for r in registers) + ');'
                memory = ('let p=raw_alloc<Int>(1);raw_store(p,0,x);' + ''.join(
                    f'assert(asm<Int>("mov rax,[{r}]",in("{r}",ptr_addr(p)),out("rax"))==x);'
                    for r in registers) + 'raw_free(p);')
            else:
                calculate = ('let (a,b,c)=asm<Int,Int,Int>('
                             '"sub sp,sp,#32;str x19,[sp];str x20,[sp,#8];'
                             'mov x17,sp;ldr x21,[x17];ldr x22,[sp,#8];'
                             'add x19,x21,x22;mov x23,sp;sub x23,x23,x17;'
                             'sub x23,x23,#8;mov x24,x19;add sp,sp,#32",'
                             'inout("x19",x),in("x20",x+1),out("x24"),out("x23"),'
                             'clobber("x17"),clobber("x21"),clobber("x22"));')
                registers = ("x17", *(f"x{i}" for i in range(19, 29)))
                reg_cases = ''.join(f'assert(asm<Int>("add {r},{r},#1",inout("{r}",x))==x+1);' for r in registers)
                reg_cases += ''.join(f'assert(asm<U32>("mov w{i},#42",out("w{i}"))==u32(42));' for i in range(19, 29))
                reg_cases += 'asm("' + ';'.join(f'mov {r},#0' for r in registers) + '",' + ','.join(
                    f'clobber("{r}")' for r in registers) + ');'
                memory = ''
            source = ('fn id<T>(x:T)->T{return x;}fn after(x:Int)->Int{return x+3;}'
                      'fn calc(x:Int)->Int{#scope[bb,opt]{let live="alive";' + calculate +
                      'assert(a==x+x+1 && b==a && c == -8);assert(live=="alive");' +
                      reg_cases + memory + 'return after(id(a));}}'
                      'fn main(){let mut i=0;while i<40{assert(calc(i)==i+i+4);i=i+1;}println(42);}')
            for opt in ("off", "basic"):
                with self.subTest(target=target, opt=opt):
                    self.success(source, target, opt=opt)
                    # Independent entry/exit probe seeds full-width ABI registers.
                    # Missing saves/restores fail even if IR values all live in memory.
                    # Xen's integer printing uses r15 as a private formatting flag.
                    # Keep that unrelated runtime convention outside this ABI probe.
                    (self.root / "probe.xen").write_text(source.replace('println(42);', ''))
                    built = subprocess.run([str(ROOT / "_build/default/tests/asm_abi_fixture.exe"),
                                            target, str(self.root / "probe.xen"),
                                            str(self.root / "probe"), opt],
                                           capture_output=True, text=True, timeout=30)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    actual = self.run_binary(self.root / "probe", target)
                    self.assertEqual((actual.returncode, actual.stdout, actual.stderr), (0, "", ""))

    def test_asm_cpu_information(self):
        for target in TARGETS:
            if target.startswith("x86"):
                body = ('let (leaf,b,c,d)=asm<U32,U32,U32,U32>("cpuid",'
                        'inout("eax",u32(0)),out("ebx"),inout("ecx",u32(0)),out("edx"));'
                        'assert(leaf>=u32(1));assert((b|c|d)!=u32(0));'
                        'let (lo,hi)=asm<U32,U32>("rdtsc",out("eax"),out("edx"));'
                        'assert((lo|hi)!=u32(0));')
            else:
                body = ('let (counter,freq,tls)=asm<U64,U64,U64>('
                        '"mrs x19,cntvct_el0;mrs x20,cntfrq_el0;mrs x17,tpidr_el0",'
                        'out("x19"),out("x20"),out("x17"));assert(counter>u64(0) && freq>u64(0));')
            for opt in ("off", "basic"):
                with self.subTest(target=target, opt=opt):
                    self.success('fn main(){#scope[bb,opt]{' + body + 'println(42);}}', target, opt=opt)

    def test_rejected_stack_operations(self):
        cases = {
            "x86_64-linux": [
                ('asm("sub rsp,16");', "must be restored"),
                ('asm("add rsp,16;sub rsp,16");', "exceeds allocated"),
                ('asm("sub rsp,8;add rsp,16");', "exceeds allocated"),
                ('asm("push r12",in("r12",1));', "must be restored"),
                ('asm<Int>("pop r12",out("r12"));', "exceeds allocated"),
                ('asm("mov rsp,rax",in("rax",1));', "stack pointer write"),
                ('asm("and rsp,-16");', "stack pointer write"),
                ('asm<Int>("lea rax,[rsp]",in("rsp",1),out("rax"));', "stack pointer constraint"),
                ('asm("nop",clobber("rsp"));', "stack pointer constraint"),
                ('asm<Int>("mov rax,rsp",out("rsp"));', "stack pointer constraint"),
                ('asm("cpuid",in("eax",u32(0)),in("ecx",u32(0)));', "undeclared"),
            ],
            "aarch64-linux": [
                ('asm("sub sp,sp,#16");', "must be restored"),
                ('asm("add sp,sp,#16;sub sp,sp,#16");', "exceeds allocated"),
                ('asm("sub sp,sp,#8;add sp,sp,#8");', "multiple of 16"),
                ('asm("sub sp,sp,#16;add sp,sp,#32");', "exceeds allocated"),
                ('asm("mov sp,x0",in("x0",1));', "unsupported"),
                ('asm("nop",clobber("sp"));', "unsupported"),
                ('asm<Int>("mrs x19,sctlr_el1",out("x19"));', "unsupported system register"),
            ],
        }
        for target, target_cases in cases.items():
            for body, message in target_cases:
                with self.subTest(target=target, body=body):
                    built, _ = self.build('fn main(){#scope[bb]{' + body + '}}', target)
                    self.assertNotEqual(built.returncode, 0)
                    self.assertIn(message, built.stderr)
                    self.assertIn("app.xen:", built.stderr)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xen-low-level-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, PATH=str(self.root / "no-tools"))

    def build(self, source, target, opt="off"):
        path = self.root / "app.xen"
        path.write_text(source)
        output = self.root / "program"
        result = subprocess.run([str(XEN), "build", str(path), f"--target={target}",
                                 f"--opt={opt}", "-o", str(output)], env=self.env,
                                capture_output=True, text=True, timeout=30)
        return result, output

    def run_binary(self, output, target):
        arch = target.split("-")[0]
        host = {"arm64": "aarch64"}.get(platform.machine(), platform.machine())
        runner = [] if host == arch else [shutil.which("qemu-" + arch)]
        if runner and runner[0] is None:
            self.skipTest(f"execution requires qemu-{arch}")
        return subprocess.run([*runner, str(output)], capture_output=True, text=True, timeout=20)

    def success(self, source, target, expected="42\n", opt="off"):
        built, output = self.build(source, target, opt)
        self.assertEqual(built.returncode, 0, built.stderr)
        actual = self.run_binary(output, target)
        self.assertEqual((actual.returncode, actual.stdout, actual.stderr), (0, expected, ""))

    def test_volatile_numeric_and_generic_pointer_roundtrip(self):
        types = [("I8", "i8(-128)"), ("U8", "u8(255)"),
                 ("I16", "i16(-32768)"), ("U16", "u16(65535)"),
                 ("I32", "i32(-2147483648)"), ("U32", "u32(4294967295)"),
                 ("I64", "-9223372036854775808"), ("U64", "u64(18446744073709551615)"),
                 ("F32", "f32(-1.5)"), ("F64", "-2.5")]
        body = "".join(f"{{let p=raw_alloc<{t}>(2);let v={value};"
                       f"volatile_store<{t}>(p,1,v);let q=alias<{t}>(ptr_addr(p),2);"
                       "assert(get(q,1)==v);put(q,0,v);assert(volatile_load(p,0)==v);raw_free(p);}"
                       for t, value in types)
        source = ("#global[bb]\nfn alias<T>(a:Int,n:Int)->Ptr<T>{return ptr_from_addr<T>(a,n);}"
                  "fn get<T>(p:Ptr<T>,i:Int)->T{return volatile_load<T>(p,i);}"
                  "fn put<T>(p:Ptr<T>,i:Int,x:T){volatile_store<T>(p,i,x);}"
                  "fn main(){#scope[opt,bb]{" + body + "println(42);}}")
        for target in TARGETS:
            for opt in ("off", "basic"):
                with self.subTest(target=target, opt=opt):
                    self.success(source, target, opt=opt)

    def test_asm_inputs_outputs_clobbers_and_memory(self):
        for target in TARGETS:
            a, b, out, scratch = REGS[target]
            if target.startswith("x86"):
                calc = f"mov {out}, {a}; add {out}, {b}; mov {scratch}, {out}; imul {out}, {b}"
                load = f"mov {out}, [{a}]"
                store = f"mov [{a}], {b}"
                tied = f"add {a}, {b}"
            else:
                calc = f"add {out}, {a}, {b}; mov {scratch}, {out}; mul {out}, {out}, {b}"
                load = f"ldr {out}, [{a}]"
                store = f"str {b}, [{a}]"
                tied = f"add {a}, {a}, {b}"
            source = ("#global[bb]\nfn value(n:Int)->Int{println(n);return n;}"
                      "fn id<T>(x:T)->T{return x;}fn main(){#scope[bb,opt]{"
                      f'println(id(asm<Int>("{calc}",in("{a}",value(4)),in("{b}",value(6)),out("{out}"),clobber("{scratch}"))));'
                      f'println(asm<I64>("{tied}",inout("{a}",17),in("{b}",25)));'
                      "let p=raw_alloc<Int>(1);raw_store(p,0,7);"
                      f'println(asm<Int>("{load}",in("{a}",ptr_addr(p)),out("{out}")));'
                      f'asm("{store}",in("{a}",ptr_addr(p)),in("{b}",42));'
                      'println(volatile_load(p,0));raw_free(p);}}')
            for opt in ("off", "basic"):
                with self.subTest(target=target, opt=opt):
                    self.success(source, target, "4\n6\n60\n42\n7\n42\n", opt)

    def test_unused_asm_and_loops_preserve_memory_effects(self):
        for target in TARGETS:
            a, b, out, _ = REGS[target]
            instruction = f"mov [{a}], {b}; mov {out}, {b}" if target.startswith("x86") else f"str {b}, [{a}]; mov {out}, {b}"
            source = ("fn main(){#scope[bb,opt]{let p=raw_alloc<Int>(1);let mut i=0;while i<3{"
                      f'asm<Int>("{instruction}",in("{a}",ptr_addr(p)),in("{b}",i),out("{out}"));'
                      "volatile_load(p,0);i=i+1;}println(raw_load(p,0));raw_free(p);}}")
            for opt in ("off", "basic"):
                with self.subTest(target=target, opt=opt):
                    self.success(source, target, "2\n", opt)

    def test_asm_high_register_staging_and_integer_extensions(self):
        for target in TARGETS:
            regs = ("r8", "r9", "r10", "r11") if target.startswith("x86") else ("x11", "x12", "x13", "x14")
            a, b, c, result = regs
            if target.startswith("x86"):
                template = f"add {result}, {a}; add {result}, {b}; add {result}, {c}"
                constant = f"mov {result}, -1"
            else:
                template = f"add {result}, {result}, {a}; add {result}, {result}, {b}; add {result}, {result}, {c}"
                constant = f"mov {result}, #-1"
            source = ("fn main(){#scope[bb,opt]{"
                      f'println(asm<I64>("{template}",in("{a}",i8(-128)),in("{b}",u32(4294967295)),'
                      f'in("{c}",7),inout("{result}",11)));'
                      f'println(asm<U64>("{constant}",out("{result}")));' + "}}")
            for opt in ("off", "basic"):
                with self.subTest(target=target, opt=opt):
                    self.success(source, target, "4294967185\n18446744073709551615\n", opt)

    def test_volatile_float_bit_preservation(self):
        # Reinterpret through bounded aliases so numeric equality cannot hide
        # signed-zero changes or NaN payload canonicalization.
        body = ""
        for integer, floating, patterns in [
                ("U32", "F32", (0x80000000, 0x7fc12345)),
                ("U64", "F64", (0x8000000000000000, 0x7ff8123456789abc))]:
            conversion = integer.lower()
            for bits in patterns:
                body += (f"{{let p=raw_alloc<{integer}>(2);raw_store(p,0,{conversion}({bits}));"
                         f"let floats=ptr_from_addr<{floating}>(ptr_addr(p),2);"
                         "volatile_store(floats,1,volatile_load(floats,0));"
                         f"assert(raw_load(p,1)=={conversion}({bits}));raw_free(p);}}")
        source = "fn main(){#scope[bb,opt]{" + body + "println(42);}}"
        for target in TARGETS:
            for opt in ("off", "basic"):
                with self.subTest(target=target, opt=opt):
                    self.success(source, target, opt=opt)

    def test_raw_syscall_mapping_pointer_interop(self):
        for target, mmap_number in (("x86_64-linux", 9), ("aarch64-linux", 222)):
            source = ("fn main(){#scope[bb,opt]{"
                      f"let address=syscall6({mmap_number},0,4096,3,34,-1,0);assert(address>0);"
                      "let p=ptr_from_addr<U32>(address,1024);volatile_store(p,1023,u32(42));"
                      "println(volatile_load(p,1023));raw_free(p);}}")
            for opt in ("off", "basic"):
                with self.subTest(target=target, opt=opt):
                    self.success(source, target, opt=opt)

    def test_pointer_and_volatile_runtime_checks(self):
        invalid = ["ptr_from_addr<Int>(0,1);", "ptr_from_addr<Int>(1,0);",
                   "ptr_from_addr<Int>(8,-1);", "ptr_from_addr<Int>(8,1152921504606846976);",
                   "ptr_from_addr<Int>(-8,1);", "ptr_from_addr<U8>(-1,2);",
                   "let p=raw_alloc<Int>(1);volatile_load(p,-1);",
                   "let p=raw_alloc<Int>(1);volatile_store(p,1,7);"]
        for target in TARGETS:
            for body in invalid:
                with self.subTest(target=target, body=body):
                    built, output = self.build("fn main(){#scope[bb,opt]{" + body + "}}", target, "basic")
                    self.assertEqual(built.returncode, 0, built.stderr)
                    actual = self.run_binary(output, target)
                    self.assertNotEqual(actual.returncode, 0)
                    self.assertIn("raw pointer", actual.stderr)
            self.success("fn main(){#scope[bb]{let p=ptr_from_addr<Int>(0,0);"
                         "assert(ptr_addr(p)==0);let high=ptr_from_addr<U8>(-1,0);"
                         "assert(ptr_addr(high)==-1);println(42);}}", target)

    def test_rejected_contracts_and_target_instructions(self):
        common = [
            ('fn main(){asm("nop");}', "requires #![bb]"),
            ('fn main(){volatile_load(1,0);}', "requires #![bb]"),
            ('fn main(){ptr_from_addr<Int>(0,0);}', "requires #![bb]"),
            ('fn main(){cpu_relax();}', "requires #![bb]"),
            ('fn main(){memory_fence();}', "requires #![bb]"),
            ('cpu_relax(1);', "expects 0 arguments"),
            ('memory_fence(1);', "expects 0 arguments"),
            ('cpu_relax<Int>();', "does not accept type arguments"),
            ('memory_fence<Int>();', "does not accept type arguments"),
            ('fn cpu_relax(){}fn main(){}', "reserved"),
            ('fn memory_fence(){}fn main(){}', "reserved"),
            ('fn main(){#scope[bb]{cpu_relax();}memory_fence();}', "requires #![bb]"),
            ('fn main(){#scope[bb]{asm("nop");}asm("nop");}', "requires #![bb]"),
            ('asm<Int>("nop");', "must return Unit"),
            ('asm<F32>("nop",out("invalid"));', "integer scalars"),
            ('asm("nop",in("invalid",true));', "integer scalars"),
            ('asm("nop",in("invalid",1),in("invalid",2));', "duplicate register"),
            ('let p=raw_alloc<Bool>(1);volatile_load(p,0);', "numeric scalar"),
            ('ptr_from_addr(0,0);', "explicit type argument"),
            ('ptr_from_addr<String>(0,0);', "not raw-safe POD"),
            ('let p=raw_alloc<I32>(1);volatile_load<I64>(p,0);', "expected I32"),
        ]
        for target in TARGETS:
            a, b, out, _ = REGS[target]
            move = f"mov {out}, {a}"
            add = f"add {a}, {b}" if target.startswith("x86") else f"add {a}, {a}, {b}"
            target_cases = [
                (f'asm<Int>("{add}",in("{a}",1),in("{b}",2),out("{a}"));', "use inout"),
                (f'asm<Int>("{add}",in("{a}",1),in("{b}",2),out("{out}"));', "undeclared output/clobber"),
                (f'asm<Int>("{move}",out("{out}"));', "uninitialized register"),
                (f'asm<Int>("nop",out("{out}"));', "uninitialized"),
                ('asm("ret");', "unsupported"),
                ('asm(".byte 0");', "unsupported"),
                ('asm("nop",clobber("rsp"));', "unsupported"),
                ('asm("nop",clobber("x29"));', "unsupported"),
                ('asm("nop",clobber("x16"));', "unsupported"),
            ]
            for body, message in common + target_cases:
                with self.subTest(target=target, body=body):
                    source = body if body.startswith("fn ") else "fn main(){#scope[bb]{" + body + "}}"
                    built, _ = self.build(source, target)
                    self.assertNotEqual(built.returncode, 0)
                    self.assertIn(message, built.stderr)
                    self.assertIn("app.xen:", built.stderr)

    def test_asm_immediates_shifts_and_unary_operations(self):
        for target in TARGETS:
            if target.startswith("x86"):
                cases = [
                    ("add r11, 49", -7, 42), ("sub r11, -49", -7, 42),
                    ("imul r11, -7", -6, 42), ("xor r11, 15", 37, 42),
                    ("and r11, 127", 170, 42), ("or r11, 10", 32, 42),
                    ("add r11, 2147483647", -2147483605, 42),
                    ("sub r11, -2147483648", -2147483606, 42),
                    ("imul r11, -2147483648", 1, -2147483648),
                    ("neg r11", -42, 42), ("not r11", -43, 42),
                    ("bswap r11", 3026418949592973312, 42),
                    ("shl r11, 63", 1, -9223372036854775808),
                    ("shr r11, 63", -1, 1), ("sar r11, 63", -9223372036854775808, -1),
                ] + [(f"{op} r11, 0", 42, 42) for op in ("shl", "shr", "sar")]
                body = "".join(f'{{assert(asm<Int>("{text}",inout("r11",{value}))=={want});}}'
                               for text, value, want in cases)
                for op, value, want in [("shl", 21, 42), ("shr", 84, 42), ("sar", -84, -42)]:
                    for count in (1, 65):
                        body += (f'assert(asm<Int>("{op} r11, cl",inout("r11",{value}),'
                                 f'in("rcx",{count}))=={want});')
            else:
                cases = [
                    ("add x14, x14, #49", -7, 42), ("sub x14, x14, #49", 91, 42),
                    ("add x14, x14, #4095", -4053, 42), ("sub x14, x14, #4095", 4137, 42),
                    ("neg x14, x14", -42, 42), ("mvn x14, x14", -43, 42),
                    ("rev x14, x14", 3026418949592973312, 42),
                    ("lsl x14, x14, #63", 1, -9223372036854775808),
                    ("lsr x14, x14, #63", -1, 1),
                    ("asr x14, x14, #63", -9223372036854775808, -1),
                ] + [(f"{op} x14, x14, #0", 42, 42) for op in ("lsl", "lsr", "asr")]
                body = "".join(f'{{assert(asm<Int>("{text}",inout("x14",{value}))=={want});}}'
                               for text, value, want in cases)
                for op, value, want in [("lsl", 21, 42), ("lsr", 84, 42), ("asr", -84, -42)]:
                    for count in (1, 65):
                        body += (f'assert(asm<Int>("{op} x11, x14, x12",in("x14",{value}),'
                                 f'in("x12",{count}),out("x11"))=={want});')
                for op, value in [("neg", -42), ("mvn", -43), ("rev", 3026418949592973312)]:
                    body += (f'assert(asm<Int>("{op} x11, x14",in("x14",{value}),'
                             'out("x11"))==42);')
            for opt in ("off", "basic"):
                with self.subTest(target=target, opt=opt):
                    self.success("fn main(){#scope[bb,opt]{" + body + "println(42);}}", target, opt=opt)

    def test_asm_memory_byte_offsets(self):
        for target in TARGETS:
            a, b, out, _ = REGS[target]
            body = "let p=raw_alloc<Int>(4096);"
            for offset, base in [(0, "ptr_addr(p)"), (32760, "ptr_addr(p)"),
                                 (-256, "ptr_addr(p)+256"), (255, "ptr_addr(p)"),
                                 (1, "ptr_addr(p)")]:
                if target.startswith("x86"):
                    address = f"[{a} {'-' if offset < 0 else '+'} {abs(offset)}]"
                    store, load = f"mov {address}, {b}", f"mov {out}, {address}"
                else:
                    scaled = offset >= 0 and offset % 8 == 0
                    address = f"[{a}, #{offset}]"
                    store = f"{'str' if scaled else 'stur'} {b}, {address}"
                    load = f"{'ldr' if scaled else 'ldur'} {out}, {address}"
                body += (f'asm("{store}",in("{a}",{base}),in("{b}",42));'
                         f'assert(asm<Int>("{load}",in("{a}",{base}),out("{out}"))==42);')
                if offset in (0, 32760, -256):
                    body += f"assert(volatile_load(p,{4095 if offset == 32760 else 0})==42);"
                else:
                    body += ("{let bytes=ptr_from_addr<U8>(ptr_addr(p),32768);"
                             f"assert(volatile_load(bytes,{offset})==u8(42));"
                             f"assert(volatile_load(bytes,{offset + 1})==u8(0));}}")
            body += "raw_free(p);println(42);"
            for opt in ("off", "basic"):
                with self.subTest(target=target, opt=opt):
                    self.success("fn main(){#scope[bb,opt]{" + body + "}}", target, opt=opt)

    def test_cpu_hint_and_fence_effects(self):
        for target in TARGETS:
            if target.startswith("x86"):
                marker = 'asm("mov r11, 123456789",clobber("r11"));'
                marker_bytes = bytes.fromhex("49bb15cd5b0700000000")
                hint, fence = bytes.fromhex("f390"), bytes.fromhex("0faef0")
            else:
                marker = 'asm("mov x14, #123456789",clobber("x14"));'
                marker_bytes = bytes.fromhex("aea299d26eeba0f20e00c0f20e00e0f2")
                hint, fence = bytes.fromhex("3f2003d5"), bytes.fromhex("bf3b03d5")
            source = ("#global[bb]\nfn touch<T>(x:T)->T{cpu_relax();memory_fence();return x;}"
                      "fn main(){#scope[bb,opt]{let p=raw_alloc<Int>(1);" + marker +
                      "cpu_relax();volatile_store(p,0,42);memory_fence();"
                      "assert(volatile_load(p,0)==42);cpu_relax();memory_fence();" + marker +
                      "assert(touch(42)==42);let mut i=0;while i<3{cpu_relax();memory_fence();i=i+1;}"
                      "raw_free(p);println(42);}}")
            for opt in ("off", "basic"):
                with self.subTest(target=target, opt=opt):
                    built, output = self.build(source, target, opt)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    pieces = output.read_bytes().split(marker_bytes)
                    self.assertEqual(len(pieces), 3)
                    code = pieces[1]
                    self.assertEqual(code.count(hint), 2)
                    self.assertEqual(code.count(fence), 2)
                    positions = sorted((code.find(hint), code.find(fence),
                                        code.rfind(hint), code.rfind(fence)))
                    self.assertEqual([code[p:p + len(op)] for p, op in zip(positions, [hint, fence, hint, fence])],
                                     [hint, fence, hint, fence])
                    actual = self.run_binary(output, target)
                    self.assertEqual((actual.returncode, actual.stdout, actual.stderr), (0, "42\n", ""))

    def test_rejected_extended_asm_operands(self):
        cases = {
            "x86_64-linux": [
                ('asm<Int>("add r8, 2147483648",inout("r8",1));', "signed 32-bit"),
                ('asm<Int>("imul r8, -2147483649",inout("r8",1));', "signed 32-bit"),
                ('asm<Int>("shl r8, 64",inout("r8",1));', "shift count"),
                ('asm<Int>("sar r8, cl",inout("r8",1));', "uninitialized register 'rcx'"),
                ('asm<Int>("shr r8, cl",inout("r8",1),clobber("rcx"));', "uninitialized register 'rcx'"),
                ('asm<Int>("neg r8",out("r8"));', "uninitialized"),
                ('asm<Int>("add r8, 1",in("r8",1));', "must return Unit"),
                ('asm<Int>("mov r8, [r8 + 2147483648]",inout("r8",1));', "signed 32-bit"),
                ('asm<Int>("mov r8, [r8 - 2147483649]",inout("r8",1));', "signed 32-bit"),
                ('asm<Int>("mov r8, [esp + 8]",out("r8"));', "unsupported"),
                ('asm<Int>("mov r8, [r8 + rcx]",inout("r8",1));', "displacement"),
            ],
            "aarch64-linux": [
                ('asm<Int>("add x14, x14, #4096",inout("x14",1));', "0..4095"),
                ('asm<Int>("sub x14, x14, #-1",inout("x14",1));', "0..4095"),
                ('asm<Int>("asr x14, x14, #64",inout("x14",1));', "0..63"),
                ('asm<Int>("lsl x14, x14, x1",inout("x14",1));', "uninitialized"),
                ('asm<Int>("rev x14, x0",out("x14"));', "uninitialized"),
                ('asm<Int>("ldr x14, [x14, #32768]",inout("x14",1));', "0..32760"),
                ('asm("str x14, [x14, #1]",in("x14",1));', "multiple of 8"),
                ('asm<Int>("ldur x14, [x14, #-257]",inout("x14",1));', "-256..255"),
                ('asm("stur x14, [x14, #256]",in("x14",1));', "-256..255"),
                ('asm<Int>("ldr x14, [x16, #8]",out("x14"));', "unsupported"),
                ('asm<Int>("ldr x14, [x14, #8]!",inout("x14",1));', "without writeback"),
            ],
        }
        for target, examples in cases.items():
            for body, message in examples:
                with self.subTest(target=target, body=body):
                    built, _ = self.build("fn main(){#scope[bb]{" + body + "}}", target)
                    self.assertNotEqual(built.returncode, 0)
                    self.assertIn(message, built.stderr)
                    self.assertIn("app.xen:", built.stderr)

    def test_volatile_access_width_and_count_in_generated_code(self):
        # Unique asm markers bound the operation sequence, independent of runtime code.
        for target in TARGETS:
            _, _, _, marker_reg = REGS[target]
            for typ, value, width in [("U8", "u8(7)", 1), ("I16", "i16(-7)", 2),
                                      ("U32", "u32(7)", 4), ("I64", "7", 8),
                                      ("F32", "f32(1.5)", 4), ("F64", "1.5", 8)]:
                if target.startswith("x86"):
                    marker = f"mov {marker_reg}, 123456789"
                    marker_bytes = bytes.fromhex("49bb15cd5b0700000000")
                    loads = {"U8": "0fb600", "I16": "480fbf00", "U32": "8b00",
                             "I64": "488b00", "F32": "f30f1000", "F64": "f20f1000"}
                    stores = {1: "8807", 2: "668907", 4: "8907", 8: "488907"}
                    # Include the checked address calculation: error-reporting
                    # stubs also contain scalar memory instructions.
                    load_bytes = bytes.fromhex("4801d04883c410" + loads[typ])
                    staged_value = "8b0424" if typ == "F32" else "488b0424"
                    store_bytes = bytes.fromhex(staged_value + stores[width] + "4883c420")
                else:
                    marker = f"mov {marker_reg}, #123456789"
                    marker_bytes = b"".join(struct.pack("<I", base | (half << 21) | (chunk << 5) | 14)
                                            for half, (base, chunk) in enumerate([
                                                (0xd2800000, 0xcd15), (0xf2800000, 0x075b),
                                                (0xf2800000, 0), (0xf2800000, 0)]))
                    base = {1: 0x39000000, 2: 0x79000000, 4: 0xb9000000, 8: 0xf9000000}[width]
                    load_bytes = struct.pack("<I", base | 0x00400000 | (9 << 5))
                    store_bytes = struct.pack("<I", base | (9 << 5))
                source = ("fn main(){#scope[bb,opt]{" + f"let p=raw_alloc<{typ}>(1);"
                          f'asm("{marker}",clobber("{marker_reg}"));'
                          f"volatile_store(p,0,{value});volatile_load(p,0);volatile_load(p,0);"
                          f'asm("{marker}",clobber("{marker_reg}"));raw_free(p);' + "}}")
                for opt in ("off", "basic"):
                    with self.subTest(target=target, typ=typ, opt=opt):
                        built, output = self.build(source, target, opt)
                        self.assertEqual(built.returncode, 0, built.stderr)
                        pieces = output.read_bytes().split(marker_bytes)
                        self.assertEqual(len(pieces), 3)
                        self.assertEqual(pieces[1].count(load_bytes), 2)
                        self.assertEqual(pieces[1].count(store_bytes), 1)


if __name__ == "__main__":
    unittest.main()
