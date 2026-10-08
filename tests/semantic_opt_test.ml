(* SPDX-License-Identifier: MIT OR Apache-2.0 *)
open Ast
open Semantic_ir
let fail s = failwith s
let expect b s = if not b then fail s
let compile source = match Checker.check(Parser.parse ~file:"opt.xen" source)with
  |Ok p->p|Error d->fail(Printf.sprintf "line %d: %s"d.span.line d.message)
let executable p = match Native_backend.generate p with Ok x->x|Error e->fail e.message
let differential source =
  let off=compile source in let basic,_=Semantic_opt.optimize off in
  let a=Test_runner.execute(executable off)and b=Test_runner.execute(executable basic)in
  expect(a=b)("off/basic mismatch: "^source);a
let operations p name = let f=List.find(fun(f:func)->f.name=name)(program p).functions in
  Array.to_list f.blocks |> List.concat_map(fun(b:block)->b.operations)
let count p name predicate=List.length(List.filter(fun op->predicate op.node)(operations p name))
let binary = function Eval(_,Binary _)->true|_->false
let copy = function Acquire _->true|_->false
let direct name = function Eval(_,Call(n,_))->n=name|_->false
let test_computation () =
  let p=compile "fn calc(x:Int)->Int{let a=x*x;let b=x*x;return a+b;} fn main(){println(calc(12));}"in
  let q,r=Semantic_opt.optimize p in
  expect(count p "calc" binary=3)"missing original arithmetic";
  expect(count q "calc" binary=2)"CSE failed";
  expect(count q "calc" copy<count p "calc" copy)"copy elimination failed";
  expect(r.fusion.fused=1 && count q "main"(direct "calc")=0)"leaf fusion failed";
  expect(count q "main"(function Logical_call_enter _->true|_->false)=1)"logical entry lost";
  let p=compile "fn main(){let a=5;let b=(a+2)*(a+2);println(b);}"in
  let q,_=Semantic_opt.optimize p in expect(count q "main" binary=0)"constant folding failed";
  (* Cleanup-free revalidation must be idempotent, including managed cleanup. *)
  let p=compile "fn main(){let s=\"hi\";let mut t=s;t=\"bye\";println(t);}"in
  let q=Semantic_analysis.revalidate(program p)in expect(program p=program q)"cleanup duplicated";
  let q,_=Semantic_opt.optimize p in
  expect(count p "main"(function Drop _->true|_->false)=count q "main"(function Drop _->true|_->false))"managed drops changed"
let test_differential () =
  List.iter(fun source->ignore(differential source))[
    "fn main(){let mut x=4;let a=x*x;x=7;let b=x*x;println(a);println(b);let c=x; x=8;println(c+x);}";
    "fn f(x:Int)->Int{let a=x*x;let b=x*x;return a+b;}fn main(){println(f(arg_count()));}";
    "fn main(){let mut x=arg_count()+4;let a=x*x;let b=a;x=7;let c=x*x;println(a+b+c);}";
    "fn main(){let x=arg_count()+5;let mut a=x*x;let b=a;a=9;let c=x*x;println(a+b+c);}";
    "fn main(){let x=arg_count()+5;let a=x*x;{let b=x*x;println(b);}let c=x*x;println(a+c);}";
    "fn main(){let n=arg_count()+2;let mut i=0;while i<4{let a=n*n;let b=n*n;if i==2{break;}println(a+b);i=i+1;continue;}}";
    "fn f(a:Int,b:Int)->Int{return a*10+b;} fn tick(x:Int)->Int{println(x);return x;} fn main(){println(f(tick(1),tick(2)));}";
    "#global[explc]\nfn bump(x:&mut Int){*x=9;} fn main(){let mut x=3;let a=x*x;bump(&mut x);let b=x*x;println(a);println(b);}";
    "fn f(x:Int)->Int{return x+1;}fn main(){let callback:fn(Int)->Int=f;println(callback(4));println(f(8));}";
    "fn main(){let x=if true{4}else{5};println(x*x);let mut y=0;while y<5{println(y*y);y=y+1;}}";
    "fn f(x:Int)->Int{return x+1;} fn main(){f(1);f(2);println(f(3));}";
    "fn side()->Bool{println(100);return true;}fn main(){println(false && side());println(true || side());}";
    "fn main(){let a:U64=18446744073709551615;let b:U64=9223372036854775808;println(a>b);println(b>a);println(a+1);println(a-b);}";
    "fn main(){let n:Int=-9223372036854775808;println(n/-1);}";
    "fn main(){let n:Int=-9223372036854775808;println(n%-1);}";
    "fn main(){println(1/0);}";
    "fn main(){let x:Int=128;println(i8(x));}";
    "fn main(){let x:F32=1.5;println(x*x);}";
    "fn main(){let mut v=[\"a\"];while v.len()<5{v.push(\"b\");}let f=open_read(\"/dev/null\");println(v.len());}";
  ];
  List.iter(fun typ->ignore(differential(Printf.sprintf
    "fn main(){let a:%s=%s;let b:%s=1;println(a+b);println(a*b);println(a-b);println(a>b);println(a==b);}"
    typ (match typ with "I8"->"127"|"U8"->"255"|"I16"->"32767"|"U16"->"65535"|"I32"->"2147483647"|"U32"->"4294967295"|"I64"->"9223372036854775807"|_->"18446744073709551615")typ)))
    ["I8";"U8";"I16";"U16";"I32";"U32";"I64";"U64"]
let test_frames () =
  let source n=Printf.sprintf "fn leaf(x:Int)->Int{return x+1;}\nfn down(n:Int)->Int{if n==0{return leaf(7);}return down(n-1);}\nfn main(){println(down(%d));}"n in
  let status,out,err=differential(source 4093)in expect(status=Unix.WEXITED 0 && out="8\n" && err="")"4096 frames rejected";
  let status,_,err=differential(source 4094)in
  expect(status=Unix.WEXITED 1 && String.starts_with ~prefix:"opt.xen:2:36:" err)"leaf failure span changed"
let test_limits () =
  let oversized=String.concat ""(List.init 35(fun _->"y=y+1;"))in
  let source="fn large(x:Int)->Int{let mut y=x;"^oversized^"return y;} fn main(){println(large(1));}"in
  let q,r=Semantic_opt.optimize(compile source)in expect(r.fusion.fused=0 && count q "main"(direct "large")=1)"large leaf fused";
  let source="fn leaf(x:Int)->Int{return x*x;} fn main(){"^String.concat ""(List.init 20(fun i->Printf.sprintf "println(leaf(%d));"i))^"}"in
  let p=compile source in let q,r=Semantic_opt.optimize p in
  let a=List.find(fun(f:func)->f.name="main")(program p).functions and b=List.find(fun(f:func)->f.name="main")(program q).functions in
  expect((Array.length b.locals-Array.length a.locals)*8<=256)"stack budget exceeded";
  expect(r.fusion.fused>0 && count q "main"(direct "leaf")>0)"cumulative stack budget ignored";
  let p=compile "fn leaf(x:Int)->Int{return x+1;} fn main(){#scope[bb]{println(leaf(1));}}"in
  let q,r=Semantic_opt.optimize p in expect(r.fusion.fused=0 && count q "main"(direct "leaf")=1)"mode mismatch fused";
  ignore(differential source);
  let p=compile "fn leaf(x:Int)->Int{return x+1;} fn main(){let f:fn(Int)->Int=leaf;println(f(1));}"in
  let q,r=Semantic_opt.optimize p in expect(r.fusion.fused=0 && count q "main"(function Eval(_,Indirect_call _)->true|_->false)=1)"indirect call fused"
let test_operation_budget () =
  let p=compile "fn leaf(x:Int)->Int{return x+1;}fn main(){leaf(1);leaf(2);leaf(3);leaf(4);leaf(5);leaf(6);leaf(7);leaf(8);leaf(9);leaf(10);}" |> program in
  let leaf=List.find(fun(f:func)->f.name="leaf")p.functions in
  let x=value_of_local leaf.locals.(0)and result={id=1;typ=I64;span=leaf.span}in
  let local={leaf.locals.(0)with id=1;name="$temporary";temporary=true;parameter=None}in
  let op node={node;span=leaf.span;scope=0}in
  let body={id=0;scope=0;operations=op(Storage_live 1)::List.init 32(fun _->op(Eval(result,Binary("+",x,x))))@[op(Storage_dead 0)];terminator=Return(Some result)}in
  let leaf={leaf with locals=[|leaf.locals.(0);local|];scopes=[|{leaf.scopes.(0)with declarations=[0;1]}|];blocks=[|body|]}in
  let p=Semantic_analysis.revalidate{p with functions=List.map(fun(f:func)->if f.name="leaf"then leaf else f)p.functions}in
  let q,r=Semantic_opt.optimize p in
  expect(r.fusion.fused=6 && count q "main"(direct "leaf")=4)"additional IR operation budget ignored";
  let a=Test_runner.execute(executable p)and b=Test_runner.execute(executable q)in expect(a=b)"budget fixture behavior changed"
let test_stack_padding () =
  let source="struct Nine{a:U8,b:U8,c:U8,d:U8,e:U8,f:U8,g:U8,h:U8,i:U8} fn leaf(x:Int)->Int{return x+1;}fn main(){"^
    String.concat ""(List.init 8(fun _->"leaf(1);"))^"}"in
  let p=compile source |> program in
  let f=List.find(fun(f:func)->f.name="main")p.functions in
  let id=Array.length f.locals in
  let local={id;name="unused";typ=Named "Nine";span=f.span;scope=0;owned=false;temporary=false;parameter=None}in
  let scopes=Array.copy f.scopes in scopes.(0)<-{scopes.(0)with declarations=scopes.(0).declarations@[id]};
  let f={f with locals=Array.append f.locals [|local|];scopes}in
  let p=Semantic_analysis.revalidate{p with functions=List.map(fun old->if old.name="main"then f else old)p.functions}in
  let q,r=Semantic_opt.optimize p in expect(r.fusion.fused=7 && count q "main"(direct "leaf")=1)"slot padding exceeds budget";
  expect(Test_runner.execute(executable p)=Test_runner.execute(executable q))"padding fixture changed result"
let test_storage_versions () =
  let p=compile "fn work(x:Int)->Int{return x*x;}fn main(){println(work(3));}" |> program in
  let f=List.find(fun(f:func)->f.name="work")p.functions in
  let l id={f.locals.(0)with id;name="$temporary";temporary=true;parameter=None}in
  let v id={id;typ=I64;span=f.span}and op node={node;span=f.span;scope=0}in
  let nodes=[Storage_live 1;Acquire(v 1,Copy,place_of_value(v 0));Storage_live 2;Acquire(v 2,Copy,place_of_value(v 1));
    Eval(v 1,Int_lit 7L);Storage_live 3;Eval(v 3,Binary("+",v 2,v 1));Storage_dead 1;Storage_live 1;
    Eval(v 1,Int_lit 9L);Storage_live 4;Eval(v 4,Binary("+",v 3,v 1));Storage_dead 0;Storage_dead 1;Storage_dead 2;Storage_dead 3]in
  let f={f with locals=[|f.locals.(0);l 1;l 2;l 3;l 4|];scopes=[|{f.scopes.(0)with declarations=[0;1;2;3;4]}|];
    blocks=[|{id=0;scope=0;operations=List.map op nodes;terminator=Return(Some(v 4))}|]}in
  let p=Semantic_analysis.revalidate{p with functions=List.map(fun old->if old.name="work"then f else old)p.functions}in
  let q,_=Semantic_opt.optimize p in
  let a=Test_runner.execute(executable p)and b=Test_runner.execute(executable q)in
  expect(a=b && a=(Unix.WEXITED 0,"19\n",""))"storage version/restart changed preserved copy"
let test_verification () =
  let p=compile "fn leaf(x:Int)->Int{return x+1;}fn main(){println(leaf(1));}"in
  let q,_=Semantic_opt.optimize p in
  let corrupt edit={ (program q) with functions=List.map(fun(f:func)->{f with blocks=Array.map(fun(b:block)->{b with operations=List.concat_map edit b.operations})f.blocks})(program q).functions}in
  let invalid p=try ignore(Semantic_analysis.revalidate p);fail "corrupt optimized IR accepted"with Invalid _|Semantic_analysis.Diagnostic _->()in
  invalid(corrupt(fun op->match op.node with Logical_call_exit _->[]|_->[op]));
  invalid(corrupt(fun op->match op.node with Logical_call_enter _->[{op with node=Logical_call_exit 0}]|_->[op]));
  invalid(corrupt(fun op->match op.node with Storage_live _->[]|_->[op]));
  let q=Semantic_analysis.revalidate(program q)in expect(program q=program(Semantic_analysis.revalidate(program q)))"revalidation changes IR"
let () =
  test_computation();test_differential();test_frames();test_limits();test_operation_budget();test_stack_padding();test_storage_versions();test_verification();
  print_endline "Semantic optimization and fusion tests passed"
