# SPDX-License-Identifier: MIT OR Apache-2.0
"""Language operators against independent integer expectations on both CPUs."""
import random
import unittest

import low_level_test as low


TYPES = [(f"{sign}{bits}", bits, sign == "I")
         for bits in (8, 16, 32, 64) for sign in ("I", "U")]


def wrap(value, bits, signed):
    value &= (1 << bits) - 1
    return value - (1 << bits) if signed and value >= 1 << (bits - 1) else value


class OperatorTests(unittest.TestCase):
    setUp = low.LowLevelTests.setUp
    build = low.LowLevelTests.build
    run_binary = low.LowLevelTests.run_binary
    success = low.LowLevelTests.success

    def each_success(self, source, expected="42\n"):
        for target in low.TARGETS:
            for opt in ("off", "basic"):
                with self.subTest(target=target, opt=opt):
                    self.success(source, target, expected, opt)

    def test_integer_widths_constants_and_dynamic_values(self):
        rng = random.Random(20261016)
        for typ, bits, signed in TYPES:
            lo = -(1 << (bits - 1)) if signed else 0
            hi = (1 << (bits - int(signed))) - 1
            pairs = [(lo, hi), (hi, lo), (0, hi), (hi, hi), (lo, lo), (1, 0)]
            pairs += [(rng.randint(lo, hi), rng.randint(lo, hi)) for _ in range(4)]
            literal = lambda n: f"{typ.lower()}({n})"
            body = []
            for a, b in pairs:
                count = rng.randrange(bits)
                # Check constants (including basic folding) and unknown values
                # returned by a helper with an observable runtime call.
                for dynamic in (False, True):
                    lhs, rhs = str(a), str(b)
                    if dynamic:
                        lhs, rhs = f"id({literal(a)})", f"id({literal(b)})"
                    checks = [("a & b", a & b), ("a | b", a | b), ("a ^ b", a ^ b),
                              ("~a", ~a), ("+a", a), ("a+b", a+b),
                              ("a-b", a-b), ("a*b", a*b),
                              (f"a**{literal(count)}", pow(a, count, 1 << bits)),
                              (f"a<<{literal(count)}", a << count),
                              (f"a>>{literal(count)}", a >> count),
                              (f"a<<{literal(bits-1)}", a << (bits-1)),
                              (f"a>>{literal(bits-1)}", a >> (bits-1)),
                              (f"a<<{literal(0)}", a), (f"a>>{literal(0)}", a)]
                    if signed:
                        checks.append(("-a", -a))
                    if b and not (signed and a == lo and b == -1):
                        quotient = abs(a) // abs(b)
                        if (a < 0) != (b < 0):
                            quotient = -quotient
                        checks += [("a/b", quotient), ("a%b", a - quotient*b)]
                    body.append(f"{{let a:{typ}={lhs};let b:{typ}={rhs};" + "".join(
                        f"assert(({expr})=={literal(wrap(result, bits, signed))});"
                        for expr, result in checks) + "}")
            source = (f"fn id(x:{typ})->{typ}{{return x+{typ.lower()}(arg_count());}}"
                      "fn main(){#scope[opt]{" + "".join(body) + "println(42);}}")
            with self.subTest(typ=typ):
                self.each_success(source)

    def test_precedence_associativity_and_borrow(self):
        self.each_success("""
fn main(){#scope[explc,opt]{
 assert(1 | 2 ^ 3 & 6 == 1);
 assert(1 << 2 + 1 == 8); assert(32 >> 1 >> 2 == 4);
 assert(2 ** 3 ** 2 == 512); assert(-2 ** 2 == -4);assert((-2) ** 2 == 4);
 assert(2*3**2==18);assert(~2**3 == -9);
 assert(7 & 3 == 3 && 0 | 4 == 4 || false);
 assert(~1 & 7 == 6); assert(2*3+4<<1 == 20);
 let a=3;let b=16;let c=1;assert(a < b >> c);
 assert(a < b >> c && b >= a << c);
 let mut x=7;let r=&mut x;*r=6;assert(x & 3 == 2);
 let boxed=box(3);let view=&boxed;assert(**view==3);assert(2 * **view==6);
 println(42);
}}
""")

    def test_nested_generic_closers_and_speculation(self):
        self.each_success("""
fn id<T>(x:T)->T{return x;}
fn main(){#scope[opt]{
 let a:Vec<Vec<Int>>=[[42]];
 let b:Vec<Vec<Vec<Int>>>=[[[42]]];
 let c=id<Vec<Vec<Int>>>(a);
 let d=id<Vec<Vec<Vec<Int>>>>(b);
 assert(c[0][0]==42 && d[0][0][0]==42);
 let e:Vec<Int>=[42];assert(e[0]==42);
 let I8=8;let n=1;assert(n < I8 >> 1);assert(I8 >= n);
 let result=match true {true=>{if true {1<<2}else{0}},false=>{if false {println(0);} 4}};
 assert(result==4);println(42);
}}
""")

    def test_evaluation_order_and_logical_short_circuit(self):
        self.each_success("""
fn n(x:Int)->Int{print(x);return x;}
fn flag(x:Int,b:Bool)->Bool{print(x);return b;}
fn main(){#scope[opt]{
 assert(n(1)<<n(2)==4);println("");
 assert(n(3)&n(4)==0);println("");
 assert(n(5)|n(6)==7);println("");
 assert(n(7)^n(8)==15);println("");
 assert(!flag(1,false) || flag(2,false));println("");
 assert(!(flag(3,false) && flag(4,true)));println("");
 assert(flag(5,true) && flag(6,true));println("");
 assert(flag(7,false) || flag(8,true));println("");
 assert(false && (1<<64==0) || true);
 assert(true || (1>>(-1)==0));
 assert(false && (1/0==0) || true);
}}
""", "12\n34\n56\n78\n1\n3\n56\n78\n")

    def test_unary_plus_float_identity_and_arithmetic(self):
        self.each_success("""
fn main(){#scope[opt]{
 let a:F32=+1.5;let b:F64=+2.5;
 assert(+a==f32(1.5));assert(+b==2.5);
 assert(1.0/(+(-0.0))<0.0);
 assert(f32(1.0)/(+(-f32(0.0)))<f32(0.0));
 assert(a+f32(2.5)==f32(4.0));assert(b-1.5==1.0);
 assert(a*f32(2.0)==f32(3.0));assert(b/2.0==1.25);
 let n:U64=+18446744073709551615;assert(n==u64(18446744073709551615));
 assert(u64(++18446744073709551615)==n);
 assert(i64(+-9223372036854775808)==-9223372036854775808);
 assert(u8(+(255+1)-1)==u8(255));
 let mask:U8=~0;let bit:U8=1<<7;assert(mask==u8(255) && bit==u8(128));
 println(42);
}}
""")

    def test_shift_range_errors_survive_unused_results(self):
        for typ, bits, signed in TYPES:
            counts = [bits, bits+1, (1 << (bits-int(signed)))-1]
            if signed:
                counts.append(-1)
            for operator in ("<<", ">>"):
                for count in counts:
                    for dynamic in (False, True):
                        value = f"{typ.lower()}({count})"
                        if dynamic:
                            value = f"id({value})"
                        source = (f"fn id(x:{typ})->{typ}{{return x+{typ.lower()}(arg_count());}}"
                                  f"fn main(){{#scope[opt]{{print(1);{typ.lower()}(1){operator}{value};print(2);}}}}")
                        for target in low.TARGETS:
                            for opt in ("off", "basic"):
                                with self.subTest(typ=typ, operator=operator, count=count,
                                                  dynamic=dynamic, target=target, opt=opt):
                                    built, output = self.build(source, target, opt)
                                    self.assertEqual(built.returncode, 0, built.stderr)
                                    actual = self.run_binary(output, target)
                                    self.assertEqual((actual.returncode, actual.stdout), (1, "1"), actual.stderr)
                                    self.assertIn("shift count out of range", actual.stderr)

    def test_invalid_operand_types(self):
        expressions = ["true & false", "true | false", "true ^ false", "~true", "+true",
                       "~1.0", "1.0<<2.0", "1.0>>2.0", "1.0&2.0", "1.0|2.0", "1.0^2.0",
                       "1&&2", "1||2", "!1", "i8(1)<<i64(1)", "u8(1)|i8(1)",
                       "u64(1)>>i64(1)", '"a"&"b"', '"a"<<"b"',
                       "u8(+256)", "i8(+128)", "u8(+-1)", "f32(+3.5e38)"]
        for expression in expressions:
            for target in low.TARGETS:
                with self.subTest(expression=expression, target=target):
                    built, _ = self.build(f"fn main(){{{expression};}}", target)
                    self.assertEqual(built.returncode, 1, built.stderr)
                    self.assertIn("app.xen:", built.stderr)
                    self.assertNotIn("internal", built.stderr.lower())

    def test_shift_error_after_operand_effects(self):
        source = ('fn n(x:Int)->Int{print(x);return x;}'
                  'fn main(){#scope[opt]{n(3)<<n(64);print(9);}}')
        for target in low.TARGETS:
            for opt in ("off", "basic"):
                with self.subTest(target=target, opt=opt):
                    built, output = self.build(source, target, opt)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    actual = self.run_binary(output, target)
                    self.assertEqual((actual.returncode, actual.stdout), (1, "364"), actual.stderr)
                    self.assertIn("shift count out of range", actual.stderr)

    def test_integer_power_errors_and_large_exponents(self):
        self.each_success('fn main(){#scope[opt]{assert(0**0==1);assert(u64(0)**u64(18446744073709551615)==u64(0));'
                          'assert(u64(1)**u64(18446744073709551615)==u64(1));'
                          'assert(u64(18446744073709551615)**u64(18446744073709551615)==u64(18446744073709551615));'
                          'assert((-1)**9223372036854775807 == -1);println(42);}}')
        for typ in ("I8", "I16", "I32", "I64"):
            source = (f'fn exponent()->{typ}{{print(2);return -1;}}'
                      f'fn main(){{#scope[opt]{{print(1);{typ.lower()}(3)**exponent();print(9);}}}}')
            for target in low.TARGETS:
                for opt in ("off", "basic"):
                    with self.subTest(typ=typ, target=target, opt=opt):
                        built, output = self.build(source, target, opt)
                        self.assertEqual(built.returncode, 0, built.stderr)
                        actual = self.run_binary(output, target)
                        self.assertEqual((actual.returncode, actual.stdout), (1, "12"), actual.stderr)
                        self.assertIn("negative integer exponent", actual.stderr)


if __name__ == "__main__":
    unittest.main()
