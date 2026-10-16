(* SPDX-License-Identifier: MIT OR Apache-2.0 *)
open Ast
open Semantic_ir

let expect ok message = if not ok then failwith message
let parse source = Parser.parse ~file:"operators.xen" source
let compile source = match Checker.check(parse source)with
  |Ok p->p|Error d->failwith d.message
let operations p = (program p).functions |> List.concat_map(fun(f:func)->
  Array.to_list f.blocks |> List.concat_map(fun(b:block)->b.operations))

let test_parser () =
  let expr source = match (List.hd(parse("fn main(){"^source^";}")).functions).body with
    |[{node=Expr e;_}]->e|_->failwith "expected one expression" in
  let rec shape (e:Ast.expr) = match e.node with
    |Ast.Binary(op,a,b)->"("^shape a^op^shape b^")"
    |Ast.Unary(op,a)->"("^op^shape a^")"
    |Ast.Var n|Ast.Int_lit n->n|_->failwith "unexpected expression"in
  List.iter(fun(source,expected)->expect(shape(expr source)=expected)("precedence: "^source))[
    "a|b^c&d<<e+f*g","(a|(b^(c&(d<<(e+(f*g))))))";
    "a < I8 >> b","(a<(I8>>b))";
    "a < I8 >= b","((a<I8)>=b)";
    "a < Vec<I8>> b","((a<Vec)<(I8>>b))";
    "a<<b>>c","((a<<b)>>c)";
    "a&b==c&&d||e","((((a&b)==c)&&d)||e)";
    "+~a*b","((+(~a))*b)";
    "-a**b**c","(-(a**(b**c)))";
    "a**-b*c","((a**(-b))*c)";
    "~a**b","(~(a**b))";
    "**a","(*(*a))";
    "a * *b","(a*(*b))";
  ];
  let tokens=Lexer.lex ~file:"operators.xen" "<< >> & && | || ^ ~ >= > ** *" in
  expect(List.map(fun(t:Lexer.token)->t.kind)tokens=
    [Lexer.Shl;Shr;Amp;And_and;Pipe;Or_or;Caret;Tilde;Gt_eq;Gt;Power;Star;Eof])"operator tokens";
  (try ignore(parse "fn main(){let x:Vec<Int>>;}");failwith "invalid declaration accepted"
   with Parser.Error(span,_)->expect(span.column=25)"split > token diagnostic span")

let test_folding () =
  List.iter(fun(typ,value)->
    let source=Printf.sprintf "fn f()->%s{return %s;}fn main(){println(f());}"typ value in
    let p=compile source in
    let q,_=Semantic_opt.optimize ~scope_only:false p in
    expect(not(List.exists(fun(op:operation)->match op.node with
      Eval(_,Unary _)|Eval(_,Binary _)->true|_->false)(operations q)))"bitwise/unary constant folding";
    verify(program q))[
      "I8","+(~-128 & 7 | 64 ^ 3)";
      "U8","~0 ^ 255";
      "I16","~32767";
      "U16","+65535";
      "I32","~-2147483648";
      "U32","~0";
      "I64","~-9223372036854775808";
      "U64","+18446744073709551615 ^ 0";
    ];
  let p=compile "fn main(){#scope[opt]{1<<64;1>>(-1);2**(-1);}}"in
  let q,_=Semantic_opt.optimize p in
  let shifts p=List.filter(fun(op:operation)->match op.node with Eval(_,Binary(("<<"|">>"|"**"),_,_))->true|_->false)(operations p)in
  expect(List.length(shifts p)=3 && List.length(shifts q)=3)"unused fallible shifts/power removed";
  expect(List.for_all(fun op->not(Semantic_opt.safe_node op.node))(shifts q))"fallible shift considered pure"

let test_conversion_context () =
  ignore(compile "fn main(){println(u64(++18446744073709551615));println(i64(+-9223372036854775808));}");
  let p=compile "fn main(){println(u8(+(255+1)));}"in
  expect(List.exists(fun(op:operation)->match op.node with
    |Eval(_,Call("__convert_u8",[x]))->x.typ=I64|_->false)(operations p))
    "unary + changed nonliteral conversion arithmetic's type";
  List.iter(fun expression->match Checker.check(parse("fn main(){"^expression^";}"))with
    |Error _->()|Ok _->failwith("out-of-range positive literal accepted: "^expression))
    ["u8(+256)";"i8(+128)";"u64(+-1)";"f32(+3.5e38)"]

let test_verifier () =
  let invalid checked transform =
    let p=program checked in
    let p={p with functions=List.map(fun(f:func)->{f with blocks=Array.map(fun(b:block)->
      {b with operations=List.map(fun(op:operation)->{op with node=transform op.node})b.operations})f.blocks})p.functions}in
    try verify p;failwith "invalid operator IR accepted"with Invalid _->()in
  let float=compile "fn main(){let a=1.0;println(a+a);println(-a);}"in
  List.iter(fun operator->invalid float(function
    |Eval(v,Binary(_,a,b))->Eval(v,Binary(operator,a,b))|n->n))["&";"|";"^";"<<";">>"];
  invalid float(function Eval(v,Unary(_,a))->Eval(v,Unary("~",a))|n->n);
  let unsigned=compile "fn main(){let a=u8(1);println(+a);}"in
  invalid unsigned(function Eval(v,Unary(_,a))->Eval(v,Unary("-",a))|n->n);
  let boolean=compile "fn main(){println(!true);}"in
  List.iter(fun operator->invalid boolean(function Eval(v,Unary(_,a))->Eval(v,Unary(operator,a))|n->n))["+";"~"];
  let shifts=compile "fn main(){let a=i8(1);println(a<<a);}"in
  invalid shifts(function Eval(v,Binary(op,a,b))->Eval(v,Binary(op,a,{b with typ=I64}))|n->n)

let test_numeric_linking () =
  let source="struct V{x:Int}fn id<T>(x:T)->T{return x;}fn xmath_pow64()->Int{return 7;}fn main(){let v=id(V{x:xmath_pow64()});println(v.x);println(9.0**0.5);println(5.5%2.0);}"in
  let a=compile source in
  let plain=compile "fn main(){println(2**3);}"in
  expect(not(List.exists(fun(f:func)->Numeric_math.is_helper f.name)(program plain).functions))"unused math helpers linked";
  let b=compile source in expect(program a=program b)"numeric linking leaked compiler state";
  List.iteri(fun id(f:func)->expect(id=f.id)"numeric helper function ID";
    if Numeric_math.is_helper f.name then expect(not(Semantic_opt.candidate f))"numeric helper may consume fused logical depth")
    (program a).functions;
  let p=compile "fn main(){println(5.5%2.0);}"in
  expect(List.filter_map(fun(f:func)->if Numeric_math.is_helper f.name then Some f.name else None)(program p).functions=["$math$fmod64"])
    "unreachable numeric helpers retained";
  List.iter(fun name->match Checker.check(parse("fn main(){"^name^"(1.0);}"))with
    |Error _->()|Ok _->failwith "internal numeric primitive exposed")
    ["xmath_bits_u64";"xmath_bits_f64";"xmath_narrow_f32";"xmath_sqrt_f64"];
  List.iter(fun source->ignore(compile source))[
    "fn main(){let n:U8=2**3;println(n);}";
    "fn main(){let n:F32=9.0**0.5;println(n%2.0);}";
  ];
  let checked,_=Semantic_opt.optimize ~scope_only:false a in verify(program checked)

let () = test_parser();test_folding();test_conversion_context();test_verifier();test_numeric_linking();print_endline "Operator parsing, folding and IR contracts passed"
