# SPDX-License-Identifier: Apache-2.0
"""Whole-language program generators for Xen.

Design goals
------------
1. Cover every *supported* language feature listed in docs/status-and-limitations.md.
2. Mix many features in a single program so cross-feature edge cases appear.
3. Maintain a Python-side oracle (expected stdout) for well-typed programs.
4. Also emit ill-typed / noise / contextual probes for check-only sweeps.

Unsupported features (must NOT be generated as "should pass"):
  pointer arithmetic, match guards, String index/mutate, Slice return/escape,
  into_iter/map/filter, package manifests, etc.
"""

from __future__ import annotations

import random
from typing import Callable

from grammar import Program, xen_string, wrap_main
from oracle import (
    INTEGER_TYPES,
    float_op,
    limits,
    trunc_div,
    trunc_mod,
    wrap_integer,
)

INT_NAMES = [n for n in INTEGER_TYPES if n != "Int"]
ARITH = ["+", "-", "*"]


class RNG:
    def __init__(self, seed: int | None = None):
        self.r = random.Random(seed)

    def choice(self, xs):
        return self.r.choice(list(xs))

    def randint(self, a, b):
        return self.r.randint(a, b)

    def random(self):
        return self.r.random()

    def sample(self, xs, k):
        return self.r.sample(list(xs), k)

    def shuffle(self, xs):
        xs = list(xs)
        self.r.shuffle(xs)
        return xs

    def boolean(self, p: float = 0.5) -> bool:
        return self.r.random() < p

    def int_in(self, ty: str) -> int:
        lo, hi = limits(ty)
        if self.boolean(0.2):
            pool = [lo, hi, 0, 1]
            if lo < 0:
                pool.append(-1)
            pool = [v for v in pool if lo <= v <= hi]
            return self.choice(pool)
        # keep values moderate for readable tests / avoid extreme mul overflow noise
        span = min(hi, 200) - max(lo, -200)
        if span <= 0:
            return self.randint(lo, hi)
        return self.randint(max(lo, -200), min(hi, 200))


# ---------------------------------------------------------------------------
# Full feature bag — one emitter per supported surface area
# ---------------------------------------------------------------------------

ALL_FEATURES = [
    "numeric",
    "float",
    "bool_logic",
    "string",
    "vec",
    "slice",
    "bytes_bridge",
    "control",
    "if_expr",
    "shadow_block",
    "struct",
    "enum_match",
    "option_result",
    "result_try",
    "recursive_generic",
    "owning_box",
    "generic",
    "fn_value",
    "borrow",
    "mut_borrow",
    "iter",
    "range",
    "conversion",
    "std_convert",
    "std_env",
    "std_string",
    "std_fs_io",
    "tuple",
    "builtins_vec",  # zeros / repeat
    "assert",
    "file",
    "bb",
    "modules",
]


class Ctx:
    """Mutable generation context shared across emitters."""

    def __init__(self, rng: RNG):
        self.rng = rng
        self.preamble: list[str] = []
        self.imports: list[str] = []
        self.caps: list[str] = []
        self.stmts: list[str] = []
        self.expected: list[str] = []
        self.features_used: set[str] = set()
        self.temp_paths: list[str] = []
        self.has_named_type = False  # struct/enum present — interacts with known crash

    def need_cap(self, cap: str) -> None:
        if cap not in self.caps:
            self.caps.append(cap)

    def ensure_preamble(self, needle: str, lines: list[str]) -> None:
        blob = "\n".join(self.preamble)
        if needle not in blob:
            self.preamble.extend(lines)

    def add_import(self, line: str) -> None:
        if line not in self.imports:
            self.imports.append(line)


# ---- emitters --------------------------------------------------------------

def emit_numeric(ctx: Ctx) -> None:
    rng = ctx.rng
    ty = rng.choice(INT_NAMES)
    a = rng.int_in(ty)
    b = rng.int_in(ty)
    # Known runtime crash: narrow int `let r=a+0` + later empty Vec + named type.
    if b == 0 and ty not in ("I64", "U64", "Int") and ctx.has_named_type:
        b = 1 if limits(ty)[1] >= 1 else limits(ty)[0]
    op = rng.choice(ARITH)
    result = wrap_integer({"+": a + b, "-": a - b, "*": a * b}[op], ty)
    ctx.stmts.append(f"let a:{ty}={a};let b:{ty}={b};let r:{ty}=a{op}b;println(r);")
    ctx.expected.append(str(result))
    if rng.boolean(0.55):
        div_b = b if b != 0 else (1 if limits(ty)[1] >= 1 else limits(ty)[0])
        lo, _ = limits(ty)
        if INTEGER_TYPES[ty][1] and a == lo and div_b == -1:
            div_b = 1
        # rebind if we changed divisor
        if div_b != b:
            ctx.stmts.append(f"let b2:{ty}={div_b};println(a/b2);println(a%b2);")
            q, rem = trunc_div(a, div_b), trunc_mod(a, div_b)
        else:
            ctx.stmts.append("println(a/b);println(a%b);")
            q, rem = trunc_div(a, b), trunc_mod(a, b)
        ctx.expected.extend([str(q), str(rem)])
    if rng.boolean(0.3) and INTEGER_TYPES[ty][1]:
        # unary negation on a fresh value
        v = rng.int_in(ty)
        # avoid negating min int if that would overflow — xen may wrap
        lo, hi = limits(ty)
        if v == lo:
            v = lo + 1 if lo < hi else v
        neg = wrap_integer(-v, ty)
        ctx.stmts.append(f"let nu:{ty}={v};let nn:{ty}=-nu;println(nn);")
        ctx.expected.append(str(neg))


def emit_float(ctx: Ctx) -> None:
    rng = ctx.rng
    ty = rng.choice(["F32", "F64"])
    values = [-8.0, -1.5, -0.5, 0.0, 0.5, 1.0, 1.5, 8.0]
    left, right = rng.choice(values), rng.choice(values)
    op = rng.choice(["+", "-", "*", "/"])
    if op == "/" and right == 0.0:
        right = 0.5
    result = float_op(op, left, right, ty)
    ctor = ty.lower()

    def lit(v: float) -> str:
        if v == 0.0 and str(v).startswith("-"):
            return "-0.0"
        return repr(v)

    ctx.stmts.append(
        f"let fa:{ty}={ctor}({lit(left)});let fb:{ty}={ctor}({lit(right)});println(fa{op}fb);"
    )
    ctx.expected.append(repr(result))


def emit_bool_logic(ctx: Ctx) -> None:
    rng = ctx.rng
    a, b = rng.boolean(), rng.boolean()
    ctx.stmts.append(
        f"println({str(a).lower()}&&{str(b).lower()});"
        f"println({str(a).lower()}||{str(b).lower()});"
        f"println(!{str(a).lower()});"
    )
    ctx.expected.extend([
        str(a and b).lower(),
        str(a or b).lower(),
        str(not a).lower(),
    ])
    # comparison producing Bool
    x, y = rng.randint(-5, 5), rng.randint(-5, 5)
    ctx.stmts.append(f"println({x}<{y});println({x}=={y});")
    ctx.expected.extend([str(x < y).lower(), str(x == y).lower()])


def emit_string(ctx: Ctx) -> None:
    rng = ctx.rng
    alphabet = "abcXYZ019 _-"

    def s():
        return "".join(rng.choice(alphabet) for _ in range(rng.randint(0, 6)))

    a, b = s(), s()
    ctx.stmts.append(
        f"let sa={xen_string(a)};let sb={xen_string(b)};"
        f"println(sa+sb);println(len(sa));println(sa==sb);"
    )
    ctx.expected.extend([a + b, str(len(a)), str(a == b).lower()])
    if rng.boolean(0.5):
        n = rng.randint(-20, 20)
        ctx.stmts.append(f"println(int_to_str({n}));")
        ctx.expected.append(str(n))


def emit_vec(ctx: Ctx) -> None:
    rng = ctx.rng
    n = rng.randint(0, 5)
    values = [rng.randint(-40, 40) for _ in range(n)]
    ctx.stmts.append("let mut v:Vec<Int>=[];")
    model: list[int] = []
    for val in values:
        ctx.stmts.append(f"v.push({val});")
        model.append(val)
    if model and rng.boolean(0.6):
        idx = rng.randint(0, len(model) - 1)
        nv = rng.randint(-40, 40)
        ctx.stmts.append(f"v.set({idx},{nv});")
        model[idx] = nv
    if model and rng.boolean(0.45):
        ctx.stmts.append("println(v.pop());")
        ctx.expected.append(str(model.pop()))
    ctx.stmts.append("println(v.len());")
    ctx.expected.append(str(len(model)))
    for i, val in enumerate(model):
        ctx.stmts.append(f"println(v.get({i}));")
        ctx.expected.append(str(val))
    if model and rng.boolean(0.5):
        idx = rng.randint(0, len(model) - 1)
        ctx.stmts.append(
            f"let cloned=v;v.set({idx},{model[idx]+1});"
            f"println(cloned.get({idx}));println(v.get({idx}));"
        )
        ctx.expected.extend([str(model[idx]), str(model[idx] + 1)])
        model[idx] = model[idx] + 1
    if len(model) >= 1 and rng.boolean(0.35):
        # vec equality
        ctx.stmts.append("let v2=v;println(v==v2);")
        ctx.expected.append("true")


def emit_slice(ctx: Ctx) -> None:
    rng = ctx.rng
    values = [rng.randint(-20, 20) for _ in range(rng.randint(2, 5))]
    lit = ",".join(str(v) for v in values)
    ctx.stmts.append(f"let mut sv:Vec<Int>=[{lit}];")
    ctx.stmts.append("let sl:Slice<Int>=sv.as_slice();")
    idx = rng.randint(0, len(values) - 1)
    ctx.stmts.append(f"println(sl.get({idx}));println(sl.len());")
    ctx.expected.extend([str(values[idx]), str(len(values))])
    # subslice
    start = rng.randint(0, len(values) - 1)
    end = rng.randint(start, len(values))
    ctx.stmts.append(f"let sub:Slice<Int>=sv.slice({start},{end});println(sub.len());")
    ctx.expected.append(str(end - start))
    if end > start:
        ctx.stmts.append("println(sub.get(0));")
        ctx.expected.append(str(values[start]))


def emit_bytes_bridge(ctx: Ctx) -> None:
    rng = ctx.rng
    alphabet = "ABCxyz01"
    text = "".join(rng.choice(alphabet) for _ in range(rng.randint(1, 5)))
    ctx.stmts.append(f"let bt={xen_string(text)};let bsl=bt.as_bytes();println(bsl.len());")
    ctx.expected.append(str(len(text.encode("utf-8"))))
    # Vec<U8> -> String
    codes = [rng.randint(65, 90) for _ in range(rng.randint(1, 4))]
    elems = ",".join(f"u8({c})" for c in codes)
    ctx.stmts.append(
        f"let data:Vec<U8>=[{elems}];let rebuilt=data.into_string();println(rebuilt);"
    )
    ctx.expected.append("".join(chr(c) for c in codes))


def emit_control(ctx: Ctx) -> None:
    rng = ctx.rng
    limit = rng.randint(0, 8)
    initial = rng.randint(-15, 15)
    continue_at = rng.randint(0, limit + 1)
    break_at = rng.randint(0, limit + 1)
    total = initial
    index = 0
    while index < limit:
        index += 1
        if index == continue_at:
            continue
        total = total + index if index % 2 == 0 else total - index
        if index == break_at:
            break
    ctx.stmts.append(
        f"let mut i=0;let mut total={initial};"
        f"while i<{limit}{{i=i+1;if i=={continue_at}{{continue;}}"
        f"if i%2==0{{total=total+i;}}else{{total=total-i;}}"
        f"if i=={break_at}{{break;}}}}println(total);"
    )
    ctx.expected.append(str(total))


def emit_if_expr(ctx: Ctx) -> None:
    rng = ctx.rng
    flag = rng.boolean()
    left, right = rng.randint(-20, 20), rng.randint(-20, 20)
    # typed vars avoid bare-literal left asymmetry
    ctx.stmts.append(
        f"let lx:Int={left};let rx:Int={right};"
        f"let picked=if {str(flag).lower()}{{lx}}else{{rx}};println(picked);"
    )
    ctx.expected.append(str(left if flag else right))


def emit_shadow_block(ctx: Ctx) -> None:
    rng = ctx.rng
    outer = rng.randint(-10, 10)
    delta = rng.randint(-5, 5)
    ctx.stmts.append(
        f"{{let x={outer};{{let x=x+{delta};println(x);}}println(x);}}"
    )
    ctx.expected.extend([str(outer + delta), str(outer)])


def emit_struct(ctx: Ctx) -> None:
    rng = ctx.rng
    ctx.has_named_type = True
    ctx.ensure_preamble("struct Point", ["struct Point{x:Int,y:Int}"])
    x, y = rng.randint(-20, 20), rng.randint(-20, 20)
    ctx.stmts.append(f"let p=Point{{x:{x},y:{y}}};println(p.x);println(p.y);")
    ctx.expected.extend([str(x), str(y)])
    if rng.boolean(0.4):
        ctx.ensure_preamble(
            "struct Pair",
            ["struct Pair{a:Int,b:Int}", "impl Pair{fn sum(&self)->Int{return self.a+self.b;}}"],
        )
        a, b = rng.randint(-10, 10), rng.randint(-10, 10)
        ctx.stmts.append(f"let pr=Pair{{a:{a},b:{b}}};println(pr.sum());")
        ctx.expected.append(str(a + b))


def emit_enum_match(ctx: Ctx) -> None:
    rng = ctx.rng
    ctx.has_named_type = True
    ctx.ensure_preamble(
        "enum Choice",
        ["enum Choice{First(Int),Second((Int,Int))}"],
    )
    if rng.boolean():
        v = rng.randint(-30, 30)
        ctx.stmts.append(
            f"let ch=Choice.First({v});"
            f"println(match ch{{Choice.First(x)=>x,Choice.Second((a,b))=>a+b}});"
        )
        ctx.expected.append(str(v))
    else:
        a, b = rng.randint(-20, 20), rng.randint(-20, 20)
        ctx.stmts.append(
            f"let ch=Choice.Second(({a},{b}));"
            f"println(match ch{{Choice.First(x)=>x,Choice.Second((a,b))=>a+b}});"
        )
        ctx.expected.append(str(a + b))


def emit_option_result(ctx: Ctx) -> None:
    rng = ctx.rng
    if rng.boolean():
        v = rng.randint(-20, 20)
        ctx.stmts.append(
            f"let o:Option<Int>=Option.Some({v});"
            f"println(match o{{Option.Some(x)=>x,Option.None=>0}});"
        )
        ctx.expected.append(str(v))
    else:
        ctx.stmts.append(
            "let o2:Option<Int>=Option.None;"
            "println(match o2{Option.Some(x)=>x,Option.None=>-1});"
        )
        ctx.expected.append("-1")
    if rng.boolean(0.7):
        if rng.boolean():
            v = rng.randint(-15, 15)
            ctx.stmts.append(
                f"let rs:Result<Int,Int>=Result.Ok({v});"
                f"println(match rs{{Result.Ok(x)=>x,Result.Err(e)=>e}});"
            )
            ctx.expected.append(str(v))
        else:
            e = rng.randint(-15, 15)
            ctx.stmts.append(
                f"let rs:Result<Int,Int>=Result.Err({e});"
                f"println(match rs{{Result.Ok(x)=>x,Result.Err(e)=>e}});"
            )
            ctx.expected.append(str(e))


def emit_generic(ctx: Ctx) -> None:
    rng = ctx.rng
    ctx.has_named_type = True
    ctx.ensure_preamble(
        "fn identity",
        [
            "fn identity<T>(value:T)->T{return value;}",
            "struct Box<T>{value:T}",
            "impl<T> Box<T>{fn get(&self)->T{return self.value;}}",
        ],
    )
    v = rng.randint(-40, 40)
    text = "".join(rng.choice("abXY01") for _ in range(rng.randint(1, 5)))
    ctx.stmts.append(
        f"println(identity({v}));"
        f"let box=Box<String>{{value:{xen_string(text)}}};println(box.get());"
    )
    ctx.expected.extend([str(v), text])


def emit_fn_value(ctx: Ctx) -> None:
    rng = ctx.rng
    ctx.ensure_preamble(
        "fn apply",
        [
            "fn apply(f:fn(Int,Int)->Int,a:Int,b:Int)->Int{return f(a,b);}",
            "fn add_fn(a:Int,b:Int)->Int{return a+b;}",
            "fn sub_fn(a:Int,b:Int)->Int{return a-b;}",
        ],
    )
    a, b = rng.randint(-20, 20), rng.randint(-20, 20)
    if rng.boolean():
        ctx.stmts.append(
            f"let op:fn(Int,Int)->Int=add_fn;println(apply(op,{a},{b}));"
        )
        ctx.expected.append(str(a + b))
    else:
        ctx.stmts.append(
            f"let op:fn(Int,Int)->Int=sub_fn;println(apply(op,{a},{b}));"
        )
        ctx.expected.append(str(a - b))


def emit_borrow(ctx: Ctx) -> None:
    rng = ctx.rng
    ctx.need_cap("#global[explc]")
    ctx.ensure_preamble(
        "fn sum_first",
        ["fn sum_first(values:&Vec<Int>)->Int{return values.get(0);}"],
    )
    n = rng.randint(1, 4)
    values = [rng.randint(-10, 10) for _ in range(n)]
    lit = ",".join(str(v) for v in values)
    extra = rng.randint(-10, 10)
    ctx.stmts.append(
        f"let mut owned:Vec<Int>=[{lit}];"
        f"println(sum_first(&owned));"
        f"owned.push({extra});println(owned.len());"
    )
    ctx.expected.extend([str(values[0]), str(n + 1)])


def emit_mut_borrow(ctx: Ctx) -> None:
    rng = ctx.rng
    ctx.need_cap("#global[explc]")
    ctx.ensure_preamble(
        "fn append_mut",
        ["fn append_mut(values:&mut Vec<Int>,value:Int){values.push(value);}"],
    )
    base = [rng.randint(-5, 5) for _ in range(rng.randint(1, 3))]
    extra = rng.randint(-10, 10)
    lit = ",".join(str(v) for v in base)
    ctx.stmts.append(
        f"let mut mb:Vec<Int>=[{lit}];"
        f"append_mut(&mut mb,{extra});println(mb.len());println(mb.get({len(base)}));"
    )
    ctx.expected.extend([str(len(base) + 1), str(extra)])


def emit_iter(ctx: Ctx) -> None:
    rng = ctx.rng
    ctx.add_import("use std.iter;")
    values = [rng.randint(-10, 10) for _ in range(rng.randint(0, 4))]
    lit = ",".join(str(v) for v in values)
    ctx.stmts.append(
        f"let itv:Vec<Int>=[{lit}];"
        f"for (index,value) in itv.iter().enumerate(){{println(index);println(value);}}"
    )
    for i, v in enumerate(values):
        ctx.expected.extend([str(i), str(v)])
    if values and rng.boolean(0.5):
        ctx.stmts.append("let its:Slice<Int>=itv.as_slice();for value in its.iter(){println(value);}")
        ctx.expected.extend(str(v) for v in values)


def emit_conversion(ctx: Ctx) -> None:
    rng = ctx.rng
    src_ty = rng.choice(["I16", "I32", "I64"])
    dst_ty = rng.choice(["I8", "I16", "I32"])
    lo, hi = limits(dst_ty)
    slo, shi = limits(src_ty)
    lo, hi = max(lo, slo), min(hi, shi)
    if lo > hi:
        return
    value = rng.randint(lo, hi)
    builtin = dst_ty.lower()
    ctx.stmts.append(f"let cv:{src_ty}={value};println({builtin}(cv));")
    ctx.expected.append(str(value))


def emit_range(ctx: Ctx) -> None:
    rng = ctx.rng
    start = rng.randint(-8, 8)
    finish = rng.randint(-8, 8)
    ctx.stmts.append(
        f"let mut range_sum=0;for range_value in {start}..{finish}{{"
        "range_sum=range_sum+range_value;}println(range_sum);"
    )
    ctx.expected.append(str(sum(range(start, finish))))


def emit_std_convert(ctx: Ctx) -> None:
    rng = ctx.rng
    ctx.add_import("use std.convert;")
    values = [rng.choice([-(2**63), 2**63 - 1, rng.randint(-100000, 100000)])]
    if values[0] not in (-(2**63), 2**63 - 1):
        values.append(rng.choice([-(2**63), 2**63 - 1]))
    for index, value in enumerate(values):
        spelling = str(value)
        ctx.stmts.append(
            f"let parsed_convert_{index}=std.convert.parse_int({xen_string(spelling)});"
            f"println(match parsed_convert_{index}{{"
            f"Result.Ok(value)=>std.convert.format_int(value),"
            f"Result.Err(_)=>\"unexpected error\"}});"
        )
        ctx.expected.append(spelling)

    digits = str(rng.randint(10, 9999))
    bad_at = rng.randint(0, len(digits))
    invalid = digits[:bad_at] + "x" + digits[bad_at:]
    ctx.stmts.append(
        f"let invalid_convert=std.convert.parse_int({xen_string(invalid)});"
        "println(match invalid_convert{"
        "Result.Ok(_)=>\"unexpected value\","
        "Result.Err(error)=>match error{"
        "std.convert.ParseIntError.InvalidDigit((index,byte))=>"
        "std.convert.format_int(index)+\":\"+std.convert.format_int(i64(byte)),"
        "_=>\"unexpected error\"}});"
    )
    ctx.expected.append(f"{bad_at}:120")


def emit_std_fs_io(ctx: Ctx) -> None:
    rng = ctx.rng
    ctx.add_import("use std.fs;")
    ctx.add_import("use std.io;")
    path = f"xen_qc_fs_{rng.randint(0, 10**9)}.bin"
    copy = path + ".copy"
    payload = "qc" + chr(1) + str(rng.randint(0, 9999))
    ctx.ensure_preamble(
        "fn qc_int_result",
        [
            "fn qc_int_result(value:Result<Int,std.io.IoError>)->Int{return match value{Result.Ok(n)=>n,Result.Err(_)=>-1};}",
            "fn qc_string_result(value:Result<String,std.io.IoError>)->String{return match value{Result.Ok(text)=>text,Result.Err(_)=>\"error\"};}",
        ],
    )
    ctx.stmts.append(
        f"println(qc_int_result(std.fs.write({xen_string(path)},{xen_string(payload)})));"
        f"println(qc_string_result(std.fs.read({xen_string(path)})));"
        f"println(qc_int_result(std.fs.copy({xen_string(path)},{xen_string(copy)})));"
        f"println(qc_string_result(std.fs.read({xen_string(copy)})));"
    )
    ctx.expected.extend([str(len(payload)), payload, str(len(payload)), payload])


def emit_std_env(ctx: Ctx) -> None:
    ctx.add_import("use std.env;")
    # QuickCheck launches generated programs without arguments; ordering and
    # binary argument cases live in the native E2E suite.
    ctx.stmts.append("let qc_args=std.env.args();println(qc_args.len());")
    ctx.expected.append("0")


def emit_std_string(ctx: Ctx) -> None:
    rng = ctx.rng
    ctx.add_import("use std.iter;")
    ctx.add_import("use std.string;")
    whitespace = {9, 10, 11, 12, 13, 32}
    raw = [rng.randint(0, 255) for _ in range(rng.randint(8, 28))]
    raw.extend(rng.sample(sorted(whitespace), rng.randint(1, len(whitespace))))
    rng.shuffle(raw)
    pieces: list[list[int]] = []
    current: list[int] = []
    for byte in raw:
        if byte in whitespace:
            if current:
                pieces.append(current)
                current = []
        else:
            current.append(byte)
    if current:
        pieces.append(current)
    values = ",".join(f"u8({byte})" for byte in raw)
    ctx.stmts.append(
        f"let qc_raw:Vec<U8>=[{values}];"
        "let qc_tokens=std.string.split_ascii_whitespace(qc_raw.into_string());"
        "println(qc_tokens.len());let mut qc_bytes=0;let mut qc_sum=0;"
        "for qc_token in qc_tokens.iter(){let qc_slice=qc_token.as_bytes();"
        "qc_bytes=qc_bytes+qc_slice.len();for qc_index in 0..qc_slice.len(){"
        "qc_sum=qc_sum+i64(qc_slice.get(qc_index));}}println(qc_bytes);println(qc_sum);"
    )
    flattened = [byte for piece in pieces for byte in piece]
    ctx.expected.extend([str(len(pieces)), str(len(flattened)), str(sum(flattened))])


def emit_tuple(ctx: Ctx) -> None:
    rng = ctx.rng
    a, b = rng.randint(-20, 20), rng.randint(-20, 20)
    ctx.stmts.append(
        f"let pair:(Int,Int)=({a},{b});println(pair.0);println(pair.1);"
        "let mut(qc_left,(_,qc_right)):(Int,(Int,Int))=(pair.0,(0,pair.1));"
        "qc_left=qc_left+qc_right;println(qc_left);"
    )
    ctx.expected.extend([str(a), str(b), str(a+b)])


def emit_result_try(ctx: Ctx) -> None:
    value = ctx.rng.randint(-20, 20)
    ctx.preamble.append(
        "fn qc_try<T,E>(value:Result<T,E>)->Result<T,E>{let inner=value?;return Result.Ok(inner);}"
    )
    ctx.stmts.append(
        f"let qc_try_result:Result<Int,String>=qc_try(Result<Int,String>.Ok({value}));"
        "println(match qc_try_result{Result.Ok(x)=>x,Result.Err(_)=>0});"
    )
    ctx.expected.append(str(value))


def emit_recursive_generic(ctx: Ctx) -> None:
    value = ctx.rng.randint(-20, 20)
    ctx.preamble.append("struct QcNode<T>{value:T,children:Vec<QcNode<T>>}")
    ctx.stmts.append(
        f"let qc_nodes:Vec<QcNode<Int>>=[QcNode<Int>{{value:{value},children:[]}}];"
        "println(qc_nodes[0].value);"
    )
    ctx.expected.append(str(value))


def emit_owning_box(ctx: Ctx) -> None:
    ctx.add_import("use core.box;")
    ctx.need_cap("#global[explc]")
    ctx.preamble.extend([
        "enum QcOwnedTree{Leaf(Int),Branch(core.box.Box<QcOwnedPair>)}",
        "struct QcOwnedPair{left:QcOwnedTree,right:QcOwnedTree}",
        "fn qc_owned_sum(t:QcOwnedTree)->Int{return match t{QcOwnedTree.Leaf(v)=>v,"
        "QcOwnedTree.Branch(b)=>{let p=b.into_inner();qc_owned_sum(p.left)+qc_owned_sum(p.right)}};}",
    ])
    values = [ctx.rng.randint(-20, 20) for _ in range(ctx.rng.randint(2, 5))]
    tree = f"QcOwnedTree.Leaf({values[0]})"
    for value in values[1:]:
        tree = ("QcOwnedTree.Branch(core.box.new(QcOwnedPair{left:" + tree
                + f",right:QcOwnedTree.Leaf({value})" + "}))")
    ctx.stmts.append(
        f"let qc_owned_tree={tree};println(qc_owned_sum(qc_owned_tree));"
        f"let mut qc_owned_scalar=core.box.new({values[-1]});"
        "let qc_owned_view=qc_owned_scalar.as_mut();*qc_owned_view=*qc_owned_view+1;"
        "let qc_owned_moved=qc_owned_scalar;println(qc_owned_moved.into_inner());"
    )
    ctx.expected.extend([str(sum(values)), str(values[-1] + 1)])


def emit_builtins_vec(ctx: Ctx) -> None:
    rng = ctx.rng
    n = rng.randint(0, 5)
    ctx.stmts.append(f"let z=zeros({n});println(z.len());")
    ctx.expected.append(str(n))
    if n > 0:
        ctx.stmts.append("println(z.get(0));")
        ctx.expected.append("0")
    val = rng.randint(-10, 10)
    m = rng.randint(1, 4)
    ctx.stmts.append(f"let rp=repeat({val},{m});println(rp.get(0));println(rp.len());")
    ctx.expected.extend([str(val), str(m)])


def emit_assert(ctx: Ctx) -> None:
    # only asserts that hold
    ctx.stmts.append("assert(1==1);assert(true);")


def emit_file(ctx: Ctx) -> None:
    rng = ctx.rng
    path = f"xen_qc_{rng.randint(0, 10**9)}.txt"
    ctx.temp_paths.append(path)
    alphabet = "abcXYZ01"
    payload = "".join(rng.choice(alphabet) for _ in range(rng.randint(1, 8)))
    # write in two chunks sometimes
    if len(payload) >= 2 and rng.boolean():
        mid = rng.randint(1, len(payload) - 1)
        w1, w2 = payload[:mid], payload[mid:]
        ctx.stmts.append(
            f"let mut outf=open_write({xen_string(path)});"
            f"outf.write({xen_string(w1)});outf.write({xen_string(w2)});outf.close();"
        )
    else:
        ctx.stmts.append(
            f"let mut outf=open_write({xen_string(path)});"
            f"outf.write({xen_string(payload)});outf.close();"
        )
    ctx.stmts.append(
        f"let mut inf=open_read({xen_string(path)});let contents=inf.read();"
        f"println(contents);println(inf.is_open());inf.close();println(inf.is_open());"
    )
    ctx.expected.extend([payload, "true", "false"])


def emit_bb(ctx: Ctx) -> None:
    rng = ctx.rng
    ctx.need_cap("#![bb]")
    # Prefer #![bb] on main via capabilities header — for whole-file use #global[bb]
    # Replace #![bb] with #global[bb] for multi-item files
    if "#![bb]" in ctx.caps:
        ctx.caps = ["#global[bb]" if c == "#![bb]" else c for c in ctx.caps]
    if "#global[bb]" not in ctx.caps:
        ctx.caps.append("#global[bb]")
    ty = rng.choice(["I32", "I64", "U8"])
    n = rng.randint(1, 4)
    values = [rng.int_in(ty) for _ in range(n)]
    ctx.stmts.append(f"let ptr=raw_alloc<{ty}>({n});")
    for i, val in enumerate(values):
        ctx.stmts.append(f"let rv{i}:{ty}={val};raw_store(ptr,{i},rv{i});")
    for i, val in enumerate(values):
        ctx.stmts.append(f"println(raw_load(ptr,{i}));")
        ctx.expected.append(str(val))
    ctx.stmts.append("assert(ptr_addr(ptr)>0);assert(syscall0(39)>0);raw_free(ptr);")


EMITTERS: dict[str, Callable[[Ctx], None]] = {
    "numeric": emit_numeric,
    "float": emit_float,
    "bool_logic": emit_bool_logic,
    "string": emit_string,
    "vec": emit_vec,
    "slice": emit_slice,
    "bytes_bridge": emit_bytes_bridge,
    "control": emit_control,
    "if_expr": emit_if_expr,
    "shadow_block": emit_shadow_block,
    "struct": emit_struct,
    "enum_match": emit_enum_match,
    "option_result": emit_option_result,
    "result_try": emit_result_try,
    "recursive_generic": emit_recursive_generic,
    "owning_box": emit_owning_box,
    "generic": emit_generic,
    "fn_value": emit_fn_value,
    "borrow": emit_borrow,
    "mut_borrow": emit_mut_borrow,
    "iter": emit_iter,
    "range": emit_range,
    "conversion": emit_conversion,
    "std_convert": emit_std_convert,
    "std_env": emit_std_env,
    "std_string": emit_std_string,
    "std_fs_io": emit_std_fs_io,
    "tuple": emit_tuple,
    "builtins_vec": emit_builtins_vec,
    "assert": emit_assert,
    "file": emit_file,
    "bb": emit_bb,
}


def pick_features(rng: RNG, max_features: int, force_all: bool = False) -> list[str]:
    pool = [f for f in ALL_FEATURES if f != "modules"]
    if force_all:
        return list(pool)
    k = rng.randint(2, min(max_features, len(pool)))
    # bias: always include at least one "value" feature
    chosen = set(rng.sample(pool, k))
    if not (chosen & {"numeric", "float", "string", "vec", "bool_logic"}):
        chosen.add(rng.choice(["numeric", "vec", "string"]))
    return list(chosen)


def _finalize(ctx: Ctx, used: set[str], as_modules: bool) -> Program:
    if as_modules and ctx.has_named_type and any(
        "struct Point" in line for line in ctx.preamble
    ):
        return _as_module_project(ctx, used)

    header = ""
    if ctx.imports:
        header = "module app;\n" + "\n".join(ctx.imports) + "\n"
    # Normalize caps: #global[bb] and #global[explc] can combine?
    # Docs: single #global[...] — try merging tags
    caps = list(ctx.caps)
    globals_tags = []
    others = []
    for c in caps:
        if c.startswith("#global["):
            tag = c[len("#global[") : -1]
            globals_tags.extend(t.strip() for t in tag.split(","))
        else:
            others.append(c)
    cap_lines = []
    if globals_tags:
        # unique preserve order
        seen = []
        for t in globals_tags:
            if t not in seen:
                seen.append(t)
        cap_lines.append("#global[" + ",".join(seen) + "]")
    cap_lines.extend(others)
    cap_header = "\n".join(cap_lines) + ("\n" if cap_lines else "")
    pre = "\n".join(ctx.preamble) + ("\n" if ctx.preamble else "")
    source = header + wrap_main("".join(ctx.stmts), preamble=pre, capabilities=cap_header)
    return Program(
        files={"app.xen": source},
        entry="app.xen",
        expected_stdout="".join(line + "\n" for line in ctx.expected),
        features=frozenset(used),
        notes=f"features={sorted(used)}",
    )


def _as_module_project(ctx: Ctx, used: set[str]) -> Program:
    model = "module lib.model;\n"
    rest_pre = []
    for line in ctx.preamble:
        if line.startswith("struct Point"):
            model += line + "\n"
        else:
            rest_pre.append(line)
    app_imports = ["import lib.model as model;"] + ctx.imports
    header = "module app;\n" + "\n".join(dict.fromkeys(app_imports)) + "\n"
    globals_tags = []
    others = []
    for c in ctx.caps:
        if c.startswith("#global["):
            tag = c[len("#global[") : -1]
            globals_tags.extend(t.strip() for t in tag.split(","))
        else:
            others.append(c)
    cap_lines = []
    if globals_tags:
        seen = []
        for t in globals_tags:
            if t not in seen:
                seen.append(t)
        cap_lines.append("#global[" + ",".join(seen) + "]")
    cap_lines.extend(others)
    cap_header = "\n".join(cap_lines) + ("\n" if cap_lines else "")
    pre = "\n".join(rest_pre) + ("\n" if rest_pre else "")
    body = "".join(ctx.stmts).replace("Point{", "model.Point{")
    source = header + wrap_main(body, preamble=pre, capabilities=cap_header)
    used = set(used) | {"modules"}
    return Program(
        files={"app.xen": source, "lib/model.xen": model},
        entry="app.xen",
        expected_stdout="".join(line + "\n" for line in ctx.expected),
        features=frozenset(used),
        notes="multi-file module project",
    )


def generate_mixed(
    rng: RNG,
    max_features: int = 8,
    force_all: bool = False,
    min_emitters: int = 2,
) -> Program:
    features = pick_features(rng, max_features, force_all=force_all)
    ctx = Ctx(rng)
    # seed marker
    seed = rng.randint(0, 9)
    ctx.stmts.append(f"println({seed});")
    ctx.expected.append(str(seed))

    # Pre-declare named types if those features selected (affects numeric crash avoidance)
    if "struct" in features or "enum_match" in features or "generic" in features:
        ctx.has_named_type = True

    emitters = [(name, EMITTERS[name]) for name in features if name in EMITTERS]
    rng.shuffle(emitters)
    if force_all:
        selected = emitters
    else:
        count = rng.randint(min_emitters, len(emitters)) if emitters else 0
        selected = emitters[:count]

    used: set[str] = set()
    for name, fn in selected:
        before = len(ctx.stmts)
        fn(ctx)
        if len(ctx.stmts) > before or name in ("assert",):
            used.add(name)
            ctx.features_used.add(name)

    as_modules = rng.boolean(0.12) and "struct" in used
    return _finalize(ctx, used, as_modules)


def generate_pair_sweep(rng: RNG, feat_a: str, feat_b: str) -> Program:
    """Force two specific features together — systematic pair coverage."""
    ctx = Ctx(rng)
    seed = rng.randint(0, 9)
    ctx.stmts.append(f"println({seed});")
    ctx.expected.append(str(seed))
    for name in (feat_a, feat_b):
        if name in ("struct", "enum_match", "generic"):
            ctx.has_named_type = True
    used = set()
    for name in (feat_a, feat_b):
        if name in EMITTERS:
            EMITTERS[name](ctx)
            used.add(name)
    return _finalize(ctx, used, as_modules=False)


def generate_kitchen_sink(rng: RNG) -> Program:
    """Nearly every feature in one program."""
    return generate_mixed(rng, max_features=len(ALL_FEATURES), force_all=True, min_emitters=20)


# ---------------------------------------------------------------------------
# Ill-typed / noise / contextual (unchanged spirit, expanded pool)
# ---------------------------------------------------------------------------

ILLTYPED_POOL = [
    ("fn main(){let x:I8=1;let y:I16=2;println(x+y);}", "expected I8"),
    ("fn main(){let f=open_read(\"/dev/null\");let moved=f;println(f.is_open());}", "moved File"),
    ("#![explc]\nfn main(){let mut v=[1];let r=&mut v;v.push(2);println(r.len());}", "borrowed"),
    ("fn main(){syscall0(39);}", "requires #![bb]"),
    ("fn bad<T>(x:T)->T{return x+x;}fn main(){}", "concrete type"),
    ("fn main(){let x=Option.Some(1);println(match x{Option.Some(v)=>v});}", "non-exhaustive"),
    ("fn main(){let x=Option.Some(1);println(match x{_=>0,Option.Some(v)=>v});}", "unreachable"),
    ("fn main(){let s=\"x\";println(s[0]);}", "indexing expects"),
    ("struct Loop{next:Loop}fn main(){}", "recursive value layout"),
    ("struct Growing<T>{children:Vec<Growing<(T,T)>>}fn main(){let x:Vec<Growing<Int>>=[];}", "generic recursion keeps expanding"),
    ("fn f()->Result<Int,String>{let x=1?;return Result.Ok(x);}fn main(){}", "? operand must be Result"),
    ("#![bb]\nfn main(){raw_alloc<String>(1);}", "not raw-safe POD"),
    ("fn main(){let data:Vec<U8>=[u8(1)];let text=data.into_string();println(data.len());}", "moved"),
    ("fn main(){let mut v=[1];let s=v.as_slice();v.push(2);println(s.len());}", "borrowed"),
    ("fn main(){let values=[];}", "cannot infer"),
    ("fn main(){let values=[1];values.push(2);}", "mutable local"),
    ("fn main(){let x:I8=-128;let y:I8=-1;println(x/y);}", ""),  # may be runtime — use check? skip needle
]


def generate_illtyped(rng: RNG) -> Program:
    source, needle = rng.choice([c for c in ILLTYPED_POOL if c[1]])
    return Program(
        files={"case.xen": source},
        entry="case.xen",
        expected_stdout="",
        features=frozenset({"illtyped"}),
        expect_check_fail=needle,
    )


TOKENS = [
    "fn", "main", "let", "mut", "return", "if", "else", "while", "for", "in",
    "break", "continue", "struct", "enum", "impl", "match", "module", "import",
    "Int", "String", "Bool", "Vec", "Option", "Result", "true", "false", "_",
    "x", "value", "0", "1", "-1", '"x"', "(", ")", "{", "}", "[", "]",
    "<", ">", ":", ";", ",", ".", "=", "=>", "+", "-", "*", "/", "%",
    "&", "#![explc]", "#![bb]", "#global[bb]", "#global[explc]",
    "raw_alloc", "open_read", "as_slice", "Option.Some", "Result.Ok",
]


def generate_noise(rng: RNG, max_tokens: int = 50) -> Program:
    if rng.boolean():
        n = rng.randint(0, max_tokens)
        parts = []
        for _ in range(n):
            parts.append(rng.choice(["", " ", "\n", "\t"]))
            parts.append(rng.choice(TOKENS))
        source = "".join(parts)
    else:
        alphabet = "abcdefghijklmnopqrstuvwxyz0123456789_ \t\n\"\\(){}[]#:;,.-+*/%<>=!&|"
        source = "".join(rng.choice(alphabet) for _ in range(rng.randint(0, max_tokens * 2)))
    return Program(
        files={"case.xen": source},
        entry="case.xen",
        expected_stdout="",
        features=frozenset({"noise"}),
        notes="frontend noise",
    )


def generate_contextual_probe(rng: RNG) -> Program:
    ty = rng.choice(["I8", "I16", "I32", "U8", "U16", "U32"])
    op = rng.choice(["+", "-", "*", "<", ">", "==", "<=", ">="])
    lit = rng.randint(-5, 5)
    if ty.startswith("U") and lit < 0:
        lit = abs(lit)
    if op in "+-*":
        source = f"fn main(){{let dx:{ty}=3;let result= {lit} {op} dx;println(result);}}"
    else:
        source = f"fn main(){{let dx:{ty}=3;if {lit} {op} dx{{println(1);}}else{{println(0);}}}}"
    return Program(
        files={"case.xen": source},
        entry="case.xen",
        expected_stdout="",
        features=frozenset({"contextual"}),
        notes=f"probe {ty} {op}",
    )


def all_feature_pairs() -> list[tuple[str, str]]:
    names = [f for f in ALL_FEATURES if f != "modules" and f in EMITTERS]
    pairs = []
    for i, a in enumerate(names):
        for b in names[i + 1 :]:
            pairs.append((a, b))
    return pairs
