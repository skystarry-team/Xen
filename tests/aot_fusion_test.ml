(* SPDX-License-Identifier: MIT OR Apache-2.0 *)
open Semantic_ir
module Native = Xen_linux_x86_64.Native_backend
let expect b message=if not b then failwith message
let compile source=match Checker.check(Parser.parse ~file:"aot-fusion.xen" source)with
  | Ok p->p|Error d->failwith d.message
let execute p=match Native.generate p with
  | Ok b->Test_runner.execute ~write:Native.write b|Error e->failwith e.message
let functions p=(program p).functions
let named p name=List.find(fun(f:func)->f.name=name)(functions p)
let fused report=List.exists(fun(r:Semantic_loop_fusion.report)->r.fused)report.Semantic_opt.loop_fusion
let compare source expected_fusion =
  let p=compile source in
  let snapshot=Semantic_prefix_cache.serialize(program p)in
  let q,r=Semantic_opt.optimize p in
  expect(execute p=execute q)("loop fusion changed execution: "^source);
  expect(snapshot=Semantic_prefix_cache.serialize(program p))"optimizer mutated checked input";
  expect(fused r=expected_fusion)("unexpected loop fusion decision: "^source);
  q,r
let source n second = Printf.sprintf
  "fn f(n:Int)->Int{let mut i=0;let mut j=0;let mut a=0;let mut b=0;#scope[opt]{while i<n{a=a+i*i;i=i+1;}%s}return a+b+i+j;}fn main(){println(f(%d));}"
  second n
let standard="while j<n{b=b+j+j;j=j+1;}"
let test_fusion () =
  List.iter(fun n->let q,_=compare(source n standard)true in
    let loops=Semantic_opt_graph.straight_loops ~safe_node:Semantic_opt.safe_node(named q "f")in
    expect(List.length loops=1)"fusion did not reduce two loops to one")[-3;0;1;2;255;10000];
  ignore(compare "fn main(){let mut i:U8=0;let mut j:U8=0;let mut a:U8=0;let mut b:U8=0;#scope[opt]{while i<255{a=a+i;i=i+1;}while j<255{b=b+j+j;j=j+1;}}println(a);println(b);println(i);println(j);}"true);
  ignore(compare "fn main(){let mut i:Int=9223372036854775806;let mut j:Int=9223372036854775806;let mut a=0;let mut b=0;#scope[opt]{while i<9223372036854775807{a=a+1;i=i+1;}while j<9223372036854775807{b=b+1;j=j+1;}}println(a);println(b);println(i);println(j);}"true);
  ignore(compare "fn main(){let mut i:U64=18446744073709551614;let mut j:U64=18446744073709551614;let mut a=0;let mut b=0;#scope[opt]{while i<18446744073709551615{a=a+1;i=i+1;}while j<18446744073709551615{b=b+1;j=j+1;}}println(a);println(b);println(i);println(j);}"true);
  List.iter(fun body->ignore(compare(source 3 body)false))[
    "while j<n{b=b+a;j=j+1;}";
    "while j<n{a=a+j;j=j+1;}";
    "while j<n+1{b=b+j;j=j+1;}";
    "while j<n{b=b+j;j=j+2;}";
    "println(a);while j<n{b=b+j;j=j+1;}";
    "while j<n{println(j);b=b+j;j=j+1;}";
    "while j<n{b=b+1/(j+1);j=j+1;}";
    "while j<n{if j==1{break;}b=b+j;j=j+1;}";
    "{while j<n{b=b+j;j=j+1;}}";
    "j=1;while j<n{b=b+j;j=j+1;}";
  ];
  ignore(compare "fn main(){let mut i=0;let mut j=1;let mut a=0;let mut b=0;#scope[opt]{while i<3{a=a+i;i=i+1;}while j<3{b=b+j;j=j+1;}}println(a+b);}"false);
  ignore(compare "#global[explc]\nfn main(){let n=3;let v=&n;let mut i=0;let mut j=0;#scope[opt]{while i<n{i=i+1;}while j<n{j=j+1;}}println(*v);}"false);
  let p=compile(source 3 standard)in let f=named p "f"in
  let count=Array.length f.blocks in let ids=Array.init count(fun id->count-id-1)in
  let blocks=Array.init count(fun id->let b=f.blocks.(count-id-1)in
    let terminator=match b.terminator with Jump t->Jump ids.(t)
      | Branch(v,a,b)->Branch(v,ids.(a),ids.(b))|t->t in {b with id;terminator})in
  let f={f with blocks;entry=ids.(f.entry)}in
  let p=Semantic_analysis.revalidate{(program p)with functions=List.map(fun old->if old.id=f.id then f else old)(functions p)}in
  let q,r=Semantic_opt.optimize p in
  expect(fused r && execute p=execute q)"block reordering changed fusion"
let cache_source middle last=Printf.sprintf
  "fn main(){let n=arg_count()+7;#scope[opt]{let a=n*n;println(a);let b=n+%d;println(b);let c=n*%d;println(c);}}"middle last
let hits report=List.map(fun(r:Semantic_opt.region)->r.prefix.hit)report.Semantic_opt.regions
let test_prefix () =
  let cache=Semantic_prefix_cache.create ~identity:"test-compiler"()in
  let p=compile(cache_source 2 3)in
  let q,r=Semantic_opt.optimize ~cache p in expect(not(List.exists Fun.id(hits r)))"cold prefix hit";
  let q2,r2=Semantic_opt.optimize ~cache p in
  expect(List.for_all Fun.id(hits r2) && program q=program q2)"identical prefix was not reused exactly";
  let _,tail=Semantic_opt.optimize ~cache(compile(cache_source 2 9))in
  expect(List.hd(hits tail) && List.exists not(hits tail))"suffix change invalidated every prefix or none";
  let _,middle=Semantic_opt.optimize ~cache(compile(cache_source 4 9))in
  expect(List.hd(hits middle) && List.exists not(hits middle))"middle change failed to keep the earlier prefix";
  let rec suffix_misses seen=function []->()|hit::rest->
    expect(not(seen && hit))"dependent suffix reused after a changed prefix";
    suffix_misses(seen||not hit)rest in suffix_misses false(hits middle);
  let _,options=Semantic_opt.optimize ~cache ~loops:false(compile(cache_source 4 9))in
  expect(not(List.exists Fun.id(hits options)))"optimization option change reused prefix";
  let leaf n=Printf.sprintf "fn leaf(x:Int)->Int{return x+%d;}fn main(){#scope[opt]{println(leaf(7));}}"n in
  ignore(Semantic_opt.optimize ~cache(compile(leaf 1)));
  let _,changed=Semantic_opt.optimize ~cache(compile(leaf 2))in
  expect(not(List.exists Fun.id(hits changed)))"callee content change reused prefix";
  (* Mutable reports and output arrays must not be retained by the cache. *)
  (List.hd r2.regions).counts.constants<-999;
  let main=named q2 "main"in main.blocks.(main.entry)<-{main.blocks.(main.entry)with operations=[]};
  let q3,r3=Semantic_opt.optimize ~cache p in
  expect(execute q=execute q3 && (List.hd r3.regions).counts.constants<>999)"cache shared mutable output"
let test_suffix_liveness () =
  let p=compile "fn f(n:Int)->Int{#scope[opt]{n*n;println(0);return n;}}fn main(){println(f(7));}"in
  let f=named p "f"in
  let definition=Array.to_list f.blocks |> List.concat_map(fun(b:block)->b.operations)|>
    List.find(fun op->match op.node with Eval(_,Binary("*",_,_))->true|_->false)in
  let value=match definition.node with Eval(v,_)->v|_->assert false in
  let change ~observe = Array.map(fun(b:block)->
    let operations=List.filter(fun op->match op.node with Storage_dead id->id<>value.id|_->true)b.operations|>
      List.concat_map(fun(op:operation)->match op.node with
        | Eval(v,Call("println",args))->
            [{op with node=Eval(v,Call("println",if observe then [value]else args))};
             {definition with node=Storage_dead value.id}]
        | _->[op])in {b with operations})f.blocks in
  let checked observe=let f={f with blocks=change ~observe}in
    Semantic_analysis.revalidate{(program p)with functions=List.map(fun old->if old.id=f.id then f else old)(functions p)}in
  let cache=Semantic_prefix_cache.create ~identity:"liveness"()in
  let original=checked false in ignore(Semantic_opt.optimize ~cache original);
  let changed=checked true in let q,r=Semantic_opt.optimize ~cache changed in
  let f_reports=List.filter(fun(r:Semantic_opt.region)->r.function_name="f")r.regions in
  expect((List.hd f_reports).prefix.hit)"backward liveness unnecessarily invalidated forward prefix";
  expect(execute changed=execute q && execute q=(Unix.WEXITED 0,"49\n7\n",""))
    "cached DCE deleted a newly observed prefix temporary"
let test_cached_scalar_and_abort () =
  let cache=Semantic_prefix_cache.create ~identity:"scalar-codec"()in
  List.iter(fun source->let p=compile source in
    let cold,_=Semantic_opt.optimize ~cache p in let warm,r=Semantic_opt.optimize ~cache p in
    expect(program cold=program warm && execute p=execute warm && List.for_all Fun.id(hits r))
      "cached narrow/boolean/non-SSA rewrites differ")[
    "fn main(){#scope[opt]{let a:I8=127;let b:I8=a+1;println(b);println(-b);println(!true);}}";
    "fn f(n:I8,b:Bool)->I8{#scope[opt]{let x=n*n+n*n;let flag=!b;if flag{return x;}return -x;}}fn main(){println(f(-101,false));println(f(-101,true));}";
    "fn main(){let mut n=arg_count()+7;#scope[opt]{let a=n*n;n=n+1;let b=n*n;println(a+b);}}";
  ];
  let p=compile "fn main(){#scope[opt]{let n=7;println(n);}}"in
  let f=named p "main"in
  let f={f with blocks=Array.map(fun(b:block)->{b with operations=List.filter(fun op->match op.node with
    Eval(_,Int_lit 7L)->false|_->true)b.operations})f.blocks}in
  let invalid=Semantic_ir.checked{(program p)with functions=[f]}in
  let cache=Semantic_prefix_cache.create ~identity:"abort"()in
  (try ignore(Semantic_opt.optimize ~cache invalid);failwith "invalid storage passed revalidation"
   with Semantic_analysis.Diagnostic _->());
  expect(cache.pending=[] && cache.aliases=[] && Hashtbl.length cache.nodes=0)
    "failed revalidation published a prefix cache transaction"
let replace_function p (f:func) = Semantic_analysis.revalidate
  {(program p)with functions=List.map(fun old->if old.id=f.id then f else old)(functions p)}
let test_header_state_and_entries () =
  let p=compile "fn f(n:Int)->Int{let mut i=0;let mut j=0;let mut x=0;#scope[opt]{while i<n{i=i+1;}while j<n{j=j+1;}}return x;}fn main(){println(f(3));}"in
  let f=named p "f"in
  let second=List.nth(Semantic_opt_graph.straight_loops ~safe_node:Semantic_opt.safe_node f)1 in
  let header=f.blocks.(second.header)in
  let x=Array.to_list f.locals|>List.find(fun(l:local)->not l.temporary && l.parameter=None &&
    not(List.exists(fun(loop:Semantic_opt_graph.loop)->
      Semantic_opt_graph.I.mem l.id loop.access.writes)
      (Semantic_opt_graph.straight_loops ~safe_node:Semantic_opt.safe_node f)))|>value_of_local in
  let base=Array.length f.locals in
  let locals=Array.init 3(fun offset->{f.locals.(x.id)with id=base+offset;name="$header_state";
    temporary=true;scope=header.scope;parameter=None})in
  let values=Array.map value_of_local locals in let a=values.(0)and one=values.(1)and sum=values.(2)in
  let at node={node;span=header.terminator |> (function Branch(v,_,_)->v.span|_->assert false);scope=header.scope}in
  let operations=List.map(fun(v:value)->at(Storage_live v.id))[a;one;sum] @
    [at(Acquire(a,Copy,place_of_value x));at(Eval(one,Int_lit 1L));
     at(Eval(sum,Binary("+",a,one)));at(Initialize(place_of_value x,sum))] @
    List.map(fun(v:value)->at(Storage_dead v.id))[a;one;sum] @ header.operations in
  let blocks=Array.copy f.blocks and scopes=Array.copy f.scopes in
  blocks.(header.id)<-{header with operations};
  scopes.(header.scope)<-{scopes.(header.scope)with declarations=scopes.(header.scope).declarations@[base;base+1;base+2]};
  let p=replace_function p {f with blocks;scopes;locals=Array.append f.locals locals}in
  let q,r=Semantic_opt.optimize p in
  expect(not(fused r) && execute p=execute q && execute q=(Unix.WEXITED 0,"4\n",""))
    "second header state change was skipped";
  let p=compile "fn f(n:Int)->Int{let mut i=0;let mut j=0;let mut again=0;#scope[opt]{while i<n{i=i+1;}while j<n{j=j+1;}if again==0{again=1;j=0;}}return j;}fn main(){println(f(3));}"in
  let f=named p "f"in
  let loops=Semantic_opt_graph.straight_loops ~safe_node:Semantic_opt.safe_node f in
  let first=List.hd loops and second=List.nth loops 1 in
  let reentry=match f.blocks.(second.exit).terminator with Branch(_,yes,_)->yes|_->assert false in
  let check f label=let p=replace_function p f in let q,r=Semantic_opt.optimize p in
    expect(not(fused r) && execute p=execute q && execute q=(Unix.WEXITED 0,"3\n",""))label in
  let blocks=Array.copy f.blocks in blocks.(reentry)<-{blocks.(reentry)with terminator=Jump second.header};
  check {f with blocks} "second header external reentry was erased";
  let id=Array.length f.blocks in
  let blocks=Array.append f.blocks[|{id;scope=first.scope;operations=[];terminator=Jump second.header}|]in
  blocks.(first.exit)<-{blocks.(first.exit)with terminator=Jump id};
  blocks.(reentry)<-{blocks.(reentry)with terminator=Jump id};
  check {f with blocks} "bridge external reentry was erased"
let with_directory action =
  let directory=Filename.temp_file "xen-prefix-transaction-" ""in
  Sys.remove directory;Unix.mkdir directory 0o700;
  Fun.protect ~finally:(fun()->Sys.readdir directory|>Array.iter(fun name->Sys.remove(Filename.concat directory name));
    Unix.rmdir directory)(fun()->action directory)
let test_cache_publication () = with_directory(fun directory->
  (* Force two independent writers to reserve the same digest slots before
     either commits. Failed parents must never publish their child or alias. *)
  let key_digest _=String.make 32 '0'in
  let make()=Semantic_prefix_cache.create ~directory ~identity:"collision-test" ~key_digest()in
  let stage cache input output=
    let _,root=Semantic_prefix_cache.advance cache ~alias:"scope/context" ~parent:"root" ~input
      ~accept:((=)"") ~compute:(fun()->"")in
    let value,child=Semantic_prefix_cache.advance cache ~alias:"scope/r0" ~parent:root.id ~input:"same child"
      ~accept:(fun _->true) ~compute:(fun()->output)in root,child,value in
  let a=make()and b=make()in
  let ar,ac,_=stage a "A" "forward-A"and br,bc,_=stage b "B" "forward-B"in
  expect(ar.id=br.id && ac.id=bc.id)"collision fixture did not reserve the same slots";
  Semantic_prefix_cache.commit a;Semantic_prefix_cache.commit b;
  expect(Hashtbl.length b.nodes=0 && b.pending=[] && b.aliases=[])
    "conflicting publisher retained an invalid parent chain";
  let rebuilt=make()in let _,_,value=stage rebuilt "B" "forward-B"in
  expect(value="forward-B")"digest collision reused a different prefix result";
  Semantic_prefix_cache.commit rebuilt;
  let warm=make()in let root,child,value=stage warm "B" "unexpected recompute"in
  expect(root.hit && child.hit && value="forward-B")"rebuilt collision chain did not persist";
  Semantic_prefix_cache.commit warm;
  let before=Array.to_list(Sys.readdir directory)|>List.sort Stdlib.compare in
  let p=compile "fn main(){#scope[opt]{let n=7;println(n);}}"in let f=named p "main"in
  let f={f with blocks=Array.map(fun(b:block)->{b with operations=List.filter(fun op->match op.node with
    Eval(_,Int_lit 7L)->false|_->true)b.operations})f.blocks}in
  let invalid=Semantic_ir.checked{(program p)with functions=[f]}in
  let cache=make()in
  (try ignore(Semantic_opt.optimize ~cache invalid);failwith "invalid storage passed"
   with Semantic_analysis.Diagnostic _->());
  expect(before=(Array.to_list(Sys.readdir directory)|>List.sort Stdlib.compare) && cache.pending=[])
    "failed final revalidation published disk cache nodes")
let ()=test_fusion();test_prefix();test_suffix_liveness();test_cached_scalar_and_abort();
  test_header_state_and_entries();test_cache_publication();
  print_endline "Counted loop fusion, exact prefixes, invalidation and fresh liveness passed"
