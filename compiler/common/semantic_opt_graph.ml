(* SPDX-License-Identifier: Apache-2.0 *)
(* Analysis overlay on checked IR. CFG order is never inferred from block IDs. *)
open Ast
open Semantic_ir
module I = Set.Make(Int)

type access = { reads:I.t; writes:I.t; addressed:I.t }
type loop = { header:block_id; body:block_id list; exit:block_id; scope:scope_id;
              access:access }
type expression = Input of local_id | Constant of int64 | Unary_expr of string * expression
                | Binary_expr of string * expression * expression | Unknown

let definition (op:operation) = match op.node with
  | Eval(v,_) | Acquire(v,_,_) -> Some v.id
  | Initialize(p,_) | Replace(p,_) when p.projections=[] -> Some p.root
  | _ -> None
let predecessors (f:func) =
  let result=Array.make(Array.length f.blocks)[] in
  Array.iter(fun(b:block)->List.iter(fun id->result.(id)<-b.id::result.(id))
    (successors b.terminator))f.blocks;result
let addressed (f:func) = Array.fold_left(fun set (b:block)->List.fold_left(fun set op->
  match op.node with Borrow(_,_,_,p)->I.add p.root set|_->set)set b.operations)I.empty f.blocks
let nested (f:func) ancestor id =
  let rec walk id=id=ancestor || match f.scopes.(id).parent with
    Some parent->walk parent|None->false in walk id
let access operations = List.fold_left(fun a (op:operation)->
  let reads=match op.node with Storage_live _|Storage_dead _|Drop _->[]|_->uses op in
  {reads=List.fold_left(fun s id->I.add id s)a.reads reads;
   writes=Option.fold ~none:a.writes ~some:(fun id->I.add id a.writes)(definition op);
   addressed=(match op.node with Borrow(_,_,_,p)->I.add p.root a.addressed|_->a.addressed)})
  {reads=I.empty;writes=I.empty;addressed=I.empty}operations
let allowed ~safe_node (f:func) addressed scope (b:block) =
  let compatible id=nested f scope id && f.scopes.(id).mode_set=f.scopes.(scope).mode_set in
  compatible b.scope && List.for_all(fun (op:operation)->compatible op.scope && safe_node op.node &&
    (match op.node with Storage_live id|Storage_dead id->
       Type_desc.is_integer f.locals.(id).typ || f.locals.(id).typ=Bool|_->true) &&
    not(List.exists(fun id->I.mem id addressed)(uses op @ defines op)))b.operations
let straight_loops ~safe_node (f:func) =
  let pred=predecessors f and address=addressed f in
  Array.to_list f.blocks |> List.filter_map(fun(header:block)->match header.terminator with
    | Branch(condition,first,exit) when condition.typ=Bool && first<>exit && exit<>header.id &&
        List.mem Opt f.scopes.(header.scope).mode_set && pred.(exit)=[header.id] &&
        allowed ~safe_node f address header.scope header ->
      let rec chain previous seen id =
        if id=header.id then Some(List.rev seen)
        else if id=exit || id=f.entry || List.mem id seen || pred.(id)<>[previous] ||
          not(allowed ~safe_node f address header.scope f.blocks.(id)) then None
        else match f.blocks.(id).terminator with Jump next->chain id(id::seen)next|_->None in
      (match chain header.id [] first with Some(_::_ as body)->
        let operations=List.concat_map(fun id->f.blocks.(id).operations)(header.id::body) in
        Some{header=header.id;body;exit;scope=header.scope;access=access operations}|_->None)
    | _ -> None)

(* Symbolic transfer is deliberately local and non-SSA aware. A read after a
   write observes that version; unknown operations never supply a constant. *)
let expressions operations =
  let env=Hashtbl.create 32 in
  let get id=Option.value ~default:(Input id)(Hashtbl.find_opt env id) in
  List.iter(fun(op:operation)->match op.node with
    | Storage_live id|Storage_dead id->Hashtbl.remove env id
    | Eval(v,r)->let e=match r with Int_lit n->Constant n
        | Unary(n,a)->Unary_expr(n,get a.id)
        | Binary(n,a,b)->Binary_expr(n,get a.id,get b.id)|_->Unknown in
        Hashtbl.replace env v.id e
    | Acquire(v,(Read|Copy),p) when p.projections=[]->Hashtbl.replace env v.id(get p.root)
    | Initialize(p,v)|Replace(p,v) when p.projections=[]->Hashtbl.replace env p.root(get v.id)
    | _->Option.iter(fun id->Hashtbl.replace env id Unknown)(definition op))operations;
  get

let scope_alias (f:func) scope =
  let rec path id=match f.scopes.(id).parent with None->"s0"|Some parent->
    let ordinal=Array.fold_left(fun n(s:scope)->if s.id<id && s.parent=Some parent then n+1 else n)0 f.scopes in
    path parent^"/s"^string_of_int ordinal in f.name^"/"^path scope

(* Stable traversal of the graph, including unreachable blocks after the
   reachable graph. This is a conservative cache lineage, not execution order. *)
let block_order (f:func) =
  let seen=Array.make(Array.length f.blocks)false and result=ref [] in
  let rec visit id=if not seen.(id)then begin seen.(id)<-true;result:=id::!result;
    let next=match f.blocks.(id).terminator with Branch(_,a,b)->[a;b]|Jump b->[b]|_->[]in
    List.iter visit next end in
  visit f.entry;Array.iter(fun(b:block)->visit b.id)f.blocks;List.rev !result
