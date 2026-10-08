(* SPDX-License-Identifier: Apache-2.0 *)
(* Bounded, local optimization of the existing non-SSA Semantic IR. No call
   ownership summary is used as evidence of purity. *)
open Ast
open Semantic_ir
module I = Set.Make(Int)

type level = Off | Basic
type counts = { mutable constants:int; mutable copies:int; mutable common:int;
                mutable dead:int; mutable fused:int }
type region = { function_name:string; block:int; scope:int; span:span;
                inputs:(local_id * typ) list; outputs:(local_id * typ) list;
                split_reason:string; counts:counts }
type report = { regions:region list; fusion:counts }
let counts () = {constants=0;copies=0;common=0;dead=0;fused=0}
let scalar t = Type_desc.is_integer t || t=Bool
let safe_rvalue = function
  |Int_lit _|Bool_lit _->true
  |Unary("!",v)->v.typ=Bool
  |Unary("-",v)->Type_desc.is_integer v.typ
  |Binary(op,a,b)->a.typ=b.typ &&
      ((Type_desc.is_integer a.typ && List.mem op ["+";"-";"*";"==";"!=";"<";"<=";">";">="])
       || (a.typ=Bool && List.mem op ["==";"!="]))
  |_->false
let safe_node = function
  |Storage_live _|Storage_dead _->true
  |Drop p->p.projections=[] && scalar p.typ
  |Acquire(v,(Read|Copy),p)->scalar v.typ && p.projections=[]
  |Initialize(p,v)->scalar v.typ && p.projections=[]
  |Eval(v,r)->scalar v.typ && safe_rvalue r
  |_->false
let scalar_uses op = match op.node with Drop p when scalar p.typ && p.projections=[]->[]|_->uses op
let add ids set = List.fold_left(fun set id->I.add id set)set ids
let wrap t n = let bits=Type_desc.bits t in
  if bits=64 then n else
  let n=Int64.logand n (Type_desc.max_unsigned bits) in
  if Type_desc.is_signed_int t && Int64.compare n (Type_desc.max_signed bits)>0
  then Int64.sub n (Int64.shift_left 1L bits) else n
let literal t n = if t=Bool then Bool_lit(n<>0L) else Int_lit(wrap t n)
let fold t r get = match r with
  |Int_lit n->Some(wrap t n)|Bool_lit b->Some(if b then 1L else 0L)
  |Unary(op,a)->Option.map(fun n->if op="!"then (if n=0L then 1L else 0L)else wrap t(Int64.neg n))(get a)
  |Binary(op,a,b)->(match get a,get b with Some x,Some y->
      let cmp=if Type_desc.is_unsigned_int a.typ then Int64.unsigned_compare x y else Int64.compare x y in
      let bool b=if b then 1L else 0L in
      Some(match op with "+"->wrap t(Int64.add x y)|"-"->wrap t(Int64.sub x y)
        |"*"->wrap t(Int64.mul x y)|"=="->bool(cmp=0)|"!="->bool(cmp<>0)
        |"<"->bool(cmp<0)|"<="->bool(cmp<=0)|">"->bool(cmp>0)|">="->bool(cmp>=0)|_->assert false)
    |_->None)
  |_->None

(* Candidate decisions use the original checked program, once. Cloned code
   is never revisited for fusion, even if it later simplifies. *)
let candidate (f:func) =
  Array.length f.blocks=1 && Array.length f.scopes=1 && scalar f.return_type &&
  Array.for_all(fun(l:local)->scalar l.typ)f.locals &&
  List.for_all(fun (op:operation)->op.scope=0 && safe_node op.node)f.blocks.(0).operations &&
  (match f.blocks.(0).terminator with Return(Some _)->true|_->false) &&
  List.length(List.filter(fun (op:operation)->match op.node with Eval _|Acquire _|Initialize _->true|_->false)f.blocks.(0).operations)<=32
let fuse program stats =
  let targets=Hashtbl.create 16 in
  List.iter(fun(f:func)->if candidate f then Hashtbl.add targets f.name f)program.functions;
  let functions=List.map(fun(f:func)->
    let locals=ref(Array.to_list f.locals) and scopes=ref(Array.to_list f.scopes) in
    let local_count=ref(Array.length f.locals) and scope_count=ref(Array.length f.scopes) in
    let slot_end start locals=Array.fold_left(fun offset (l:local)->
      let size,alignment=match l.typ with
        |Named name->let layout=List.find(fun(l:struct_layout)->l.name=name)program.layouts in layout.size,layout.alignment
        |t->let descriptor=Type_desc.describe t in descriptor.size,descriptor.alignment in
      Type_desc.align_up offset alignment+max 8 size)start locals in
    let initial_end=slot_end 8 f.locals in
    let added_ops=ref 0 and stack_end=ref initial_end in
    let blocks=Array.map(fun(b:block)->let operations=List.concat_map(fun (op:operation)->match op.node with
      |Eval(destination,Call(name,args)) when Hashtbl.mem targets name->
        let callee=Hashtbl.find targets name in
        let body=callee.blocks.(0) in
        let cost=List.length body.operations+2*List.length args+4-1 in
        let next_end=slot_end !stack_end callee.locals in
        if callee.id=f.id || callee.mode_set<>f.scopes.(op.scope).mode_set ||
           !added_ops+cost>256 || next_end-initial_end>256 then [op] else begin
          added_ops:= !added_ops+cost;stack_end:=next_end;stats.fused<-stats.fused+1;
          let base= !local_count and scope= !scope_count in
          local_count:=base+Array.length callee.locals;incr scope_count;
          let value(v:value)={v with id=base+v.id} in
          let place(p:place)={p with root=base+p.root} in
          let rvalue=function Unary(n,v)->Unary(n,value v)|Binary(n,a,b)->Binary(n,value a,value b)|r->r in
          let node=function
            |Storage_live id->Storage_live(base+id)|Storage_dead id->Storage_dead(base+id)
            |Acquire(v,k,p)->Acquire(value v,k,place p)|Eval(v,r)->Eval(value v,rvalue r)
            |Initialize(p,v)->Initialize(place p,value v)|Drop p->Drop(place p)|_->assert false in
          let new_locals=Array.to_list(Array.map(fun(l:local)->{l with id=base+l.id;scope;parameter=None})callee.locals) in
          locals:= !locals @ new_locals;
          scopes:= !scopes @ [{callee.scopes.(0) with id=scope;parent=Some op.scope;
                              declarations=List.map(fun(l:local)->l.id)new_locals}];
          let at node={op with node} in
          let inside node={op with scope;node} in
          let parameters=List.concat(List.map2(fun id argument->
            let p=place_of_value(value(value_of_local callee.locals.(id)))in
            [inside(Storage_live p.root);inside(Initialize(p,argument))])callee.params args)in
          let result=match body.terminator with Return(Some v)->value v|_->assert false in
          [at(Logical_call_enter callee.id)] @ parameters @
          List.map(fun (o:operation)->{o with scope;node=node o.node})body.operations @
          [inside(Acquire(destination,Copy,place_of_value result));inside(Storage_dead result.id);
           at(Logical_call_exit callee.id)]
        end
      |_->[op])b.operations in {b with operations})f.blocks in
    {f with locals=Array.of_list !locals;scopes=Array.of_list !scopes;blocks})program.functions in
  {program with functions}

let boundary (op:operation) = match op.node with
  |Logical_call_enter _|Logical_call_exit _->"logical call"
  |Borrow _->"borrow/address"
  |Eval(_,Call _)->"direct call/effect unknown"
  |Eval(_,Indirect_call _)->"indirect call/effect unknown"
  |Eval(_,Binary(("/"|"%"),_,_))->"fallible arithmetic"
  |Acquire _|Initialize _|Replace _->"projection or non-scalar memory"
  |Drop _|Forget _|Drop_flag _->"ownership bookkeeping"
  |Eval _->"non-scalar, allocation, memory or fallible operation"
  |Storage_live _|Storage_dead _->"non-scalar storage"
type chunk = { start:int; stop:int; scope:scope_id; operations:operation list;
               reason:string; calculation:bool }
let calculation_chunks (f:func) =
  let addressed=Array.fold_left(fun set (b:block)->List.fold_left(fun set op->match op.node with
    Borrow(_,_,_,p)->I.add p.root set|_->set)set b.operations)I.empty f.blocks in
  let allowed (op:operation) = safe_node op.node &&
    (match op.node with Storage_live id|Storage_dead id->scalar f.locals.(id).typ|_->true) &&
    not(List.exists(fun id->I.mem id addressed)(uses op @ defines op)) in
  Array.map(fun (b:block)->
    let pending=ref [] and chunks=ref [] and scope=ref b.scope and start=ref 0 in
    let flush stop reason=if !pending<>[] then begin
      chunks:={start= !start;stop;scope= !scope;operations=List.rev !pending;reason;calculation=true}::!chunks;
      pending:=[] end in
    List.iteri(fun index (op:operation)->
      if op.scope<> !scope then(flush index "lexical scope";scope:=op.scope);
      if allowed op then (if !pending=[] then start:=index;pending:=op::!pending)else begin
        let reason=if List.exists(fun id->I.mem id addressed)(uses op @ defines op)then "address-taken local"else boundary op in
        flush index reason;
        chunks:={start=index;stop=index+1;scope=op.scope;operations=[op];reason;calculation=false}::!chunks
      end)b.operations;
    flush(List.length b.operations) "CFG/terminator";List.rev !chunks)f.blocks
let optimize_function (f:func) =
  let next=ref 0 in
  let partitions=Array.map(List.map(fun chunk->
    let id=if chunk.calculation then(let id= !next in incr next;Some id)else None in
    id,chunk.operations,chunk.reason))(calculation_chunks f)in
  let outside=Array.make !next I.empty in
  let use_regions=Array.make(Array.length f.locals)I.empty and fixed=ref I.empty in
  Array.iteri(fun bid chunks->fixed:=add(terminator_uses f.blocks.(bid).terminator)!fixed;
    List.iter(fun(id,ops,_)->List.iter(fun (op:operation)->List.iter(fun local->match id with
      None->fixed:=I.add local !fixed|Some region->use_regions.(local)<-I.add region use_regions.(local))
      (scalar_uses op))ops)chunks)partitions;
  Array.iter(fun chunks->List.iter(fun(region,ops,_)->match region with None->()|Some region->
    List.iter(fun op->List.iter(fun id->
      if I.mem id !fixed || I.exists(fun other->other<>region)use_regions.(id)
      then outside.(region)<-I.add id outside.(region))(defines op))ops)chunks)partitions;
  let reports=ref [] in
  let blocks=Array.mapi(fun bid chunks->let operations=List.concat_map(fun(id,ops,reason)->match id with None->ops|Some id->
    let stats=counts() in
    (* Sparse per-region facts: bookkeeping in unrelated regions must not
       make a function with many effect boundaries quadratic in its locals. *)
    let versions=Hashtbl.create 16 in
    let version id=Option.value ~default:0(Hashtbl.find_opt versions id)in
    let constants=Hashtbl.create 16 and aliases=Hashtbl.create 16 in
    let common=Hashtbl.create 32 and expressions=Hashtbl.create 16 in
    let rec representative seen (v:value)=match Hashtbl.find_opt aliases v.id with
      |Some(other,born) when version other=born && not(I.mem other seen)->
        representative(I.add v.id seen){v with id=other}
      |_->v in
    let get(v:value)=Hashtbl.find_opt constants v.id in
    let substitute v=let other=representative I.empty v in if other.id<>v.id then stats.copies<-stats.copies+1;other in
    let forward=List.map(fun (op:operation)->
      let node=match op.node with
        |Eval(v,Unary(n,a))->Eval(v,Unary(n,substitute a))
        |Eval(v,Binary(n,a,b))->Eval(v,Binary(n,substitute a,substitute b))
        |Acquire(v,k,p)->let x=substitute {id=p.root;typ=p.typ;span=p.span}in Acquire(v,k,{p with root=x.id})
        |Initialize(p,v)->Initialize(p,substitute v)|n->n in
      let fact,alias,key=match node with
        |Eval(v,r)->let fact=fold v.typ r get in
            let key=match r with
              |Unary(n,a)->Some(v.typ,n,[a.typ,a.id,version a.id])
              |Binary(n,a,b)->Some(v.typ,n,[a.typ,a.id,version a.id;b.typ,b.id,version b.id])|_->None in
            fact,None,key
        |Acquire(_,_,p)->get {id=p.root;typ=p.typ;span=p.span},Some(p.root,version p.root),Hashtbl.find_opt expressions p.root
        |Initialize(_,v)->get v,Some(v.id,version v.id),Hashtbl.find_opt expressions v.id
        |_->None,None,None in
      let reused=Option.bind key(fun key->match Hashtbl.find_opt common key with
        Some(other,born)when version other=born->Some other|_->None) in
      List.iter(fun id->Hashtbl.replace versions id (version id+1);Hashtbl.remove constants id;
        Hashtbl.remove aliases id;Hashtbl.remove expressions id)(defines {op with node});
      let node=match node,fact,reused with
        |Eval(v,(Int_lit _|Bool_lit _)),_,_->Eval(v,literal v.typ(Option.get fact))
        |Eval(v,_),Some n,_->stats.constants<-stats.constants+1;Eval(v,literal v.typ n)
        |Acquire(v,_,_),Some n,_->stats.constants<-stats.constants+1;Eval(v,literal v.typ n)
        |Eval(v,_),None,Some other when other<>v.id->stats.common<-stats.common+1;
            Acquire(v,Copy,{root=other;projections=[];typ=v.typ;span=v.span})
        |_->node in
      let record id alias=
        Option.iter(fun n->Hashtbl.replace constants id n)fact;
        (match alias with Some(other,born)when other<>id->Hashtbl.replace aliases id(other,born)|_->());
        Option.iter(fun key->Hashtbl.replace expressions id key;Hashtbl.replace common key(id,version id))key in
      (match node with Eval(v,_)|Acquire(v,_,_)->
          let alias=match reused,fact with Some other,None->Some(other,version other)|_->alias in
          record v.id alias
        |Initialize(p,_)->record p.root alias
        |_->());
      {op with node})ops in
    let live=ref outside.(id) in
    let result=List.fold_right(fun op kept->
      let removable=match op.node with Eval(v,_)|Acquire(v,_,_)->f.locals.(v.id).temporary && not(I.mem v.id !live)
        |Initialize(p,_)->f.locals.(p.root).temporary && not(I.mem p.root !live)|_->false in
      if removable then(stats.dead<-stats.dead+1;kept)else begin
        live:=add(scalar_uses op)(List.fold_left(fun s id->I.remove id s)!live(defines op));op::kept end)forward [] in
    let defined=ref I.empty and inputs=ref I.empty in
    List.iter(fun (op:operation)->inputs:=I.union !inputs(I.diff(add(scalar_uses op)I.empty)!defined);
      match op.node with
      |Storage_live id|Storage_dead id->defined:=I.remove id !defined
      |_->defined:=add(defines op)!defined)result;
    let typed set=I.elements set |> List.map(fun id->id,f.locals.(id).typ)in
    let first=List.hd ops in
    reports:={function_name=f.name;block=bid;scope=first.scope;span=first.span;inputs=typed !inputs;
      outputs=typed(I.inter !defined outside.(id));split_reason=reason;counts=stats}::!reports;
    result)chunks in {f.blocks.(bid) with operations})partitions in
  {f with blocks},List.rev !reports

let optimize checked =
  let stats=counts() in
  let p=fuse(program checked)stats in
  let results=List.map optimize_function p.functions in
  let p={p with functions=List.map fst results}in
  let checked=Semantic_analysis.revalidate p in
  checked,{regions=List.concat_map snd results;fusion=stats}
let print_report report =
  Printf.eprintf "opt basic: fused=%d regions=%d\n" report.fusion.fused(List.length report.regions);
  let values xs=String.concat ","(List.map(fun(id,t)->Printf.sprintf "l%d:%s"id(string_of_typ t))xs)in
  List.iter(fun r->Printf.eprintf "opt region %s b%d s%d %s:%d:%d inputs=[%s] outputs=[%s] split=%s constants=%d copies=%d common=%d dead=%d\n"
    r.function_name r.block r.scope r.span.file r.span.line r.span.column(values r.inputs)(values r.outputs)
    r.split_reason r.counts.constants r.counts.copies r.counts.common r.counts.dead)report.regions
let apply ?(report=false) level checked = match level with Off->checked|Basic->
  let checked,summary=optimize checked in if report then print_report summary;checked
