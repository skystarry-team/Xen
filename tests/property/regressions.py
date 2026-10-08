# SPDX-License-Identifier: Apache-2.0
"""Fixed diagnostic regressions sourced from examples/errors and known asymmetry."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class FixedCase:
    id: str
    source: str
    expected_substring: str


KNOWN_ERRORS: list[FixedCase] = [
    FixedCase("implicit_numeric_conversion",
              "fn main(){let small:I8=1;let wide:I16=2;println(small+wide);}",
              "expected I8"),
    FixedCase("use_after_move",
              "fn consume(file:File){}\nfn main(){let file=open_read(\"/dev/null\");consume(file);println(file.is_open());}",
              "moved File"),
    FixedCase("borrow_conflict",
              "#![explc]\nfn main(){let mut value=1;let reference=&value;value=2;println(*reference);}",
              "while it is borrowed"),
    FixedCase("generic_type_operation",
              "fn double<T>(value:T)->T{return value+value;}\nfn main(){println(double(2));}",
              "concrete type"),
    FixedCase("non_exhaustive_match",
              "fn main(){let value=Option.Some(1);println(match value{Option.Some(number)=>number});}",
              "non-exhaustive match"),
    FixedCase("unreachable_match",
              "fn main(){println(match true{_=>1,true=>2});}",
              "unreachable pattern"),
    FixedCase("recursive_struct_layout",
              "struct Left{right:Right}\nstruct Right{left:Left}\nfn main(){}",
              "recursive value layout"),
    FixedCase("raw_memory_outside_bb",
              "fn main(){let pointer=raw_alloc_int(1);}",
              "requires #![bb]"),
    FixedCase("immutable_vec_receiver",
              "fn main(){let values=[1];values.push(2);}",
              "mutable local"),
    FixedCase("untyped_empty_vec",
              "fn main(){let values=[];}",
              "cannot infer"),
    FixedCase("duplicate_pattern_binding",
              "fn main(){println(match (1,2){(value,value)=>value});}",
              "duplicate pattern binding"),
    FixedCase("invalid_enum_payload",
              "enum Point{Coordinates((Int,Int))}\nfn main(){let point=Point.Coordinates(1,2);}",
              "enum variant payload expects one value"),
    FixedCase("recursive_enum_layout",
              "enum Chain{End,Next(Chain)}\nfn main(){}",
              "recursive value layout"),
]


# Still FAIL on xen 0.2.3 — pin the asymmetry so a future fix flips these green.
KNOWN_ASYMMETRY: list[FixedCase] = [
    FixedCase("literal_left_sub",
              "fn main(){let dx:I32=3;let result=0-dx;println(result);}",
              "expected Int (I64), found I32"),
    FixedCase("literal_left_lt",
              "fn main(){let dx:I32=3;if 0<dx{println(1);}}",
              "expected Int (I64), found I32"),
    FixedCase("literal_then_branch",
              "fn main(){let dx:I32=3;let result=if true{0}else{dx};println(result);}",
              "expected Int (I64), found I32"),
]


@dataclass(frozen=True)
class RuntimeRegression:
    id: str
    source: str
    expected_stdout: str


# Whole-language mixed QC found these crashes. They now require clean execution
# so the original reproductions remain permanent runtime regressions.
KNOWN_RUNTIME_REGRESSIONS: list[RuntimeRegression] = [
    RuntimeRegression(
        id="unused_generic_struct_fields",
        source="""struct Box<T>{value:T}
struct Holder{option:Option<Int>,result:Result<Int,String>,nested:Box<Box<Int>>,safe:Vec<Box<Int>>}
fn main(){println(42);}
""",
        expected_stdout="42\n",
    ),
    RuntimeRegression(
        id="struct_u16_add_zero_then_empty_vec",
        source="""struct P{x:Int}
fn main(){
  let a:U16=1;let b:U16=0;let r:U16=a+b;println(r);
  let mut v:Vec<Int>=[];println(v.len());
}
""",
        expected_stdout="1\n0\n",
    ),
    RuntimeRegression(
        id="enum_i16_add_zero_then_empty_vec",
        source="""enum E{A}
fn main(){
  let a:I16=1;let b:I16=0;let r:I16=a+b;println(r);
  let mut v:Vec<Int>=[];println(v.len());
}
""",
        expected_stdout="1\n0\n",
    ),
]
