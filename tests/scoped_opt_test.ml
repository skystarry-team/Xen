(* SPDX-License-Identifier: MIT OR Apache-2.0 *)
open Ast
open Semantic_ir
module Native = Xen_linux_x86_64.Native_backend
let expect b message=if not b then failwith message
let compile source = match Checker.check(Parser.parse ~file:"scoped-opt.xen" source)with
  |Ok p->p|Error d->failwith d.message
let function_named p name=List.find(fun(f:func)->f.name=name)(program p).functions
let execute p=match Native.generate p with
  |Ok b->Test_runner.execute ~write:Native.write b|Error e->failwith e.message
let compare source expected =
  let p=compile source in let q,report=Semantic_opt.optimize p in
  let a=execute p and b=execute q in
  expect(a=b && b=(Unix.WEXITED 0,expected,""))("scoped AOT output differs: "^source);
  q,report
let text n body=Printf.sprintf
  "fn f(n:Int)->Int{let mut i=0;let mut sum=0;#scope[opt]{while i<n{%s}}return sum;}fn main(){println(f(%d));}"
  body n
let invariant="let w=n*n+3;sum=sum+w+i;i=i+1;"
let test_scopes () =
  let source="fn leaf(x:Int)->Int{return x*x+x*x;}fn main(){let n=arg_count()+7;let a=n*n;let b=n*n;println(a+b);}"in
  let p=compile source in let q,r=Semantic_opt.optimize p in
  expect(program p=program q && r.regions=[] && r.loops=[] && r.fusion.fused=0)
    "unmarked source was optimized";
  let source="fn leaf(x:Int)->Int{return x*x+x*x;}fn main(){let n=arg_count()+7;let a=n*n;let b=n*n;#scope[opt]{println(leaf(n));}println(a+b);}"in
  let p=compile source in let q,r=Semantic_opt.optimize p in
  expect(function_named p "leaf"=function_named q "leaf")"callee outside opt changed";
  let outside (f:func)=Array.to_list f.blocks|>List.concat_map(fun(b:block)->List.filter(fun (op:operation)->
    not(List.mem Opt f.scopes.(op.scope).mode_set))b.operations)in
  expect(outside(function_named p "main")=outside(function_named q "main"))"unmarked operations changed";
  expect(r.fusion.fused=1)"scoped pure leaf was not expanded";
  expect(execute p=execute q)"scoped leaf expansion changed behavior";
  let p=compile "fn main(){#scope[opt]{let x=3;{let y=x*x;println(y);}}}"in
  expect(program(Semantic_opt.apply Semantic_opt.Off p)=program p)"off changed opt scope";
  ignore(compare "fn main(){#scope[opt]{let x=3;{let y=x*x;println(y);}}}" "9\n");
  List.iter(fun source->try ignore(Parser.parse ~file:"removed.xen" source);
    failwith "removed jit syntax accepted"with Parser.Error _->())
    ["fn main(){#scope[jit]{}}";"#global[jit]\nfn main(){}";"#![jit]\nfn main(){}"];
  List.iter(fun source->expect(Result.is_error(Checker.check(Parser.parse ~file:"global.xen" source)))
    "global/function opt must remain unsupported")
    ["#global[opt]\nfn main(){}";"#![opt]\nfn main(){}"]
let test_licm () =
  List.iter(fun n->
    let x=Int64.of_int n in
    let expected=Int64.add(Int64.mul x(Int64.add(Int64.mul x x)3L))
      (Int64.div(Int64.mul x(Int64.sub x 1L))2L)in
    let _,r=compare(text n invariant)(Int64.to_string expected^"\n")in
    expect(List.length r.loops=1 && (List.hd r.loops).arithmetic>=2)"AOT did not hoist invariant chain")
    [0;1;2;255;257;10000];
  let source="fn f(n:Int,a:I8)->I8{let mut i=0;let mut sum:I8=0;#scope[opt]{while i<n{let w=a*a;sum=sum+w;i=i+1;}}return sum;}fn main(){println(f(0,-101));println(f(20000,-101));println(f(20001,103));}"in
  ignore(compare source "0\n32\n-111\n");
  let source="fn down(n:Int,d:Int)->Int{let mut i=0;let mut sum=0;#scope[opt]{while i<n{let w=n*n+3;sum=sum+w+i;i=i+1;}}if d==0{return sum;}return sum+down(n+1,d-1);}fn main(){println(down(2,2));}"in
  ignore(compare source "136\n");
  let body=String.concat ""(List.init 35(fun _->"sum=sum+i;"))^invariant in
  let _,r=compare(text 2 body)"50\n"in
  expect(List.length r.loops=1)"AOT inherited JIT encoding-size limit";
  let p=compile(text 3 invariant)in
  let f=function_named p "f"in
  let order=List.rev(List.init(Array.length f.blocks)Fun.id)in
  let ids=Array.make(Array.length f.blocks)0 in List.iteri(fun id old->ids.(old)<-id)order;
  let blocks=Array.of_list(List.mapi(fun id old->let b=f.blocks.(old)in
    let terminator=match b.terminator with Jump t->Jump ids.(t)|Branch(v,a,b)->Branch(v,ids.(a),ids.(b))|t->t in
    {b with id;terminator})order)in
  let f={f with blocks;entry=ids.(f.entry)}in
  let p=Semantic_analysis.revalidate{(program p)with functions=List.map(fun old->if old.id=f.id then f else old)(program p).functions}in
  let q,r=Semantic_opt.optimize p in
  expect(r.loops<>[] && execute p=execute q)"reordered CFG broke LICM";
  expect(program q=program(Semantic_analysis.revalidate(program q)))"loop cleanup revalidation not idempotent"
let test_boundaries () =
  let cases=[
    "let w=n*n+3;sum=sum+w+i;if i==1{break;}i=i+1;","15\n";
    "let w=n*n+3;println(w);sum=sum+w;i=i+1;","7\n7\n14\n";
    "let w=n*n+3;sum=sum+w/(i+1);i=i+1;","10\n";
    "#scope[bb]{let w=n*n+3;sum=sum+w;}i=i+1;","14\n";
    "let w=i*i;sum=sum+w;i=i+1;","1\n";
  ]in
  List.iter(fun(body,expected)->let _,r=compare(text 2 body)expected in
    expect(r.loops=[])"unsafe/effectful loop hoisted")cases;
  let source="#global[explc]\nfn main(){let mut n=2;let mut i=0;let mut sum=0;#scope[opt]{while i<2{let w=n*n;sum=sum+w;n=n+1;i=i+1;}}println(sum);}"in
  let _,r=compare source "13\n"in expect(r.loops=[])"loop-carried input hoisted";
  let source="#global[explc]\nfn main(){let n=2;let view=&n;let mut i=0;let mut sum=0;#scope[opt]{while i<2{let w=n*n;sum=sum+w;i=i+1;}}println(sum);println(*view);}"in
  let _,r=compare source "8\n2\n"in expect(r.loops=[])"address-taken input hoisted";
  ignore(compare "fn main(){#scope[opt]{let mut v=[\"a\"];while v.len()<3{v.push(\"b\");}println(v.len());}}" "3\n")
let test_reentry () =
  let source="fn f(n:Int)->Int{let mut i=0;let mut sum=0;#scope[opt]{while i<3{let w=n*n+3;sum=sum+w;i=i+1;}i=0;while i<2{let w=(n+1)*(n+1);sum=sum+w;i=i+1;}}return sum;}fn main(){println(f(3));println(f(4));}"in
  let _,r=compare source "68\n107\n"in expect(List.length r.loops=2)"multiple loop caches lost";
  let source="fn main(){let mut k=0;let mut sum=0;#scope[opt]{while k<4{let mut i=0;while i<k+1{let w=k*k+3;sum=sum+w;i=i+1;}k=k+1;}}println(sum);}"in
  let _,r=compare source "80\n"in expect(List.length r.loops=1)"inner loop was not independently optimized";
  List.iter(fun n->let source=Printf.sprintf
    "fn f(n:Int){let mut i=0;#scope[opt]{while i<n{let x=1/0;println(x);i=i+1;}}}fn main(){f(%d);}"n in
    let p=compile source in let q,r=Semantic_opt.optimize p in
    expect(execute p=execute q && r.loops=[])"fallible zero-trip loop changed") [0;1]
let test_non_ssa () =
  let p=compile(text 3 invariant)in let f=function_named p "f"in
  let header=Array.to_list f.blocks|>List.find(fun(b:block)->match b.terminator with Branch _->true|_->false)in
  let body=match header.terminator with Branch(_,id,_)->id|_->assert false in
  let op=List.find(fun op->match op.node with Eval(_,Binary("*",_,_))->true|_->false)f.blocks.(body).operations in
  let check f = Semantic_analysis.revalidate{(program p)with functions=List.map(fun old->if old.id=f.id then f else old)(program p).functions}in
  let blocks=Array.copy f.blocks in
  blocks.(body)<-{blocks.(body)with operations=List.concat_map(fun current->if current=op then [current;current]else[current])blocks.(body).operations};
  let duplicated=check {f with blocks}in let q,r=Semantic_opt.optimize duplicated in
  expect(r.loops=[] && execute duplicated=execute q)"multiply-defined temporary was hoisted";
  (* Initialize the result outside, then observe its previous-iteration value
     in the header. It has one loop writer, but a use before that writer. *)
  let v=match op.node with Eval(v,_)->v|_->assert false in
  let exit=match header.terminator with Branch(_,_,exit)->exit|_->assert false in
  let blocks=Array.map(fun(b:block)->{b with operations=List.filter(fun op->match op.node with
    Storage_live id|Storage_dead id->id<>v.id|_->true)b.operations})f.blocks in
  let at node={op with scope=header.scope;node}in
  blocks.(f.entry)<-{blocks.(f.entry)with operations=blocks.(f.entry).operations@[at(Storage_live v.id);at(Eval(v,Int_lit 3L))]};
  let condition=match header.terminator with Branch(v,_,_)->v|_->assert false in
  blocks.(header.id)<-{blocks.(header.id)with operations=List.map(fun op->match op.node with
    Eval(result,Binary(n,a,_))when result.id=condition.id->{op with node=Eval(result,Binary(n,a,v))}|_->op)blocks.(header.id).operations};
  blocks.(exit)<-{blocks.(exit)with operations=at(Storage_dead v.id)::blocks.(exit).operations};
  let locals=Array.copy f.locals and scopes=Array.copy f.scopes in
  let old_scope=locals.(v.id).scope in locals.(v.id)<-{locals.(v.id)with scope=header.scope};
  scopes.(old_scope)<-{scopes.(old_scope)with declarations=List.filter((<>)v.id)scopes.(old_scope).declarations};
  scopes.(header.scope)<-{scopes.(header.scope)with declarations=scopes.(header.scope).declarations@[v.id]};
  let previous=check {f with blocks;locals;scopes}in let q,r=Semantic_opt.optimize previous in
  expect(r.loops=[] && execute previous=execute q)"use-before-definition temporary was hoisted"
let ()=test_scopes();test_licm();test_boundaries();test_reentry();test_non_ssa();
  print_endline "Scoped AOT, LICM, effects, lifetimes and CFG tests passed"
