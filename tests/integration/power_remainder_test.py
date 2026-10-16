# SPDX-License-Identifier: MIT OR Apache-2.0
"""Native portable power/remainder: IEEE bits, independent oracle and linking."""
import math
import random
import struct
import unittest

import low_level_test as low


def bits(value, width):
    return int.from_bytes(struct.pack("<f" if width == 32 else "<d", value), "little")


def number(value, width):
    return struct.unpack("<f" if width == 32 else "<d",
                         value.to_bytes(width // 8, "little"))[0]


def rounded(value, width):
    try:
        return number(bits(value, width), width)
    except OverflowError:
        return math.copysign(math.inf, value)


def power(x, y):
    try:
        return math.pow(x, y)
    except OverflowError:
        return -math.inf if x < 0 and y.is_integer() and y % 2 else math.inf
    except ValueError:
        if x == 0 and y < 0:
            return math.copysign(math.inf, x) if y.is_integer() and y % 2 else math.inf
        return math.nan


def remainder(x, y):
    try:
        return math.fmod(x, y)
    except ValueError:
        return math.nan


SOURCE = """
#global[bb]
fn from64(v:U64)->F64{
 let p=raw_alloc<U64>(1);raw_store(p,0,v);
 let r=raw_load(ptr_from_addr<F64>(ptr_addr(p),1),0);raw_free(p);return r;
}
fn bits64(v:F64)->U64{
 let p=raw_alloc<F64>(1);raw_store(p,0,v);
 let r=raw_load(ptr_from_addr<U64>(ptr_addr(p),1),0);raw_free(p);return r;
}
fn from32(v:U32)->F32{
 let p=raw_alloc<U32>(1);raw_store(p,0,v);
 let r=raw_load(ptr_from_addr<F32>(ptr_addr(p),1),0);raw_free(p);return r;
}
fn bits32(v:F32)->U32{
 let p=raw_alloc<F32>(1);raw_store(p,0,v);
 let r=raw_load(ptr_from_addr<U32>(ptr_addr(p),1),0);raw_free(p);return r;
}
fn pow64(x:F64,y:F64)->F64{return x**y;}
fn pow32(x:F32,y:F32)->F32{return x**y;}
fn rem64(x:F64,y:F64)->F64{return x%y;}
fn rem32(x:F32,y:F32)->F32{return x%y;}
"""


class PowerRemainderTests(unittest.TestCase):
    setUp = low.LowLevelTests.setUp
    build = low.LowLevelTests.build
    run_binary = low.LowLevelTests.run_binary
    success = low.LowLevelTests.success

    def check_values(self, cases, operation, width, tolerance):
        # Reference input values are rounded before applying the oracle.
        pairs = [(rounded(x, width), rounded(y, width)) for x, y in cases]
        expected = [rounded((power if operation == "pow" else remainder)(x, y), width)
                    for x, y in pairs]
        body = "".join(f"println(bits{width}({operation}{width}(from{width}(u{width}({bits(x,width)})),"
                       f"from{width}(u{width}({bits(y,width)})))));" for x, y in pairs)
        source = SOURCE + "fn main(){#scope[bb,opt]{" + body + "}}"
        for target in low.TARGETS:
            for opt in ("off", "basic"):
                with self.subTest(target=target, opt=opt, operation=operation, width=width):
                    built, output = self.build(source, target, opt)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    data = output.read_bytes()
                    phoff = struct.unpack_from("<Q", data, 32)[0]
                    size, count = struct.unpack_from("<HH", data, 54)
                    self.assertNotIn(3, [struct.unpack_from("<I", data, phoff+i*size)[0]
                                         for i in range(count)], "arithmetic unexpectedly requires a dynamic loader")
                    actual = self.run_binary(output, target)
                    self.assertEqual(actual.returncode, 0, actual.stderr)
                    self.assertEqual(actual.stderr, "")
                    rows = actual.stdout.splitlines()
                    self.assertEqual(len(rows), len(expected))
                    for index, (raw, reference) in enumerate(zip(rows, expected)):
                        raw = int(raw)
                        value = number(raw, width)
                        if math.isnan(reference):
                            self.assertTrue(math.isnan(value), (pairs[index], value))
                        elif reference == 0 or math.isinf(reference):
                            self.assertEqual(raw, bits(reference, width), (pairs[index], value, reference))
                        else:
                            self.assertTrue(math.isfinite(value), (pairs[index], value, reference))
                            self.assertNotEqual(value, 0.0, (pairs[index], reference))
                            self.assertEqual(math.copysign(1, value), math.copysign(1, reference))
                            self.assertLessEqual(abs(raw-bits(reference,width)), tolerance,
                                                 (pairs[index], value, reference, operation, width))

    def test_power_f64_boundaries_and_random_values(self):
        cases = [(9., .5), (27., 1./3.), (2., -1074.), (2., -1075.), (2., 1023.),
                 (2., 1024.), (.5, 1074.), (-2., -1073.), (-2., 1023.),
                 (1e-300, .5), (1e300, -.5), (math.nextafter(1., 2.), 2.**52),
                 (math.nextafter(1., 0.), 2.**53), (math.nextafter(1., 2.), 2.**64),
                 (math.nextafter(1., 0.), 2.**65), (5e-324, .25), (5e-324, -1.),
                 (float.fromhex('0x1.fffffffffffffp+1023'), 1.), (1.5, 2147483649.),
                 (-1.5, -2147483649.), (-1.0001, 4294967295.)]
        rng = random.Random(20261017)
        cases += [(math.ldexp(rng.uniform(1., 2.), rng.randint(-1000, 1000)),
                   rng.uniform(-8., 8.)) for _ in range(45)]
        cases += [(-rng.uniform(.1, 8.), float(rng.randint(-32, 32))) for _ in range(12)]
        cases += [(math.nextafter(1., 2.), value) for value in (1e9, -1e9, 1e15, -1e15, 1e20, -1e20)]
        self.check_values(cases, "pow", 64, 2)

    def test_power_f32(self):
        cases = [(9., .5), (2., -149.), (2., -150.), (2., 127.), (2., 128.),
                 (-2., 129.), (1e-30, .5), (1e30, -2.), (-8., 3.), (-8., 1.5),
                 (float.fromhex('0x1.fffffep+127'), 1.)]
        rng = random.Random(1057)
        cases += [(math.ldexp(rng.uniform(1., 2.), rng.randint(-125, 125)),
                   rng.uniform(-8., 8.)) for _ in range(45)]
        self.check_values(cases, "pow", 32, 1)

    def test_power_ieee_special_values(self):
        cases = [(x, y) for x in (0., -0., 1., -1., 2., -2., math.inf, -math.inf, math.nan)
                 for y in (0., -0., 1., -1., 2., 3., -3., .5, -.5, math.inf, -math.inf, math.nan)]
        for width in (32, 64):
            self.check_values(cases, "pow", width, 1 if width == 32 else 2)

    def test_remainder_exact_bits(self):
        rng = random.Random(207)
        for width in (32, 64):
            cases = [(x, y) for x in (0., -0., 5.5, -5.5, math.inf, -math.inf, math.nan)
                     for y in (0., -0., 2., -2., math.inf, -math.inf, math.nan)]
            samples = ([5e-324, 1e-320, 2.2250738585072014e-308, 1e308] if width == 64
                       else [2.**-149, 2.**-140, 2.**-126, 2.**127])
            cases += [(x, y) for x in samples for y in samples]
            cases += [(math.copysign(x, sign), y) for x in samples for y in (3., .3) for sign in (-1., 1.)]
            for _ in range(24):
                limit = 1023 if width == 64 else 127
                x = math.ldexp(rng.uniform(-2., 2.), rng.randint(-limit, limit))
                y = math.ldexp(rng.uniform(.5, 1.), rng.randint(-limit, limit))
                cases.append((x, y))
            self.check_values(cases, "rem", width, 0)

    def test_math_helpers_preserve_user_call_depth_and_state(self):
        source = ("struct V{x:Int}fn id<T>(v:T)->T{return v;}fn xmath_pow64()->Int{return 7;}"
                  "fn f(n:Int)->F64{if n==0{return 9.0**0.5+5.5%2.0;}return f(n-1);}"
                  "fn main(){#scope[opt]{let v=id(V{x:xmath_pow64()});assert(v.x==7);"
                  "assert(f(4094)==4.5);println(42);}}")
        for target in low.TARGETS:
            for opt in ("off", "basic"):
                with self.subTest(target=target, opt=opt):
                    self.success(source, target, opt=opt)


if __name__ == "__main__":
    unittest.main()
