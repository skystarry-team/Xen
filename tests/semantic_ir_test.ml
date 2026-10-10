(* SPDX-License-Identifier: Apache-2.0 *)
open Ast
open Semantic_ir

let fail format = Printf.ksprintf failwith format
let expect yes message = if not yes then fail "%s" message

(* Bypass only analysis/cleanup, retaining the real frontend and lowering. A
   checked program must not be analyzed again: cleanup is already elaborated. *)
let lower source =
  let ast=Parser.parse ~file:"semantic-property.xen" source in
  let ast=match Checker.add_prelude ast with Ok p->p|Error d->fail "%s" d.message in
  let ast=match Monomorph.run ast with Ok p->p|Error d->fail "%s\n%s"d.message source in
  let typed=match Checker.check_internal ~entry:"main" ast with Ok p->p|Error d->fail "%s"d.message in
  Semantic_lower.lower typed

let outcome p =
  try
    let checked=Semantic_analysis.check p in
    verify(program checked);
    (* Check cleanup against the actual raw operation/place IDs. *)
    List.iter2(fun (before:func)(after:func)->Array.iteri(fun id (b:block)->
      let remaining=ref after.blocks.(id).operations in
      List.iter(fun (op:operation)->
        let take expected=match !remaining with
          |next::rest when next.node=expected->remaining:=rest
          |_->fail "cleanup contract failed: f%d b%d" before.id id in
        (match op.node with
          |Storage_dead local when before.locals.(local).owned->
              take(Drop(place_of_value(value_of_local before.locals.(local))));take op.node
          |Replace(p,v)->take(Drop p);take(Initialize(p,v))
          |_->take op.node);
        (* Summary-generated flags are attached only to calls. *)
        (match op.node with Eval(_,(Call _|Indirect_call _))->
          let rec skip()=match !remaining with {node=Drop_flag _;_}::rest->remaining:=rest;skip()|_->()in skip()
          |_->()))b.operations;
      expect(!remaining=[])"unexpected cleanup operation")before.blocks)
      p.functions (program checked).functions;
    true
  with Semantic_analysis.Diagnostic _->false

let map_functions transform p={p with functions=List.map transform p.functions}
let split_blocks p=map_functions(fun (f:func)->
  let n=Array.length f.blocks in
  let heads=Array.mapi(fun id (b:block)->
    let cut=List.length b.operations/2 in
    {b with operations=List.filteri(fun i _->i<cut)b.operations;terminator=Jump(n+id)})f.blocks in
  let tails=Array.mapi(fun id(b:block)->{b with id=n+id;
    operations=List.filteri(fun i _->i>=List.length b.operations/2)b.operations})f.blocks in
  {f with blocks=Array.append heads tails})p

let split_edges p=map_functions(fun(f:func)->
  let next=ref(Array.length f.blocks)and bridges=ref[]in
  let edge scope target=let id= !next in incr next;
    bridges:={id;scope;operations=[];terminator=Jump target}::!bridges;id in
  let blocks=Array.map(fun(b:block)->let terminator=match b.terminator with
    |Jump t->Jump(edge b.scope t)
    |Branch(v,a,c)->let a=edge b.scope a in let c=edge b.scope c in Branch(v,a,c)
    |t->t in {b with terminator})f.blocks in
  {f with blocks=Array.append blocks(Array.of_list(List.rev !bridges))})p

let reverse_blocks p=map_functions(fun(f:func)->
  let n=Array.length f.blocks in let rename id=n-1-id in
  let blocks=Array.init n(fun id->let b=f.blocks.(rename id)in
    let terminator=match b.terminator with Jump t->Jump(rename t)
      |Branch(v,a,c)->Branch(v,rename a,rename c)|t->t in {b with id;terminator})in
  {f with blocks;entry=rename f.entry})p

let test_cfg () =
  let count=ref 0 in
  let check label expected source=
    let raw=lower source in verify raw;
    List.iter(fun(name,transform)->let candidate=transform raw in
      verify candidate;
      if outcome candidate<>expected then fail "%s / %s changed analysis outcome\n%s\n%s"
        label name source(dump candidate);incr count)
      ["identity",Fun.id;"split blocks",split_blocks;"split edges",split_edges;
       "reverse",reverse_blocks;"combined",(fun p->reverse_blocks(split_edges(split_blocks p)))]in
  List.iter(fun mutable_->List.iter(fun bad->List.iter(fun loop->
    let source=Printf.sprintf
      "#global[explc]\nfn exercise(c:Bool){let mut a=1;let mut b=2;let r=if c{&%sa}else{&%sb};let q=if c{r}else{r};%s%s a=9;b=10;}fn main(){exercise(true);}"
      (if mutable_ then "mut "else "")(if mutable_ then "mut "else "")
      (if bad then "a=3;"else "")
      (if loop then "let mut i=0;while i<2{println(*q);i=i+1;}"else "println(*q);")in
    check "joined reference" (not bad) source)[false;true])[false;true])[false;true];
  List.iter(fun(bad,source)->check "regression CFG" (not bad) source)[
    false,"#global[explc]\nfn exercise(c:Bool){let mut a=1;let r=if c{&mut a}else{&mut a};*r=2;println(*r);a=3;}fn main(){exercise(true);}";
    false,"fn main(){let mut a=[1];let s=a.as_slice();println(s[0]);a.push(2);}";
    true,"fn main(){let mut a=[1];let s:Slice<Int>=if true{a.as_slice()}else{a.as_slice()};a.push(2);println(s[0]);}";
    true,"#![explc]\nfn main(){let mut n=1;let r=&n;let mut i=0;while i<2{println(*r);n=2;i=i+1;}}";
    false,"struct P{a:File,b:File}fn take(f:File){}fn main(){let mut p=P{a:open_read(\"/dev/null\"),b:open_read(\"/dev/null\")};take(p.a);p.a=open_read(\"/dev/null\");take(p.b);take(p.a);}";
    true,"struct P{a:File,b:File}fn take(f:File){}fn main(){let p=P{a:open_read(\"/dev/null\"),b:open_read(\"/dev/null\")};take(p.a);take(p.a);}";
    false,"fn take(f:File,n:Int){}fn fail()->Result<Int,Int>{return Result.Err(1);}fn run()->Result<Int,Int>{take(open_read(\"/dev/null\"),fail()?);return Result.Ok(0);}fn main(){let r=run();}";
    false,"fn main(){let mut i=0;while i<3{let f=open_read(\"/dev/null\");i=i+1;match i{1=>{continue;},2=>{break;},_=>{}}}}";
    false,"struct V{s:Slice<Int>}impl V{fn set(&mut self,s:Slice<Int>){self.s=s;}}fn main(){let mut a=[1];let b=[2];let mut v=V{s:a.as_slice()};v.set(b.as_slice());a.push(3);println(v.s[0]);}";
    false,"fn main(){let(a,_)= (box(1),box(2));println(a.into_inner());}";
    true,"fn main(){let p=(box(1),box(2));let(a,_)=p;println(p.0.into_inner());}";
    true,"fn main(){let mut v=[1];let(view,_)= (v.as_slice(),0);v.push(2);println(view[0]);}";
  ];
  Printf.printf "Semantic IR CFG properties passed: %d variants\n" !count

let test_tuple_let_cleanup () =
  let raw=lower "fn marker(){}fn main(){let(a,_)= (box(1),box(2));marker();println(a.into_inner());}" in
  verify raw;expect(outcome raw)"tuple let analysis rejected";
  let fn=List.find(fun(f:func)->f.name="main")raw.functions in
  let ops=List.concat_map(fun(b:block)->b.operations)(Array.to_list fn.blocks)in
  let moves=List.filter_map(fun(op:operation)->match op.node with
    |Acquire(_,Move,({projections=[Field _];_}as p))->Some p|_->None)ops in
  let owner=match moves with [p]->p.root|_->fail "tuple let expected one field move" in
  expect(fn.locals.(owner).temporary)"tuple let owner is not a temporary";
  let rec before_marker dead=function
    |[]->fail "tuple let marker missing"
    |{node=Storage_dead id;_}::rest when id=owner->before_marker true rest
    |{node=Eval(_,Call("marker",[]));_}::_->expect dead "tuple owner outlived declaration"
    |_::rest->before_marker dead rest in
  before_marker false ops;
  let checked=Semantic_analysis.check raw |> program in
  let fn=List.find(fun(f:func)->f.name="main")checked.functions in
  expect(Array.exists(fun(b:block)->List.exists(fun(op:operation)->match op.node with
    |Drop p->p.root=owner|_->false)b.operations)fn.blocks)"tuple remainder drop missing";
  print_endline "Semantic IR tuple let cleanup passed"

let test_verifier () =
  let raw=lower "fn add(n:Int)->Int{return n+1;}fn main(){println(add(2));}"in
  let invalid label transform=
    try verify(transform raw);fail "verifier accepted %s"label
    with Invalid _->()in
  let first change p=match p.functions with f::rest->{p with functions=change f::rest}|_->assert false in
  invalid "unknown entry"(fun p->{p with entry="missing"});
  invalid "duplicate names"(fun p->{p with functions=p.functions@[List.hd p.functions]});
  invalid "invalid parameter"(first(fun f->{f with params=[9999]}));
  invalid "parameter metadata"(first(fun f->{f with params=[]}));
  invalid "duplicate declaration"(first(fun f->{f with scopes=Array.mapi(fun i s->
    if i=0 then {s with declarations=s.declarations@[0]}else s)f.scopes}));
  invalid "missing declaration"(first(fun f->{f with scopes=Array.map(fun s->{s with declarations=[]})f.scopes}));
  invalid "unknown operation scope"(first(fun f->{f with blocks=Array.map(fun b->{b with operations=
    List.map(fun (op:operation)->{op with scope=999})b.operations})f.blocks}));
  invalid "non-concrete type"(first(fun f->{f with locals=Array.mapi(fun i l->if i=0 then {l with typ=Int}else l)f.locals}));
  invalid "unknown successor"(first(fun f->{f with blocks=Array.mapi(fun i b->if i=0 then {b with terminator=Jump 999}else b)f.blocks}));
  let operations change=first(fun f->{f with blocks=Array.map(fun b->{b with operations=List.map change b.operations})f.blocks})in
  invalid "unknown operator"(operations(fun op->match op.node with Eval(v,Binary(_,a,b))->{op with node=Eval(v,Binary("bogus",a,b))}|_->op));
  invalid "unknown call"(map_functions(fun f->{f with blocks=Array.map(fun b->{b with operations=List.map(fun op->match op.node with
    Eval(v,Call(_,args))->{op with node=Eval(v,Call("missing",args))}|_->op)b.operations})f.blocks}));
  let owned=lower "struct P{text:String}fn main(){let p=P{text:\"x\"};println(p.text);}"in
  let corrupt={owned with functions=List.map(fun f->{f with blocks=Array.map(fun b->{b with operations=List.map(fun op->match op.node with
    Eval(v,Struct_lit(l,fields))->{op with node=Eval(v,Struct_lit({l with size=l.size+8},fields))}|_->op)b.operations})f.blocks})owned.functions}in
  (try verify corrupt;fail "verifier accepted forged aggregate layout"with Invalid _->());
  let borrow=lower "#![explc]\nfn main(){let n=1;let r=&n;println(*r);}"in
  let corrupt=map_functions(fun f->{f with blocks=Array.map(fun b->{b with operations=List.map(fun op->match op.node with
    Borrow(v,m,_,p)->{op with node=Borrow(v,m,true,p)}|_->op)b.operations})f.blocks})borrow in
  (try verify corrupt;fail "verifier reserved a shared borrow"with Invalid _->());
  let check_invalid label transform p=
    try verify(transform p);fail "verifier accepted %s"label with Invalid _->()in
  let nodes change=map_functions(fun f->{f with blocks=Array.map(fun b->{b with operations=List.map(fun op->
    {op with node=change op.node})b.operations})f.blocks})in
  check_invalid "deref of scalar"(nodes(function Acquire(v,k,p) when p.projections<>[]->
    Acquire(v,k,{p with root=0})|n->n))borrow;
  check_invalid "wrong place type"(nodes(function Acquire(v,k,p)->Acquire(v,k,{p with typ=Bool})|n->n))borrow;
  check_invalid "missing capability"(map_functions(fun f->{f with scopes=Array.mapi(fun i (s:scope)->
    if i=0 then {s with mode_set=[]}else s)f.scopes}))borrow;
  let file=lower "fn main(){let f=open_read(\"/dev/null\");let g=f;}"in
  List.iter(fun kind->check_invalid "copy/clone of File"(nodes(function Acquire(v,_,p)when p.typ=File->
    Acquire(v,kind,p)|n->n))file)[Copy;Clone];
  check_invalid "owning observation"(nodes(function Acquire(v,_,p)when p.typ=File->Acquire(v,Read,p)|n->n))file;
  let raw_operation=lower "#![bb]\nfn main(){let p=raw_alloc_int(1);raw_free_int(p);}"in
  check_invalid "raw operation without bb"(map_functions(fun f->{f with mode_set=[];
    scopes=Array.map(fun(s:scope)->{s with mode_set=[]})f.scopes}))raw_operation;
  let numeric=lower "fn main(){let xs=repeat(1,2);println(xs);}"in
  check_invalid "repeat arity"(nodes(function Eval(v,Call("repeat",xs))->Eval(v,Call("repeat",List.tl xs))|n->n))numeric;
  let strings=lower "fn main(){let text=\"x\";let n=1;let xs=[text];}"in
  let malformed=map_functions(fun f->let n=Array.find_opt(fun(l:local)->String.starts_with ~prefix:"n$"l.name)f.locals|>Option.get|>value_of_local in
    {f with blocks=Array.map(fun b->{b with operations=List.map(fun op->match op.node with
      Eval(v,Vec_lit[x])when x.typ=String->{op with node=Eval(v,Call("repeat",[x;n]))}|_->op)b.operations})f.blocks})strings in
  (try verify malformed;fail "verifier accepted repeat(String,Int)"with Invalid _->());
  Printf.printf "Semantic IR verifier mutation properties passed\n"

let test_initialization () =
  let span={file="uninitialized.ir";line=1;column=1}in
  let local id typ:local={id;name="unset";typ;span;scope=0;owned=false;temporary=false;parameter=None}in
  let locals=[|local 0 (Ref(false,I64));local 1 I64|]in
  let op node:operation={node;scope=0;span}in
  let value=value_of_local locals.(1)in
  let place={root=0;projections=[Deref];typ=I64;span}in
  let f:func={id=0;name="main";mode_set=[Explc];params=[];return_type=Unit;locals;
    scopes=[|{id=0;parent=None;mode_set=[Explc];span;declarations=[0;1]}|];
    blocks=[|{id=0;scope=0;operations=[op(Storage_live 0);op(Storage_live 1);op(Acquire(value,Copy,place))];terminator=Return None}|];entry=0;span}in
  let p={layouts=[];enums=[];functions=[f];entry="main"}in
  List.iter(fun transform->let p=transform p in verify p;
    expect(not(outcome p))"uninitialized reference dereference accepted")
    [Fun.id;split_blocks;split_edges;reverse_blocks];
  let dead={p with functions=[{f with blocks=[|{f.blocks.(0)with operations=
    [op(Storage_live 0);op(Storage_dead 0);op(Storage_live 1);op(Acquire(value,Copy,place))]}|]}]}in
  expect(not(outcome dead))"dead reference dereference accepted";
  let scalar={p with functions=[{f with locals=[|local 0 I64;local 1 I64|];blocks=[|{f.blocks.(0)with
    operations=List.map op [Storage_live 0;Eval({value with id=0},Int_lit 1L);Storage_dead 0;
      Eval({value with id=0},Int_lit 2L);Storage_live 1;Acquire(value,Copy,{place with projections=[]})]}|]}]}in
  verify scalar;expect(not(outcome scalar))"definition resurrected dead storage";
  let live=map_functions(fun f->{f with blocks=Array.map(fun b->{b with operations=List.concat_map(fun op->
    match op.node with Storage_dead 0->[op;{op with node=Storage_live 0}]|_->[op])b.operations})f.blocks})scalar in
  expect(outcome live)"explicitly reopened storage was rejected";
  let initialized_ref={p with functions=[{f with params=[0];locals=[|{f.locals.(0)with parameter=Some 0};f.locals.(1)|];
    blocks=[|{f.blocks.(0)with operations=[op(Storage_live 1);op(Acquire(value,Copy,place))]}|]}]}in
  expect(outcome initialized_ref)"initialized reference projection was rejected";
  let locals=[|{(local 0(Vec I64))with owned=true;name="values"};
    {(local 1 I64)with name="index"};local 2 I64;local 3 I64|]in
  let v id=value_of_local locals.(id)in
  let place={root=0;projections=[Element(v 1)];typ=I64;span}in
  let f={f with locals;scopes=[|{f.scopes.(0)with declarations=[0;1;2;3]}|];
    blocks=[|{id=0;scope=0;operations=List.map op [Storage_live 0;Storage_live 1;Storage_live 2;
      Eval(v 2,Int_lit 1L);Eval(v 0,Vec_lit[v 2]);Storage_live 3;Acquire(v 3,Copy,place)];terminator=Return None}|]}in
  let indexed={p with functions=[f]}in verify indexed;
  (try ignore(Semantic_analysis.check indexed);fail "uninitialized index accepted"with
    Semantic_analysis.Diagnostic(_,message,_)->
      let rec contains i=i+7<=String.length message&&(String.sub message i 7="'index'"||contains(i+1))in
      expect(contains 0)"index operand initialization was not checked");
  let initialized_index=map_functions(fun f->{f with blocks=Array.map(fun b->{b with operations=List.concat_map(fun op->
    match op.node with Storage_live 1->[op;{op with node=Eval(v 1,Int_lit 0L)}]|_->[op])b.operations})f.blocks})indexed in
  List.iter(fun transform->expect(outcome(transform initialized_index))
    "initialized element projection was rejected") [Fun.id;split_blocks;split_edges;reverse_blocks];
  let moved_owner=map_functions(fun f->{f with blocks=Array.map(fun b->{b with operations=List.concat_map(fun op->
    match op.node with Acquire(_,_,p) when p.projections<>[]->[{op with node=Forget{p with projections=[];typ=Vec I64}};op]|_->[op])b.operations})f.blocks})initialized_index in
  expect(not(outcome moved_owner))"element projection resurrected a moved Vec owner";
  Printf.printf "Semantic IR initialization properties passed\n"

let test_reborrow_alternatives () =
  (* p and its live child may be alternatives of a value, but must never
     authorize each other. The true branch conflicts with held. *)
  let span={file="parent-child.ir";line=1;column=1}in
  let local ?parameter id typ:local={id;name="ref";typ;span;scope=0;owned=false;temporary=false;parameter}in
  let locals=[|local ~parameter:0 0 (Ref(true,I64));local ~parameter:1 1 Bool;
    local 2(Ref(true,I64));local 3(Ref(true,I64));local 4(Ref(true,I64));local 5 I64;local 6 I64|]in
  let v id=value_of_local locals.(id)in
  let p id=place_of_value(v id)in
  let deref id={root=id;projections=[Deref];typ=I64;span}in
  let op node:operation={node;span;scope=0}in
  let b id nodes terminator:block={id;scope=0;operations=List.map op nodes;terminator}in
  let f:func={id=0;name="exercise";mode_set=[Explc];params=[0;1];return_type=Unit;locals;
    scopes=[|{id=0;parent=None;mode_set=[Explc];span;declarations=List.init 7 Fun.id}|];entry=0;span;
    blocks=[|b 0 [Storage_live 2;Borrow(v 2,true,false,deref 0);Storage_live 3;Acquire(v 3,Copy,p 2);
      Storage_live 4;Storage_live 5;Eval(v 5,Int_lit 3L)](Branch(v 1,1,2));
      b 1 [Initialize(p 4,v 0)](Jump 3);b 2 [Initialize(p 4,v 2)](Jump 3);
      b 3 [Replace(deref 4,v 5);Storage_live 6;Acquire(v 6,Copy,deref 3)](Return None)|]}in
  let raw={layouts=[];enums=[];functions=[f];entry="exercise"}in
  List.iter(fun transform->let p=transform raw in verify p;
    expect(not(outcome p))"merged parent authorized an independently live child")
    [Fun.id;split_blocks;split_edges;reverse_blocks];
  Printf.printf "Semantic IR parent/child loan negative controls passed\n"

let test_shared_reborrow () =
  let span={file="shared-child.ir";line=1;column=1}in
  let types=[|Ref(true,I64);Ref(false,I64);I64;I64;Ref(true,I64)|]in
  let locals=Array.mapi(fun id typ:local->{id;name="slot"^string_of_int id;typ;span;scope=0;
    owned=false;temporary=false;parameter=(if id=0 then Some 0 else None)})types in
  let v id=value_of_local locals.(id)in
  let p id=place_of_value(v id)in
  let deref id={root=id;projections=[Deref];typ=I64;span}in
  let prefix=[Storage_live 1;Storage_live 2;Storage_live 3;Storage_live 4;
    Acquire(v 4,Copy,p 0);Eval(v 3,Int_lit 2L);Borrow(v 1,false,false,deref 0);
    Acquire(v 2,Copy,deref 1)]in
  let cases=[
    true,[Replace(deref 0,v 3)];
    true,[Replace(deref 4,v 3)];
    true,[Acquire(v 2,Copy,deref 0);Acquire(v 2,Copy,deref 1)];
    false,[Replace(deref 0,v 3);Acquire(v 2,Copy,deref 1)];
    false,[Replace(deref 4,v 3);Acquire(v 2,Copy,deref 1)];
    false,[Replace(deref 1,v 3)];
  ]in
  List.iter(fun(expected,nodes)->
    let operations=List.map(fun node:operation->{node;span;scope=0})(prefix@nodes)in
    let f:func={id=0;name="exercise";mode_set=[Explc];params=[0];return_type=Unit;locals;span;entry=0;
      scopes=[|{id=0;parent=None;mode_set=[Explc];span;declarations=List.init 5 Fun.id}|];
      blocks=[|{id=0;scope=0;operations;terminator=Return None}|]}in
    let raw={layouts=[];enums=[];functions=[f];entry="exercise"}in
    List.iter(fun transform->let p=transform raw in verify p;
      expect(outcome p=expected)"shared child lost authority or did not freeze parent/alias mutation")
      [Fun.id;split_blocks;split_edges;reverse_blocks])cases;
  Printf.printf "Semantic IR shared reborrow properties passed: 24 variants\n"

let test_joined_store () =
  let span={file="joined-store.ir";line=1;column=1}in
  let field:struct_field={name="file";typ=File;offset=0;owner_size=8}in
  let layout:struct_layout={name="P";fields=[field];size=8;alignment=8;managed=true}in
  let types=[Named "P";Named "P";Ref(true,Named "P");Bool;File;File;File;File;File;File;File]in
  let locals=Array.of_list(List.mapi(fun id typ:local->{id;typ;name=Printf.sprintf "slot%d"id;span;scope=0;
    owned=(match typ with Named _->true|File->id<9|_->false);temporary=false;parameter=None})types)in
  let v id=value_of_local locals.(id)in let p id=place_of_value(v id)in
  let file id={root=id;projections=[Field field];typ=File;span}in
  let op node:operation={node;span;scope=0}in
  let block id nodes terminator:block={id;scope=0;operations=List.map op nodes;terminator}in
  let prefix=List.init 11(fun id->Storage_live id)@[
    Eval(v 3,Bool_lit true);Eval(v 4,Int_lit(-1L));Eval(v 5,Int_lit(-1L));
    Eval(v 0,Struct_lit(layout,[field,v 4]));Forget(p 4);
    Eval(v 1,Struct_lit(layout,[field,v 5]));Forget(p 5);
    Acquire(v 6,Move,file 0);Acquire(v 7,Move,file 1);Eval(v 8,Int_lit(-1L))]in
  let destination={root=2;projections=[Deref;Field field];typ=File;span}in
  let f:func={id=0;name="main";mode_set=[];params=[];return_type=Unit;locals;
    scopes=[|{id=0;parent=None;mode_set=[];span;declarations=List.init 11 Fun.id}|];entry=0;span;
    blocks=[|block 0 prefix(Branch(v 3,1,2));
      block 1 [Borrow(v 2,true,true,p 0)](Jump 3);block 2 [Borrow(v 2,true,true,p 1)](Jump 3);
      block 3 [Replace(destination,v 8);Forget(p 8);Acquire(v 9,Read,file 0);Acquire(v 10,Read,file 1)](Return None)|]}in
  let raw={layouts=[layout];enums=[];functions=[f];entry="main"}in
  List.iter(fun transform->let p=transform raw in verify p;
    expect(not(outcome p))"one indirect store reinitialized both moved fields")
    [Fun.id;split_blocks;split_edges;reverse_blocks];
  Printf.printf "Semantic IR multi-destination store properties passed\n"

let test_joined_call () =
  let raw=lower "#global[explc]\nstruct V{s:Slice<Int>}impl V{fn set(&mut self,s:Slice<Int>){self.s=s;}}fn main(){let mut a=[1];let b=[2];let flag=true;let mut h=V{s:a.as_slice()};let mut other=V{s:a.as_slice()};h.set(b.as_slice());a.push(3);println(h.s[0]);}"in
  let join different p=map_functions(fun(f:func)->if f.name<>"main"then f else
    let original=f.blocks.(0)in expect(Array.length f.blocks=1)"joined call fixture stopped being linear";
    let rec split acc=function
      |({node=Borrow(v,true,true,target);_}as op)::rest when target.typ=Named "V"->List.rev acc,op,v,target,rest
      |op::rest->split(op::acc)rest|[]->fail "missing reserved receiver"in
    let before,op,result,target,after=split[]original.operations in
    let other=Array.find_opt(fun(l:local)->String.starts_with ~prefix:"other$" l.name)f.locals|>Option.get in
    let condition=Array.find_opt(fun(l:local)->String.starts_with ~prefix:"flag$" l.name)f.locals|>Option.get|>value_of_local in
    let count=Array.length f.locals in
    let aliases=Array.init 2(fun i->{f.locals.(result.id)with id=count+i;name="$alternative"})in
    let branch id local target=
      let v=value_of_local local in
      {id;scope=original.scope;operations=List.map(fun node->{op with node})[
        Storage_live v.id;Borrow(v,true,true,target);Initialize(place_of_value result,v);Storage_dead v.id];terminator=Jump 3}in
    let scopes=Array.mapi(fun i s->if i=op.scope then {s with declarations=s.declarations@[count;count+1]}else s)f.scopes in
    {f with locals=Array.append f.locals aliases;scopes;blocks=[|
      {original with operations=before;terminator=Branch(condition,1,2)};
      branch 1 aliases.(0) target;
      branch 2 aliases.(1)(if different then place_of_value(value_of_local other)else target);
      {original with id=3;operations=after}|]})p in
  List.iter(fun different->let p=join different raw in
    List.iter(fun transform->let p=transform p in verify p;
      expect(outcome p=not different)"call overwrite used identity count instead of actual destinations")
      [Fun.id;split_blocks;split_edges;reverse_blocks])[false;true];
  Printf.printf "Semantic IR joined call overwrite properties passed\n"

let () =
  let previous=Sys.signal Sys.sigalrm(Sys.Signal_handle(fun _->fail "Semantic IR property timed out"))in
  ignore(Unix.alarm 30);
  Fun.protect ~finally:(fun()->ignore(Unix.alarm 0);Sys.set_signal Sys.sigalrm previous)
    (fun()->test_verifier();test_tuple_let_cleanup();test_cfg();test_initialization();test_reborrow_alternatives();test_shared_reborrow();test_joined_store();test_joined_call())
