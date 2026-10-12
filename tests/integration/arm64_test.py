# SPDX-License-Identifier: MIT OR Apache-2.0
"""Linux AArch64 contract and execution, using native ARM64 or QEMU.

Builds always run without external tools on PATH. Set XEN_REQUIRE_ARM64=1 to fail
instead of skipping execution when no compatible runner is installed.
"""
import os
import math
from pathlib import Path
import platform
import random
import re
import resource
import shutil
import struct
import subprocess
import tempfile
import threading
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

    def test_recursive_function_field_types_and_label_names(self):
        self.differential('''
struct Callback { invoke: fn(Callback)->I64 }
fn answer(value:Callback)->I64{return 7;}
fn main_block_0()->I64{return 42;}
fn main(){let value=Callback{invoke:answer};let call=value.invoke;
 println(call(value));println(main_block_0());}
''', "7\n42\n")

    def test_string_cleanup_reference_replacement_and_exchange(self):
        self.differential('''
use std.mem;
#global[explc]
enum Label { Empty, Text(String) }
fn read(value:&Label)->String{
 return match *value{Label.Empty=>"empty",Label.Text(text)=>text};
}
fn main(){
 let mut pair:(I64,String)=(1,"original");
 {let r=&mut pair;*r=*r;r.0=7;println(r.1);}
 println(pair.0);println(pair.1);
 let mut label:Label=Label.Text("first");println(read(&label));
 {let r=&mut label;*r=Label.Empty;}println(read(&label));
 {let r=&mut label;*r=Label.Text("last");}println(read(&label));
 let mut text="old";let previous=std.mem.replace(&mut text,"new");
 println(previous);println(text);
}
''', "original\n7\noriginal\nfirst\nempty\nlast\nold\nnew\n")

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

    def test_float_arithmetic_calls_storage_and_comparisons(self):
        self.differential('''
#global[explc]
struct Pair<T>{left:T,right:T}
fn id<T>(x:T)->T{return x;}
fn mix(a:F32,b:I64,c:Bool,d:F64,e:U64,f:F32)->F64{
 if c{return f64(a)+float(b)*d-f64(e)/f64(f);}return -0.0;
}
fn recurse(n:I64,x:F64)->F64{if n==0{return x;}return recurse(n-1,x+0.5);}
fn double(x:F32)->F32{return x*2.0;}
fn bump(x:&mut F32){*x=*x+0.5;}
fn main(){
 let mut x:F32=1.5;bump(&mut x);println(x);let call=double;println(call(x));
 let p=id(Pair{left:f32(1.25),right:f32(2.5)});println(p.left+p.right);
 let tuple=id((1.5,f32(-2.25)));println(tuple.0);println(tuple.1);
 println(mix(1.0,2,true,3.0,4,2.0));println(mix(1.0,2,false,3.0,4,2.0));
 println(recurse(3,1.0));println(f32(16777216.0)+f32(1.0));
 println(f32(0.0)*f32(-1.0));println(-(-0.0));
 let n=0.0/0.0;let s:F32=0.0/0.0;
 println(n==n);println(n!=n);println(n<1.0);println(n<=1.0);println(n>1.0);println(n>=1.0);
 println(1.0<n);println(1.0<=n);println(1.0>n);println(1.0>=n);
 println(s==s);println(s!=s);println(s<f32(1.0));println(s<=f32(1.0));
 println(s>f32(1.0));println(s>=f32(1.0));
 assert(f32(s)!=s);assert(f64(n)!=n);assert(f64(s)!=f64(s));
 assert(f32(f32(1.0)/f32(0.0))>f32(1.0));
 println(1.0<2.0);println(2.0<=2.0);println(3.0>2.0);println(3.0>=4.0);
 println(match f32(1.5){1.5=>7,_=>0});
}''', "2.0\n4.0\n3.75\n1.5\n-2.25\n5.0\n-0.0\n2.5\n16777216.0\n-0.0\n0.0\n"
             "false\ntrue\nfalse\nfalse\nfalse\nfalse\nfalse\nfalse\nfalse\nfalse\n"
             "false\ntrue\nfalse\nfalse\nfalse\nfalse\ntrue\ntrue\ntrue\nfalse\n7\n")

    def test_float_checked_conversions(self):
        self.differential('''fn main(){
 println(float(9007199254740993));println(int(3.9));println(int(-3.9));
 println(int(-9223372036854775808.0));println(i8(-128.0));println(u8(255.99));
 println(i16(f32(-12.75)));println(u16(65535.5));println(i32(-2147483648.0));
 println(u32(4294967295.0));println(i64(9223372036854774784.0));
 println(u64(9223372036854775808.0));println(u64(18446744073709549568.0));
 println(f64(u64(18446744073709551615)));println(f32(u64(18446744073709551615)));
 println(f64(i8(-128)));println(f32(u8(255)));println(f64(f32(0.1)));
 println(f32(3.4028234663852886e38));println(f32(-3.4028234663852886e38));
 println(f32(1e-100));println(f32(-1e-100));
}''', "9007199254740992.0\n3\n-3\n-9223372036854775808\n-128\n255\n-12\n65535\n"
             "-2147483648\n4294967295\n9223372036854774784\n9223372036854775808\n"
             "18446744073709549568\n1.8446744073709552e+19\n1.8446744073709552e+19\n"
             "-128.0\n255.0\n0.10000000149011612\n3.4028234663852886e+38\n"
             "-3.4028234663852886e+38\n0.0\n-0.0\n")
        failures = [
            ("int", "0.0/0.0"), ("int", "1.0/0.0"), ("int", "9223372036854775808.0"),
            ("f32", "0.0/0.0"), ("f32", "1.0/0.0"), ("f32", "-1.0/0.0"),
            ("f32", "3.402823466385289e38"), ("f32", "-3.402823466385289e38"),
        ]
        for typ, lower, upper in [("i8", -128, 128), ("u8", 0, 256),
                                  ("i16", -32768, 32768), ("u16", 0, 65536),
                                  ("i32", -2147483648, 2147483648), ("u32", 0, 4294967296),
                                  ("i64", -9223372036854775808, 9223372036854775808),
                                  ("u64", 0, 18446744073709551616)]:
            below = repr(math.nextafter(float(lower), -math.inf))
            failures.extend((typ, expression) for expression in
                            (below, f"{upper}.0", "0.0/0.0", "1.0/0.0"))
        for typ, expression in failures:
            with self.subTest(typ=typ, expression=expression):
                message = ("Float cannot be converted to Int" if typ == "int" else
                           f"numeric conversion to {typ.upper()} failed")
                self.differential(f"fn main(){{let x:F64={expression};println(7);println({typ}(x));}}",
                                  "7\n", status=1, error=message)

    @staticmethod
    def float_spelling(value):
        # Python's independently implemented binary64 formatter is the oracle.
        text = format(value, ".17g")
        if -2**63 <= value < 2**63 and value == math.trunc(value):
            text += ".0"
        return text

    def test_float_decimal_rounding_and_generated_values(self):
        values = [0.0, -0.0, 0.1, 1.2345678901234567, 1e-4, 1e-5, 1e16, 1e17,
                  5e-324, -5e-324, float.fromhex("0x1p-1022"),
                  float.fromhex("0x0.fffffffffffffp-1022"),
                  float.fromhex("0x1.fffffffffffffp+1023"),
                  -2**63, 2**63, math.nextafter(float(2**63), -math.inf),
                  # Exact halves with even/odd retained digits; decimal carry.
                  1.00000762939453125, 1.00002288818359375,
                  math.nextafter(1e-4, 0.0), math.nextafter(1e17, 0.0),
                  9.999999999999999e-5, 1e-14, 1e-305, 1e98, 1e129]
        rng = random.Random(20261012)
        while len(values) < 160:
            value = struct.unpack("<d", rng.getrandbits(64).to_bytes(8, "little"))[0]
            if math.isfinite(value):
                values.append(value)
        statements = [f"println({repr(float(value))});" for value in values]
        answers = [self.float_spelling(float(value)) for value in values]
        for _ in range(40):
            value = struct.unpack("<f", rng.getrandbits(32).to_bytes(4, "little"))[0]
            if math.isfinite(value):
                statements.append(f"{{let x:F32={repr(value)};println(x);}}")
                answers.append(self.float_spelling(value))
        self.differential("fn main(){"+"".join(statements)+"}", "\n".join(answers)+"\n")

    def test_generated_float_arithmetic(self):
        rng = random.Random(20261013)
        statements, answers = [], []
        for typ in ("F32", "F64"):
            for _ in range(40):
                a, b = rng.randint(-10000, 10000)/8, rng.randint(1, 10000)/8
                op = rng.choice(("+", "-", "*", "/"))
                value = {"+": lambda: a+b, "-": lambda: a-b,
                         "*": lambda: a*b, "/": lambda: a/b}[op]()
                if typ == "F32":
                    value = struct.unpack("<f", struct.pack("<f", value))[0]
                statements.append(f"{{let a:{typ}={a};let b:{typ}={b};println(a{op}b);}}")
                answers.append(self.float_spelling(value))
        self.differential("fn main(){"+"".join(statements)+"}", "\n".join(answers)+"\n")

    def test_float_subnormal_arithmetic_and_overflow(self):
        self.differential('''fn main(){
 let tiny:F32=1.401298464324817e-45;
 println(tiny/2.0);println(-tiny/2.0);println(tiny+tiny);
 let dtiny:F64=4.9406564584124654e-324;
 println(dtiny/2.0);println(-dtiny/2.0);println(dtiny+dtiny);
 let normal:F32=1.1754943508222875e-38;println(normal/2.0);
 let dnormal:F64=2.2250738585072014e-308;println(dnormal/2.0);
 let largest:F32=3.4028234663852886e38;
 println(largest*2.0);println(-largest*2.0);
 let dlargest:F64=1.7976931348623157e308;
 println(dlargest*2.0);println(-dlargest*2.0);
}''', "0.0\n-0.0\n2.8025969286496341e-45\n0.0\n-0.0\n9.8813129168249309e-324\n"
             "5.8774717541114375e-39\n1.1125369292536007e-308\ninf\n-inf\ninf\n-inf\n")

    def test_float_nonfinite_spelling_preserves_target_nan_sign(self):
        # Invalid A64 arithmetic produces positive default NaN; SSE produces
        # negative default NaN. Negation must flip each target's actual sign.
        source = "fn main(){println(1.0/0.0);println(-1.0/0.0);println(0.0/0.0);println(-(0.0/0.0));}"
        for opt in ("off", "basic"):
            compiled, output = self.compile(source, opt=opt)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            actual = self.execute(output)
            self.assertEqual((actual.returncode, actual.stdout, actual.stderr),
                             (0, "inf\n-inf\nnan\n-nan\n", ""))
            if platform.machine() == "x86_64":
                compiled, output = self.compile(source, target="x86_64-linux", opt=opt)
                self.assertEqual(compiled.returncode, 0, compiled.stderr)
                actual = subprocess.run([str(output)], capture_output=True, text=True, timeout=20)
                self.assertEqual((actual.returncode, actual.stdout, actual.stderr),
                                 (0, "inf\n-inf\n-nan\nnan\n", ""))

    def test_heap_strings_clone_move_fields_and_reference_replacement(self):
        self.differential('''
use std.mem;
#global[explc]
struct Pair<T>{left:T,right:T}
enum Label{Empty,Text(String)}
fn suffix(s:String)->String{return s+"!";}
fn id<T>(x:T)->T{return x;}
fn replace(p:&mut Pair<String>){p.left="ne"+"w";}
fn main(){
 let mut text="he"+"llo";let saved=text;text="different"+" value";
 println(saved);println(text);println(suffix(saved));println(saved);
 let mut p=Pair{left:"ori"+"ginal",right:"a\0"+"b"};let copy=id(p);
 replace(&mut p);println(p.left);println(copy.left);println(copy.right);println(len(copy.right));
 {let r=&mut p;*r=*r;}println(p.left);println(p.right=="a\0b");
 let mut label:Label=Label.Text("fi"+"rst");
 {let r=&mut label;*r=Label.Empty;*r=Label.Text("la"+"st");}
 println(match label{Label.Empty=>"empty",Label.Text(s)=>s});
 let mut number=int_to_str(-9223372036854775807-1);let old=std.mem.replace(&mut number,int_to_str(42));
 println(old);println(number);println(int_to_str(0));println(int_to_str(9223372036854775807));
 println(""+"");println(suffix(""));let empty="";let empty_copy=empty;println(empty_copy);
 println(arg(0)+"!");println(len("\uD55C"+"\uAE00"));
}''', "hello\ndifferent value\nhello!\nhello\nnew\noriginal\na\0b\n3\nnew\ntrue\n"
             "last\n-9223372036854775808\n42\n0\n9223372036854775807\n\n!\n\narg!\n6\n",
             args=("arg",))

    def test_box_functions_borrows_extraction_and_recursive_types(self):
        self.differential('''
use std.mem;
#global[explc]
struct Pair<T>{left:T,right:T}
enum Expr{Num(I64),Name(String),Add(Binary)}
struct Binary{left:Box<Expr>,right:Box<Expr>}
struct A<T>{value:T,next:Option<Box<B<T>>>}
struct B<T>{back:A<T>}
fn id<T>(x:T)->T{return x;}
fn six(a:Box<I8>,b:String,c:Box<F32>,d:Pair<String>,e:U64,f:Box<Unit>)->String{
 println(a.into_inner());println(c.into_inner());println(d.left);println(e);f.into_inner();return b;
}
fn eval(x:Expr)->I64{return match x{Expr.Num(n)=>n,Expr.Name(s)=>len(s),
 Expr.Add(b)=>eval(b.left.into_inner())+eval(b.right.into_inner())};}
fn edit(p:&mut Pair<String>){*p=Pair{left:"ne"+"w",right:"ri"+"ght"};}
fn main(){
 let call=six;println(call(box(i8(-7)),"ret"+"urn",box(f32(2.5)),
     Pair{left:"le"+"ft",right:"unused"},u64(18446744073709551615),box(())));
 let nested=id(box(box("in"+"ner")));println(nested.into_inner().into_inner());
 let mut p=box(Pair{left:"ol"+"d",right:"value"});edit(p.as_mut());println(p.as_ref().left);
 let previous=std.mem.replace(&mut p,box(Pair{left:"next",right:"item"}));
 println(previous.into_inner().right);println(p.into_inner().left);
 let tree=Expr.Add(Binary{left:box(Expr.Name("xe"+"n")),right:box(Expr.Num(7))});println(eval(tree));
 let a=A<I64>{value:1,next:Option.Some(box(B<I64>{back:A<I64>{value:2,next:Option<Box<B<I64>>>.None}}))};
 println(match a.next{Option.Some(b)=>b.into_inner().back.value,Option.None=>0});
 let (first,_)=id((box("fi"+"rst"),box("skip"+"ped")));println(first.into_inner());
}''', "-7\n2.5\nleft\n18446744073709551615\nreturn\ninner\nnew\nright\nnext\n10\n2\nfirst\n")

    def heap_trace(self, source, expected, *, stack=None, reserve=None, status=0):
        if not QEMU:
            self.skipTest("guest allocation ledger requires qemu-aarch64 -strace")
        options = [QEMU, "-strace"]
        if stack:
            options.extend(("-s", str(stack)))
        if reserve:
            options.extend(("-R", str(reserve)))
        for opt in ("off", "basic"):
            trace = None
            with self.subTest(opt=opt):
                compiled, output = self.compile(source, opt=opt)
                self.assertEqual(compiled.returncode, 0, compiled.stderr)
                actual = subprocess.run([*options, str(output)], capture_output=True,
                                        text=True, timeout=30)
                self.assertEqual(actual.returncode, status, actual.stderr[-4000:])
                self.assertEqual(actual.stdout, expected)
                trace = actual.stderr
            if trace is not None:
                yield trace

    def test_collection_storage_operations_and_byte_views(self):
        self.differential('''
#global[explc]
struct P{tag:U8,text:String,number:F32}
fn first<T>(v:Vec<T>)->T{return v.get(0);}
fn six(a:Vec<I16>,b:String,c:F32,d:Vec<P>,e:U64,f:Vec<Unit>)->String{
 println(a[0]);println(c);println(d[0].number);println(e);println(f.len());return b;
}
fn main(){
 let mut v=[1,2,3];v.push(4);v.push(5);v.swap(0,4);v.swap(2,2);println(v);
 println(v.replace(1,8));println(v.pop());v.push(9);println(v);
 let mut p:Vec<P>=[P{tag:u8(7),text:"hel"+"lo",number:f32(2.5)}];let saved=p;
 p.set(0,p.get(0));p[0]=P{tag:u8(8),text:"new"+" text",number:f32(3.5)};
 println(saved[0].text);println(p[0].tag);let borrowed=&saved[0];println(borrowed.text);
 let field=&saved[0].text;println(*field);let view=saved.as_slice();println(view.get(0).number);
 let empty=saved.slice(1,1);println(len(empty));println(first<I16>([i16(-7)]));
 let call=six;println(call([i16(-8)],"re"+"turn",f32(-0.0),saved,
  u64(18446744073709551615),[(),(),()]));
 println([["a"],["b"]]==[["a"],["b"]]);println([["a"]]!=[["c"]]);
 println([0.0]==[-0.0]);println([0.0/0.0]==[0.0/0.0]);
 let q:F32=0.0;println([f32(0.0)]==[f32(-0.0)]);println([q/q]==[q/q]);
 println(zeros(4));println(repeat(1.5,2));println(repeat(-7,3));println(zeros(0));
 let mut bytes:Vec<U8>=[];bytes.push(u8(97));bytes.push(u8(0));bytes.push(u8(255));
 let text=bytes.into_string();let byte_view=text.as_bytes();println(byte_view.len());println(byte_view[1]);println(byte_view[2]);
 let mut empty_bytes:Vec<U8>=[u8(1)];empty_bytes.pop();println(len(empty_bytes.into_string()));
 let mut units:Vec<Unit>=[(),()];units.pop();units.push(());units.swap(0,1);println(units.len());
}''', '[5, 2, 3, 4, 1]\n2\n1\n[5, 8, 3, 4, 9]\nhello\n8\nhello\nhello\n2.5\n0\n-7\n'
             '-8\n-0.0\n2.5\n18446744073709551615\n3\nreturn\ntrue\ntrue\ntrue\nfalse\ntrue\nfalse\n'
             '[0, 0, 0, 0]\n[1.5, 1.5]\n[-7, -7, -7]\n[]\n3\n0\n255\n0\n2\n')

    def test_collection_owned_elements_and_cleanup(self):
        source = '''
use std.iter;
use std.mem;
#global[explc]
struct Bag{items:Vec<String>,keep:String}
impl Bag{fn refill(&mut self){self.items=["af"+"ter"];}}
struct Tree{text:String,children:Vec<Box<Tree>>}
fn tree()->Box<Tree>{return box(Tree{text:"root",children:[
 box(Tree{text:"a"+"b",children:[]}),box(Tree{text:"c"+"d",children:[]})]});}
fn main(){
 let mut b=Bag{items:["be"+"fore"],keep:"ke"+"pt"};let old=b.items;b.refill();
 println(old[0]);println(b.items[0]);println(b.keep);
 let mut nested:Vec<Vec<String>>=[["a"+"b"],["c"+"d"]];let saved=nested;
 nested[0]=["ne"+"w"];println(saved[0][0]);println(nested[0][0]);
 let mut i=0;while i<25{
  let mut values:Vec<Box<Tree>>=[];values.push(tree());values.push(tree());values.push(tree());
  values.swap(0,2);let previous=values.replace(0,tree());let last=values.pop();values.push(tree());
  {let r=&mut values;*r=std.mem.replace(r,[tree()]);}
  for item in values.into_iter(){let inner=item.into_inner();}
  i=i+1;if i%2==0{let pending=tree();continue;}if i==23{let pending=tree();break;}
 }println(i);
}'''
        expected = 'before\nafter\nkept\nab\nnew\n23\n'
        self.differential(source, expected)
        if QEMU:
            for trace in self.heap_trace(source, expected):
                self.assertGreater(self.assert_balanced_heap(trace), 500)

    def test_deep_recursive_vec_clone_and_mixed_box_cleanup(self):
        programs = [
            ('''use std.mem;
#global[explc]
struct Node{text:String,children:Vec<Node>}
fn main(){let mut root=Node{text:"end",children:[]};let mut i=0;
 while i<10000{root=Node{text:"x"+"y",children:[std.mem.replace(&mut root,Node{text:"",children:[]})]};i=i+1;}
 let saved=root;root=Node{text:"new",children:[]};println(saved.text);println(root.text);}''', 'xy\nnew\n'),
            ('''struct Node{children:Vec<Box<Node>>}
fn main(){let mut root=box(Node{children:[]});let mut i=0;
 while i<10000{root=box(Node{children:[root]});i=i+1;}println(i);}''', '10000\n'),
        ]
        if QEMU:
            for source, expected in programs:
                for trace in self.heap_trace(source, expected, stack=65536):
                    self.assertGreaterEqual(self.assert_balanced_heap(trace), 20000)
        else:
            for source, expected in programs:
                self.differential(source, expected)

    def test_collection_stdlib(self):
        source = '''
use std.string;
use std.iter;
use std.hashmap;
#global[explc]
fn main(){
 let parts=std.string.split_byte("=a==",u8(61));println(parts.len());println(parts[1]);
 let words=std.string.split_ascii_whitespace(" a  b\\nc\\t");println(words.len());
 println(std.string.contains("abc","bc"));
 let mut map=std.hashmap.new<Box<String>>();let mut i=0;
 while i<40{map.insert(int_to_str(i),box("v"+int_to_str(i)));i=i+1;}
 println(map.len());let key=int_to_str(7);println(map.contains_key(&key));
 let value=map.remove(&key);println(match value{Option.Some(s)=>s.into_inner(),Option.None=>"missing"});
 println(map.len());let mut count=0;for (key,item) in map.into_iter(){count=count+1;}println(count);
 let mut sum=0;for value in [1,2,3].into_iter(){sum=sum+value;}println(sum);
}'''
        expected = '4\na\n3\ntrue\n40\ntrue\nv7\n39\n39\n6\n'
        self.differential(source, expected)
        if QEMU:
            for trace in self.heap_trace(source, expected):
                self.assertGreater(self.assert_balanced_heap(trace), 100)

    def test_collection_runtime_failures(self):
        for body, message in [
            ('let v=[1];println(v[-1]);', 'vector index out of bounds'),
            ('let v=[1];println(v[1]);', 'vector index out of bounds'),
            ('let mut v=[1];v.set(2,3);', 'vector index out of bounds'),
            ('let mut v=[1];v.replace(-1,3);', 'vector index out of bounds'),
            ('let mut v=[1];v.swap(0,1);', 'vector index out of bounds'),
            ('let mut v:Vec<Unit>=[];v.pop();', 'cannot pop from an empty vector'),
            ('let v=[1];let s=v.slice(-1,1);', 'slice range out of bounds'),
            ('let v=[1];let s=v.slice(1,0);', 'slice range out of bounds'),
            ('let v=[1];let s=v.slice(0,2);', 'slice range out of bounds'),
            ('let v=[1];let s=v.as_slice();println(s.get(-1));', 'slice index out of bounds'),
            ('let v=[1];let s=v.as_slice();println(s[1]);', 'slice index out of bounds'),
            ('zeros(-1);', 'zeros length cannot be negative'),
            ('repeat(1.5,-1);', 'repeat length cannot be negative'),
        ]:
            with self.subTest(body=body):
                self.differential('fn main(){'+body+'}', '', status=1, error=message)

    def test_arm64_target_defaults_and_option_order(self):
        for flags in ((), ('--opt=basic',), ('--jit=off',)):
            built, output = self.compile('fn main(){println([1,2]);}', flags=flags)
            self.assertEqual(built.returncode, 0, built.stderr)
            self.assertEqual(self.execute(output).stdout, '[1, 2]\n')
        for flags in (('--jit-report',), ('--jit=on',), ('--jit=on','--target=arm64-linux')):
            built, _ = self.compile('fn main(){}', flags=flags)
            self.assertEqual(built.returncode, 1, built.stderr)
            self.assertIn('JIT is not implemented', built.stderr)

    def assert_balanced_heap(self, trace, *, allow_failed=False):
        # Track addresses AND requested lengths. Counts alone hide double frees,
        # address reuse, leaked siblings, and wrong base/length for hidden headers.
        live, allocations = {}, 0
        for line in trace.splitlines():
            if " mmap(" in line:
                if allow_failed and re.search(r"\) = -1 errno=12", line):
                    continue
                match = re.search(r"mmap\(NULL,(\d+),.*\) = (0x[0-9a-f]+)", line)
                self.assertIsNotNone(match, line)
                length, address = int(match[1]), int(match[2], 16)
                self.assertGreater(length, 0, "empty values must not mmap zero bytes")
                self.assertNotIn(address, live, "an active allocation was overwritten")
                self.assertIn("PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0", line)
                live[address] = length
                allocations += 1
            elif " munmap(" in line:
                match = re.search(r"munmap\((0x[0-9a-f]+),(\d+)\) = 0$", line)
                self.assertIsNotNone(match, line)
                address, length = int(match[1], 16), int(match[2])
                self.assertIn(address, live, "unmapped unknown/already freed storage")
                self.assertEqual(live.pop(address), length, "wrong allocation extent")
        self.assertEqual(live, {}, "allocations survive normal scope cleanup")
        return allocations

    def test_ownership_flags_cleanup_on_branch_loop_return_and_try(self):
        source = '''
#global[explc]
enum Tree{Empty,Leaf(String),Branch(Box<Pair>)}
struct Pair{left:Tree,right:Tree}
struct Holder{item:Box<String>,text:String}
impl Holder{fn refill(&mut self){self.item=box("after"+" call");}}
fn tree()->Box<Tree>{return box(Tree.Branch(box(Pair{
 left:Tree.Leaf("le"+"ft"),right:Tree.Leaf(int_to_str(7))})));}
fn fail()->Result<I64,I64>{return Result.Err(7);}
fn pending(x:Box<Tree>,n:I64){}
fn early()->Result<I64,I64>{pending(tree(),fail()?);return Result.Ok(0);}
fn main(){
 let mut h=Holder{item:box("be"+"fore"),text:"ke"+"pt"};let old=h.item;
 h.refill();println(old.into_inner());println(*h.item.as_ref());println(h.text);
 let mut i=0;while i<40{
  let mut root=tree();root=tree();let taken=root.into_inner();let empty=box(Tree.Empty);
  assert(match early(){Result.Err(n)=>n==7,_=>false});
  {let nested=tree();}let conditional=if i%2==0{tree()}else{box(Tree.Leaf("other"+" branch"))};
  i=i+1;if i%2==0{let next=tree();continue;}if i==39{let last=tree();break;}
 }println(i);
}'''
        # A partially moved field is reinitialized by the callee; its caller flag
        # is activated by the elaborated Drop_flag after that call.
        expected = "before\nafter call\nkept\n39\n"
        self.differential(source, expected)
        if QEMU:
            for trace in self.heap_trace(source, expected):
                self.assertGreater(self.assert_balanced_heap(trace), 500)

    def test_deep_box_cleanup_with_bounded_stack(self):
        source = '''enum List{Empty,Link(Node)}struct Node{text:String,next:Box<List>}
fn main(){let mut list=List.Empty;let mut n=0;
 while n<20000{list=List.Link(Node{text:int_to_str(n),next:box(list)});n=n+1;}
 println(n);}'''
        # Building uses a loop, and destruction must not consume one call frame
        # per node. The 64KiB guest stack cannot hold 20,000 recursive destructors.
        if QEMU:
            for trace in self.heap_trace(source, "20000\n", stack=65536):
                self.assertEqual(self.assert_balanced_heap(trace), 40000)
        else:
            self.runner()
            for opt in ("off", "basic"):
                compiled, output = self.compile(source, opt=opt)
                self.assertEqual(compiled.returncode, 0, compiled.stderr)
                def small_stack():
                    resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
                actual = subprocess.run([str(output)], capture_output=True, text=True,
                                        preexec_fn=small_stack, timeout=30)
                self.assertEqual((actual.returncode, actual.stdout, actual.stderr),
                                 (0, "20000\n", ""))

    def test_recursive_box_branching_and_large_owned_payloads(self):
        source = '''enum Tree{Leaf(String),Branch(Pair)}struct Pair{left:Box<Tree>,right:Box<Tree>}
fn tree(n:I64)->Box<Tree>{if n==0{return box(Tree.Leaf("a"+"b"));}
 return box(Tree.Branch(Pair{left:tree(n-1),right:tree(n-1)}));}
struct Large{payload:String,tail:(I64,I64,I64)}
fn main(){let root=tree(6);let text="'''+"x"*70000+'''"+"tail";
 let copy=text;let b=box(Large{payload:copy,tail:(1,2,3)});
 let value=b.into_inner();println(len(value.payload));println(value.tail.2);}'''
        self.differential(source, "70004\n3\n")
        if QEMU:
            for trace in self.heap_trace(source, "70004\n3\n"):
                self.assertGreater(self.assert_balanced_heap(trace), 150)

    def test_mutual_generic_box_destruction(self):
        source = '''
struct A<T>{value:T,next:Option<Box<B<T>>>}
struct B<T>{text:String,next:Option<Box<A<T>>>}
struct Value{tag:I8,text:String}
fn build<T>(first:T,last:T)->Box<A<T>>{
 return box(A<T>{value:first,next:Option<Box<B<T>>>.Some(box(B<T>{
  text:"mid"+"dle",next:Option<Box<A<T>>>.Some(box(A<T>{
   value:last,next:Option<Box<B<T>>>.None}))}))});
}
fn main(){
 {let integer=build(i64(1),i64(2));}
 {let strings=build("fi"+"rst","la"+"st");}
 {let padded=build(Value{tag:i8(1),text:"first"+" value"},
                   Value{tag:i8(2),text:"last"+" value"});}
 println("done");
}'''
        self.differential(source, "done\n")
        if QEMU:
            for trace in self.heap_trace(source, "done\n"):
                self.assertGreater(self.assert_balanced_heap(trace), 15)
                # A<I64>, B<I64> and A<Value> use different payload extents.
                for length in (40, 56, 64):
                    self.assertIn(f"mmap(NULL,{length},", trace)

    def test_guest_allocation_failure_is_a_runtime_error(self):
        if not QEMU:
            self.skipTest("bounded guest VA failure injection requires qemu-aarch64")
        programs = [
            ('''enum List{Empty,Link(Node)}struct Node{next:Box<List>}
fn main(){let mut list=List.Empty;let mut n=0;
 while n<20000{list=List.Link(Node{next:box(list)});n=n+1;}}''', "Box allocation failed"),
            ('fn main(){let mut text="x";let mut n=0;while n<32{text=text+text;n=n+1;}}',
             "string allocation failed"),
        ]
        for source, message in programs:
            with self.subTest(message=message):
                for trace in self.heap_trace(source, "", stack=65536, reserve=33554432, status=1):
                    self.assertRegex(trace, r"mmap\(.*\) = -1 errno=12")
                    self.assertIn("xen runtime error: "+message, trace)
                    if message.startswith("Box"):
                        self.assertRegex(trace, r"app\.xen:\d+:\d+: xen runtime error:")
                    # Fatal allocation errors exit without unwinding, as on x86.

    def test_heap_runtime_boundaries(self):
        self.runner()
        for mode in ("large_box", "signed_overflow", "unsigned_wrap", "empty"):
            with self.subTest(mode=mode):
                output = self.root / mode
                built = subprocess.run(["dune", "exec", "tests/arm64_heap_fixture.exe", "--",
                                        mode, str(output)], cwd=REPO, capture_output=True,
                                       text=True, timeout=60)
                self.assertEqual(built.returncode, 0, built.stderr)
                status, expected = ((1, "") if "overflow" in mode or mode == "unsigned_wrap" else
                                    (0, "large\n" if mode == "large_box" else "empty\n"))
                actual = self.execute(output)
                self.assertEqual((actual.returncode, actual.stdout), (status, expected), actual.stderr)
                if status:
                    self.assertIn("string is too large", actual.stderr)
                else:
                    self.assertEqual(actual.stderr, "")
                if QEMU:
                    trace = subprocess.run([QEMU, "-strace", str(output)], capture_output=True,
                                           text=True, timeout=20)
                    self.assertEqual((trace.returncode, trace.stdout), (status, expected))
                    if mode == "large_box":
                        self.assertEqual(self.assert_balanced_heap(trace.stderr), 3)
                        self.assertIn("mmap(NULL,65552,", trace.stderr)
                    else:
                        self.assertNotIn(" mmap(", trace.stderr,
                                         "empty/overflow must be handled before allocation")

    def test_collection_size_boundaries_and_allocation_failure(self):
        self.runner()
        for mode in ('vec_multiply_overflow', 'vec_header_overflow', 'vec_growth_overflow'):
            output = self.root / mode
            built = subprocess.run(['dune','exec','tests/arm64_heap_fixture.exe','--',mode,str(output)],
                                   cwd=REPO, capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stderr)
            actual = self.execute(output)
            self.assertEqual((actual.returncode,actual.stdout), (1,''))
            self.assertIn('vector is too large', actual.stderr)
            if QEMU:
                trace = subprocess.run([QEMU,'-strace',str(output)],capture_output=True,text=True,timeout=20)
                self.assertNotIn(' mmap(', trace.stderr)
        if QEMU:
            for source in ('fn main(){zeros(50000000);}',
                           'fn main(){let mut v:Vec<I64>=[];let mut n=0;while n<5000000{v.push(n);n=n+1;}}'):
                for trace in self.heap_trace(source, '', stack=65536, reserve=33554432, status=1):
                    self.assertRegex(trace, r'mmap\(.*\) = -1 errno=12')
                    self.assertIn('vector allocation failed', trace)

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

    def assert_balanced_files(self, trace):
        live, opens = set(), 0
        for line in trace.splitlines():
            if " openat(" in line:
                match = re.search(r"openat\(.*\) = (\d+)$", line)
                if match:
                    fd = int(match[1])
                    self.assertNotIn(fd, live, "an active fd was overwritten")
                    live.add(fd)
                    opens += 1
            elif " close(" in line:
                match = re.search(r"close\((\d+)\) = 0$", line)
                self.assertIsNotNone(match, line)
                fd = int(match[1])
                self.assertIn(fd, live, "closed unknown/already closed fd")
                live.remove(fd)
        self.assertEqual(live, set(), "owned file descriptors survive cleanup")
        return opens

    def test_file_creation_transfer_offsets_and_close(self):
        source = '''
#global[explc]
fn relay<T>(v:T)->T{return v;}
fn inspect(f:&File)->Bool{return f.is_open();}
fn finish(f:&mut File){f.write("llo");f.close();f.close();}
fn main(){
 let mut out=open_write(arg(0));println(inspect(&out));out.write("hé");finish(&mut out);
 println(out.is_open());let input=open_read(arg(0));let mut moved=relay(input);
 println(moved.read());println(len(moved.read()));moved.close();moved.close();
 {let mut overwrite=open_write(arg(0));overwrite.write("short");}
 println(read_text(arg(0)));let mut file=open_read(arg(0));let view=file.read();
 let saved=view;file.close();println(saved);println(view);
}'''
        path = self.root / "hé-file.dat"
        self.differential(source, "true\nfalse\nhéllo\n0\nshort\nshort\nshort\n", args=(path,))
        self.assertEqual(path.read_bytes(), b"short")
        if QEMU:
            for opt in ("off", "basic"):
                built, output = self.compile(source, opt=opt)
                self.assertEqual(built.returncode, 0, built.stderr)
                actual = subprocess.run([QEMU, "-strace", str(output), str(path)],
                                        capture_output=True, text=True, timeout=30)
                self.assertEqual(actual.returncode, 0, actual.stderr)
                self.assertEqual(self.assert_balanced_files(actual.stderr), 5)
                self.assertGreater(self.assert_balanced_heap(actual.stderr), 10)

    def test_file_binary_bytes_and_growth_boundaries(self):
        source = '''fn main(){let mut f=open_read(arg(0));let s=f.read();
 let mut out=open_write(arg(1));out.write(s);out.close();f.close();
 let text=read_text(arg(0));print(text);}'''
        path, copy = self.root / "input.bin", self.root / "copy.bin"
        for length in (0, 1, 4095, 4096, 4097, 8192, 200000):
            data = (b"\0\xff\xc3\xa9abc" * ((length+6)//7))[:length]
            path.write_bytes(data)
            for opt in ("off", "basic"):
                with self.subTest(length=length, opt=opt):
                    built, output = self.compile(source, opt=opt)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    actual = subprocess.run([*self.runner(), str(output), str(path), str(copy)],
                                            capture_output=True, timeout=30)
                    self.assertEqual((actual.returncode, actual.stdout, actual.stderr), (0, data, b""))
                    self.assertEqual(copy.read_bytes(), data)
                    if QEMU:
                        actual = subprocess.run([QEMU, "-strace", str(output), str(path), str(copy)],
                                                capture_output=True, timeout=30)
                        self.assertEqual((actual.returncode, actual.stdout), (0, data))
                        trace = actual.stderr.decode()
                        self.assertEqual(self.assert_balanced_files(trace), 3)
                        self.assert_balanced_heap(trace)
                        if length:
                            self.assertIn(f"mmap(NULL,{length},", trace)
            if platform.machine() == "x86_64":
                built, output = self.compile(source, target="x86_64-linux")
                self.assertEqual(built.returncode, 0, built.stderr)
                actual = subprocess.run([str(output), str(path), str(copy)], capture_output=True, timeout=30)
                self.assertEqual((actual.returncode, actual.stdout, actual.stderr), (0, data, b""))
                self.assertEqual(copy.read_bytes(), data)

    def test_file_aggregate_and_recursive_cleanup(self):
        source = '''
use std.mem;
#global[explc]
struct Owner{file:File,label:String}
struct Pair{left:Owner,right:Owner}
struct Node{file:File,children:Vec<Box<Node>>}
enum Event{File(File),Empty}
fn owner()->Owner{return Owner{file:open_read("/dev/null"),label:"o"+"wned"};}
fn take(f:File){}
fn take_left(p:&mut Pair)->File{let f=p.left.file;p.left.file=open_read("/dev/null");return f;}
fn early()->Int{let a=owner();let b=box(owner());return 7;}
fn fail()->Result<Int,Int>{let a=owner();let b:Result<Int,Int>=Result.Err(1);return Result.Ok(b?);}
fn main(){
 let mut p=Pair{left:owner(),right:owner()};let mut f=take_left(&mut p);println(f.read());
 let partial=p.right.file;p.right.file=open_read("/dev/null");take(partial);
 let mut v:Vec<File>=[open_read("/dev/null"),open_read("/dev/null")];v.push(open_read("/dev/null"));
 v.swap(0,2);v.swap(1,1);v.set(0,open_read("/dev/null"));take(v.replace(1,open_read("/dev/null")));
 let mut popped=v.pop();popped.close();let moved=v;let wrapped=box(moved);
 let values:Vec<Owner>=[owner(),owner()];let mut boxed=box(owner());
 {let slot=boxed.as_mut();slot.file=open_read("/dev/null");}take(boxed.into_inner().file);
 let e=Event.File(open_read("/dev/null"));match e{Event.File(file)=>take(file),Event.Empty=>()};
 let empty=Event.Empty;let mut n=0;while n<500{let each=owner();n=n+1;if n%2==0{continue;}if n==499{break;}}
 println(early());println(match fail(){Result.Err(_)=>0,Result.Ok(n)=>n});
 let mut root=box(Node{file:open_read("/dev/null"),children:[]});let mut i=0;
 while i<2000{root=box(Node{file:open_read("/dev/null"),children:[root]});i=i+1;}println(i);
}'''
        expected = "\n7\n0\n2000\n"
        self.differential(source, expected)
        if QEMU:
            for trace in self.heap_trace(source, expected, stack=65536):
                self.assertGreater(self.assert_balanced_files(trace), 2500)
                self.assertGreater(self.assert_balanced_heap(trace), 4500)

    def test_file_low_descriptor_limit_and_fd_zero(self):
        source = '''#global[explc]
struct Holder{file:File}
fn take(h:&mut Holder)->File{let f=h.file;h.file=open_read("/dev/null");return f;}
fn main(){let mut h=Holder{file:open_read("/dev/null")};let mut i=0;
 while i<1000{{let f=take(&mut h);let v:Vec<File>=[open_read("/dev/null"),f];let b=box(v);}i=i+1;}
 let held=&h.file;println(held.is_open());}'''
        def limit_fds():
            resource.setrlimit(resource.RLIMIT_NOFILE, (32, 32))
        def close_stdin():
            os.close(0)
        for opt in ("off", "basic"):
            built, output = self.compile(source, opt=opt)
            self.assertEqual(built.returncode, 0, built.stderr)
            actual = subprocess.run([*self.runner(), str(output)], capture_output=True, text=True,
                                    preexec_fn=limit_fds, timeout=30)
            self.assertEqual((actual.returncode, actual.stdout, actual.stderr), (0, "true\n", ""))
            built, output = self.compile('fn main(){let mut f=open_read("/dev/null");'
                                         'println(f.is_open());f.close();println(f.is_open());}', opt=opt)
            self.assertEqual(built.returncode, 0, built.stderr)
            runner = [QEMU, "-strace"] if QEMU else self.runner()
            actual = subprocess.run([*runner, str(output)], capture_output=True, text=True,
                                    preexec_fn=close_stdin, timeout=30)
            self.assertEqual((actual.returncode, actual.stdout), (0, "true\nfalse\n"))
            if QEMU:
                self.assertRegex(actual.stderr, r'openat\(.*\) = 0\n')
                self.assertEqual(self.assert_balanced_files(actual.stderr), 1)
                self.assert_balanced_heap(actual.stderr)

    def test_file_proc_and_short_fifo_reads(self):
        self.differential('fn main(){let s=read_text("/proc/self/status");println(len(s)>0);}', "true\n")
        fifo = self.root / "pipe"
        os.mkfifo(fifo)
        chunks = (b"ab", b"\0c", b"d"*5000, b"end")
        for opt in ("off", "basic"):
            for builtin in (False, True):
                source = 'fn main(){'+('let s=read_text(arg(0));' if builtin else
                                       'let mut f=open_read(arg(0));let s=f.read();f.close();')+'print(s);}'
                built, output = self.compile(source, opt=opt)
                self.assertEqual(built.returncode, 0, built.stderr)
                errors = []
                def write_chunks():
                    try:
                        with fifo.open("wb", buffering=0) as stream:
                            for chunk in chunks:
                                stream.write(chunk)
                    except Exception as error:
                        errors.append(error)
                writer = threading.Thread(target=write_chunks, daemon=True)
                writer.start()
                actual = subprocess.run([*self.runner(), str(output), str(fifo)], capture_output=True, timeout=30)
                writer.join(timeout=5)
                self.assertFalse(writer.is_alive(), "FIFO writer remained blocked")
                self.assertEqual(errors, [])
                self.assertEqual((actual.returncode, actual.stdout, actual.stderr), (0, b"".join(chunks), b""))

    def test_file_errors_and_read_text_failure_cleanup(self):
        cases = [
            ('let f=open_read("/definitely/missing/xen-arm64");', "file open failed"),
            ('let f=open_write("/definitely/missing/xen-arm64/file");', "file open failed"),
            ('read_text("/definitely/missing/xen-arm64");', "file open failed"),
            ('let f=open_read("a\0b");', "file path contains an embedded NUL"),
            ('let f=open_write("a\0b");', "file path contains an embedded NUL"),
            ('read_text("a\0b");', "file path contains an embedded NUL"),
            ('let mut f=open_read("/dev/null");f.close();f.read();', "File is closed"),
            ('let mut f=open_write("/dev/null");f.close();f.write("x");', "File is closed"),
            ('let mut f=open_read("/dev/null");f.write("x");', "file write failed"),
            ('let mut f=open_write("/dev/null");f.read();', "file read failed"),
            ('let mut f=open_write("/dev/full");f.write("x");', "file write failed"),
            ('let mut f=open_read(".");f.read();', "file read failed"),
            ('read_text(".");', "file read failed"),
        ]
        for body, error in cases:
            with self.subTest(body=body):
                self.differential("fn main(){"+body+"}", "", status=1, error=error)
        if QEMU:
            for body in ('read_text(".");', 'read_text("/definitely/missing/xen-arm64");', 'read_text("a\0b");'):
                for trace in self.heap_trace("fn main(){"+body+"}", "", status=1):
                    self.assert_balanced_files(trace)
                    self.assert_balanced_heap(trace)

    def test_read_text_allocation_failure_releases_buffer_and_fd(self):
        if not QEMU:
            self.skipTest("bounded guest VA requires qemu-aarch64")
        path = self.root / "large-input"
        path.write_bytes(b"x" * 20000000)
        source = 'fn main(){read_text("'+str(path)+'");}'
        for trace in self.heap_trace(source, "", stack=65536, reserve=33554432, status=1):
            self.assertRegex(trace, r"mmap\(.*\) = -1 errno=12")
            self.assertIn("string allocation failed", trace)
            self.assertEqual(self.assert_balanced_files(trace), 1)
            self.assertGreater(self.assert_balanced_heap(trace, allow_failed=True), 5)

        # Geometric buffers leave reusable holes, so a VA limit alone cannot
        # distinguish final allocation from growth. This fixture leaves exactly
        # one free guest page and reads a short real proc file through EOF.
        built = subprocess.run(["dune", "build", "tests/arm64_heap_fixture.exe"], cwd=REPO,
                               capture_output=True, text=True, timeout=30)
        self.assertEqual(built.returncode, 0, built.stderr)
        output = self.root / "final-allocation"
        built = subprocess.run([str(REPO / "_build/default/tests/arm64_heap_fixture.exe"),
                                 "file_final_allocation_failure", str(output)],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(built.returncode, 0, built.stderr)
        actual = subprocess.run([QEMU, "-strace", "-R", "16777216", "-s", "65536", str(output)],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual((actual.returncode, actual.stdout), (0, "file-final-allocation\n"), actual.stderr[-4000:])
        self.assertRegex(actual.stderr, r"read\(.*\) = 0\n.*mmap\(NULL,6,.*\) = -1 errno=12")
        self.assertEqual(self.assert_balanced_files(actual.stderr), 1)
        self.assertGreater(self.assert_balanced_heap(actual.stderr, allow_failed=True), 10)

    def test_file_runtime_size_close_and_invalid_descriptor_contracts(self):
        self.runner()
        built = subprocess.run(["dune", "build", "tests/arm64_heap_fixture.exe"], cwd=REPO,
                               capture_output=True, text=True, timeout=30)
        self.assertEqual(built.returncode, 0, built.stderr)
        fixture = REPO / "_build/default/tests/arm64_heap_fixture.exe"
        for mode, expected in (("file_path_large", "file-size\n"), ("file_path_negative", "file-size\n"),
                               ("file_close_failure", "file-close\n"), ("file_read_failure", "file-read\n"),
                               ("file_write_failure", "file-write\n")):
            output = self.root / mode
            built = subprocess.run([str(fixture), mode, str(output)], capture_output=True, text=True, timeout=30)
            self.assertEqual(built.returncode, 0, built.stderr)
            actual = self.execute(output)
            self.assertEqual((actual.returncode, actual.stdout, actual.stderr), (0, expected, ""))
            if QEMU:
                traced = subprocess.run([QEMU, "-strace", str(output)], capture_output=True, text=True, timeout=30)
                self.assertEqual((traced.returncode, traced.stdout), (0, expected))
                self.assert_balanced_heap(traced.stderr)
                if mode.startswith("file_path_"):
                    self.assertNotIn(" mmap(", traced.stderr)
                    self.assertNotIn(" openat(", traced.stderr)
                if mode == "file_close_failure":
                    self.assertEqual(len(re.findall(r" close\(", traced.stderr)), 1)
                    self.assertIn("errno=9", traced.stderr)
                if mode == "file_write_failure":
                    self.assertEqual(len(re.findall(r"write\(-1,", traced.stderr)), 1)

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
            ("fn main(){}", "JIT is not implemented", ("--jit=on",)),
            ("fn main(){}", "JIT is not implemented", ("--jit=on", "--jit-report")),
            ('#global[bb]\nfn main(){let p=raw_alloc_int(1);raw_free_int(p);}', "type Ptr", ("--jit=off",)),
            ('fn main(){println(read_ints("missing"));}', "builtin 'read_ints'", ("--jit=off",)),
            ('fn main(){println(read_floats("missing"));}', "builtin 'read_floats'", ("--jit=off",)),
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
