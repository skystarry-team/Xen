# SPDX-License-Identifier: MIT OR Apache-2.0
"""Initial Linux AArch64 contract and execution, using native ARM64 or QEMU.

Builds always run without external tools on PATH. Set XEN_REQUIRE_ARM64=1 to fail
instead of skipping execution when no compatible runner is installed.
"""
import os
from pathlib import Path
import platform
import random
import shutil
import struct
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
XEN = REPO / "compiler/dist/xen"
NATIVE = platform.system() == "Linux" and platform.machine() in ("aarch64", "arm64")
QEMU = shutil.which("qemu-aarch64")


class Arm64Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xen-arm64-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "app.xen"
        self.env = dict(os.environ, PATH=str(self.root / "no-tools"))
        self.env.pop("XEN_STDLIB_ROOT", None)

    def compile(self, text, target="aarch64-linux", opt="off", flags=("--jit=off",)):
        self.source.write_text(text)
        output = self.root / target
        result = subprocess.run([str(XEN), "build", str(self.source),
                                 f"--target={target}", f"--opt={opt}", *flags,
                                 "-o", str(output)], env=self.env,
                                capture_output=True, text=True, timeout=30)
        return result, output

    def runner(self):
        if NATIVE:
            return []
        if QEMU:
            return [QEMU]
        if os.getenv("XEN_REQUIRE_ARM64") == "1":
            self.fail("ARM64 execution requires qemu-aarch64 or a native Linux ARM64 host")
        self.skipTest("install qemu-user for ARM64 execution")

    def execute(self, binary, args=()):
        return subprocess.run([*self.runner(), str(binary), *args],
                              capture_output=True, text=True, timeout=20)

    def differential(self, text, expected, args=(), status=0, error=None):
        self.runner()
        for opt in ("off", "basic"):
            with self.subTest(opt=opt):
                built, arm = self.compile(text, opt=opt)
                self.assertEqual(built.returncode, 0, built.stderr)
                actual = self.execute(arm, args)
                self.assertEqual(actual.returncode, status, actual.stderr)
                self.assertEqual(actual.stdout, expected)
                if error:
                    self.assertIn(error, actual.stderr)
                if platform.machine() == "x86_64":
                    built, x86 = self.compile(text, target="x86_64-linux", opt=opt)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    reference = subprocess.run([str(x86), *args], capture_output=True,
                                               text=True, timeout=20)
                    self.assertEqual((actual.returncode, actual.stdout),
                                     (reference.returncode, reference.stdout))
                    # Depth diagnostics identify callee entry on ARM64, caller
                    # on x86-64. Missing-arg legacy output also has extra bytes.
                    if not error or error not in ("maximum call depth", "missing program argument"):
                        self.assertEqual(actual.stderr, reference.stderr)

    def test_static_elf_and_alias_without_external_tools(self):
        compiled, output = self.compile('fn main(){println("hello ARM64");}')
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        binary = output.read_bytes()
        self.assertEqual(binary[:7], b"\x7fELF\x02\x01\x01")
        self.assertEqual(struct.unpack_from("<HH", binary, 16), (2, 183))
        entry, phoff = struct.unpack_from("<QQ", binary, 24)
        entsize, count = struct.unpack_from("<HH", binary, 54)
        headers = [struct.unpack_from("<IIQQQQQQ", binary, phoff + i * entsize)
                   for i in range(count)]
        self.assertEqual(count, 4)
        self.assertFalse(any(h[0] in (2, 3) for h in headers))  # DYNAMIC, INTERP
        self.assertEqual([h[1] for h in headers if h[0] == 1], [5, 4, 6])
        self.assertEqual(headers[-1][:2], (0x6474E551, 6))  # non-executable stack
        for h in headers[:3]:
            self.assertEqual(h[7], 65536)
            self.assertEqual(h[2] % h[7], h[3] % h[7])
            self.assertLessEqual(h[2] + h[5], len(binary))
        self.assertTrue(headers[0][3] <= entry < headers[0][3] + headers[0][5])
        compiled, alias = self.compile('fn main(){println("hello ARM64");}', target="arm64-linux")
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        self.assertEqual(alias.read_bytes(), binary)

    def test_integer_widths_control_flow_and_calls(self):
        self.differential('''
fn fib(n:I64)->I64{if n<2{return n;}return fib(n-1)+fib(n-2);}
fn six(a:I8,b:U16,c:I32,d:U64,e:I64,f:Bool)->I64{
    assert(f);return i64(a)+i64(b)+i64(c)+i64(d)+e;
}
fn main(){
    let a:I8=127;println(a+i8(1));
    let b:U8=255;println(b+u8(1));
    let c:I16=-32768;println(c-i16(1));
    let d:U16=65535;println(d+u16(1));
    let e:I32=2147483647;println(e+i32(1));
    let f:U32=4294967295;println(f+u32(1));
    let big:U64=18446744073709551615;println(big);println(big/u64(3));
    println(big%u64(7));println(big>u64(1));println(-7/3);println(-7%3);
    println(-9223372036854775807-1);println(fib(10));
    println(six(i8(-2),u16(7),i32(-3),u64(5),6,true));
    let mut i=0;let mut sum=0;while i<10{i=i+1;if i==3{continue;}if i==7{break;}sum=sum+i;}
    println(sum);println(false && (1/0==0));println(true || (1/0==0));
}''', "-128\n0\n32767\n0\n-2147483648\n0\n18446744073709551615\n"
                 "6148914691236517205\n1\ntrue\n-2\n-1\n-9223372036854775808\n55\n13\n18\nfalse\ntrue\n")

    def test_references_aggregates_generics_and_indirect_calls(self):
        self.differential('''
#global[explc]
struct Pair<T>{left:T,right:T}
fn id<T>(x:T)->T{return x;}
fn bump(x:&mut I32){*x=*x+i32(1);}
fn double(x:I64)->I64{return x*2;}
fn sum(p:Pair<I64>)->I64{return p.left+p.right;}
fn main(){let mut n:I32=8;bump(&mut n);println(n);
 let p=Pair{left:12,right:30};println(sum(id(p)));let f=double;println(f(21));
 let mut label="first";{let r=&mut label;*r="second";}println(label);
 let mut q=Pair{left:"a",right:"b"};q.left="c";println(id(q).left);
 let option:Option<I64>=Option.Some(42);println(match option{Option.Some(n)=>n,Option.None=>0});
}''', "9\n42\n42\nsecond\nc\n42\n")

    def test_string_lifetimes_and_program_arguments(self):
        self.differential('''
fn choose(n:Bool)->String{if n{return "literal";}return arg(0);}
fn main(){let a=choose(true);let b=a;println(a);println(b);println(choose(false));
 println(arg_count());println(len(arg(1)));println(arg(1)=="한글");println("ab"!="ac");
 println(""=="");println("a"=="aa");print("embedded\0nul");println("");}
''', "literal\nliteral\nhello\n2\n6\ntrue\ntrue\ntrue\nfalse\nembedded\0nul\n", args=("hello", "한글"))

    def test_large_frame_and_backward_branches(self):
        declarations = "".join(f"let v{i}:I64={i};" for i in range(600))
        expression = "+".join(f"v{i}" for i in range(600))
        self.differential("fn main(){" + declarations + f"println({expression});" + "}", "179700\n")

    def test_generated_integer_programs(self):
        rng = random.Random(20261011)
        statements, answers = [], []
        for _ in range(80):
            a, b = rng.randint(-10000, 10000), rng.randint(1, 1000)
            op = rng.choice(["+", "-", "*", "/", "%", "<", ">=", "=="])
            value = {"+": a+b, "-": a-b, "*": a*b, "/": int(a/b),
                     "%": a-int(a/b)*b, "<": a<b, ">=": a>=b, "==": a==b}[op]
            statements.append(f"println(({a}){op}({b}));")
            answers.append(str(value).lower())
        self.differential("fn main(){" + "".join(statements) + "}", "\n".join(answers)+"\n")

    def test_run_and_test_host_execution_diagnostics(self):
        self.source.write_text('test fn works(){assert(true);}fn main(){println(42);}')
        for command in ("run", "test"):
            with self.subTest(command=command):
                result = subprocess.run([str(XEN), command, str(self.source),
                                         "--target=aarch64-linux", "--jit=off"],
                                        capture_output=True, text=True, timeout=20)
                if result.returncode == 0:
                    self.assertIn("42\n" if command == "run" else "1 passed; 0 failed", result.stdout)
                else:
                    # The compiler does not implicitly invoke a QEMU on PATH.
                    # A native host or configured binfmt handler may execute it.
                    self.assertFalse(NATIVE, result.stderr)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn("cannot execute target 'aarch64-linux' on this host", result.stderr)

    def test_runtime_failures(self):
        for body, error in [
            ("println(1/0);", "division by zero"),
            ("println(1%0);", "remainder by zero"),
            ("let x:I8=-128;println(x/i8(-1));", "signed division overflow"),
            ("let x:I64=-9223372036854775807-1;println(x%(-1));", "signed remainder overflow"),
            ("let x:I64=-1;println(u8(x));", "numeric conversion to U8 failed"),
            ("let x:I64=128;println(i8(x));", "numeric conversion to I8 failed"),
            ("assert(false);", "assertion failed"),
            ('assert_msg(false,"reason");', "assertion failed: reason"),
            ('panic("stop");', "stop"),
            ("println(arg(-1));", "missing program argument"),
        ]:
            with self.subTest(body=body):
                self.differential("fn main(){"+body+"}", "", status=1, error=error)
        self.differential('fn recurse(n:I64)->I64{return recurse(n+1);}fn main(){println(recurse(0));}',
                          "", status=1, error="maximum call depth")

    def test_unsupported_features_do_not_overwrite_output(self):
        for text, message, flags in [
            ("fn main(){}", "JIT is not implemented", ()),
            ("fn main(){}", "JIT is not implemented", ("--jit=on", "--jit-report")),
            ("fn main(){println(1.5);}", "type F64 is not implemented", ("--jit=off",)),
            ("fn main(){println([1,2]);}", "type Vec", ("--jit=off",)),
            ('fn main(){let f=open_read("missing");}', "type File", ("--jit=off",)),
            ('fn main(){println("a"+"b");}', "concatenation is not implemented", ("--jit=off",)),
            ('fn main(){println(int_to_str(42));}', "builtin 'int_to_str'", ("--jit=off",)),
            ('#global[bb]\nfn main(){println(syscall0(172));}', "raw syscalls", ("--jit=off",)),
            ('use std.process;fn main(){println(std.process.id());}', "raw syscalls", ("--jit=off",)),
        ]:
            with self.subTest(text=text):
                output = self.root / "aarch64-linux"
                output.write_bytes(b"preserve me")
                compiled, output = self.compile(text, flags=flags)
                self.assertEqual(compiled.returncode, 1, compiled.stderr)
                self.assertIn(message, compiled.stderr)
                if "JIT" not in message:
                    self.assertIn(": error:", compiled.stderr.replace("native backend error:", "error:"))
                self.assertEqual(output.read_bytes(), b"preserve me")


if __name__ == "__main__":
    unittest.main(verbosity=2)
