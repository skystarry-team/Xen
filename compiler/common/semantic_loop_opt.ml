(* SPDX-License-Identifier: Apache-2.0 *)
(* Scoped non-SSA LICM. Keep original lifetimes/assignments in the loop and
   replace invariant definitions with reads of fresh preheader temporaries. *)
open Ast
open Semantic_ir
module I = Set.Make(Int)
type report = { function_name:string; header:block_id; scope:scope_id;
                span:span; hoisted:int; arithmetic:int }
let value_definition (op:operation) = match op.node with
  |Eval(v,_)|Acquire(v,_,_)->Some v.id
  |Initialize(p,_)|Replace(p,_) when p.projections=[]->Some p.root
  |_->None

let optimize_function ~safe_node (f:func) =
  let predecessors=Semantic_opt_graph.predecessors f in
  let addressed=Semantic_opt_graph.addressed f in
  let blocks=ref f.blocks and locals=ref f.locals and scopes=Array.copy f.scopes
  and entry=ref f.entry and reports=ref [] and added=ref 0 in
  Array.iter(fun(header:block)->match header.terminator with
    |Branch(condition,first,exit) when condition.typ=Bool && first<>exit &&
      exit<>header.id && List.mem Opt f.scopes.(header.scope).mode_set &&
      predecessors.(exit)=[header.id]->
      let allowed=Semantic_opt_graph.allowed ~safe_node f addressed header.scope in
      let rec chain previous seen id =
        if id=header.id then Some(List.rev seen)
        else if id=exit || id=f.entry || List.mem id seen ||
          predecessors.(id)<>[previous] || not(allowed f.blocks.(id)) then None
        else match f.blocks.(id).terminator with
          |Jump next->chain id(id::seen)next|_->None in
      if allowed header then (match chain header.id [] first with
        |Some(_::_ as body)->
          let members=header.id::body in
          let ordered=List.concat_map(fun id->
            List.map(fun op->Some op,uses op)f.blocks.(id).operations @
            [None,terminator_uses f.blocks.(id).terminator])members in
          let writes=Hashtbl.create 32 and first_use=Hashtbl.create 32 in
          List.iteri(fun index(op,ids)->
            List.iter(fun id->if not(Hashtbl.mem first_use id)then Hashtbl.add first_use id index)ids;
            Option.iter(fun op->Option.iter(fun id->Hashtbl.replace writes id
              (1+Option.value ~default:0(Hashtbl.find_opt writes id)))(value_definition op))op)ordered;
          let candidates=Hashtbl.create 32 and ordered_candidates=ref [] and roots=ref [] in
          List.iteri(fun index(op,ids)->match op with
            |Some({node=(Eval(v,_)|Acquire(v,_,_));_}as op) when
              f.locals.(v.id).temporary && Hashtbl.find writes v.id=1 &&
              Option.value ~default:max_int(Hashtbl.find_opt first_use v.id)>index &&
              List.for_all(fun id->not(Hashtbl.mem writes id)||Hashtbl.mem candidates id)ids->
                Hashtbl.add candidates v.id op;ordered_candidates:=op::!ordered_candidates;
                (match op.node with Eval(_,Unary _)|Eval(_,Binary _)->roots:=v.id::!roots|_->())
            |_->())ordered;
          let selected=ref I.empty in
          let rec select id=if Hashtbl.mem candidates id && not(I.mem id !selected)then begin
            selected:=I.add id !selected;List.iter select(uses(Hashtbl.find candidates id))end in
          List.iter select !roots;
          let hoisted=List.rev !ordered_candidates |> List.filter(fun op->
            I.mem(Option.get(value_definition op))!selected)in
          (* Same conservative extra scalar-storage budget as leaf expansion. *)
          if hoisted<>[] && !added+List.length hoisted<=32 then begin
            added:= !added+List.length hoisted;
            let ids=Hashtbl.create 32 and prefix=ref [] and deaths=ref [] in
            List.iter(fun op->
              let old=Option.get(value_definition op)in
              let id=Array.length !locals in
              let local={f.locals.(old)with id;name="$loop_invariant";scope=header.scope;parameter=None}in
              locals:=Array.append !locals [|local|];Hashtbl.add ids old(value_of_local local);
              scopes.(header.scope)<-{scopes.(header.scope)with declarations=scopes.(header.scope).declarations@[id]};
              let value(v:value)=Option.value ~default:v(Hashtbl.find_opt ids v.id)in
              let node=match op.node with
                |Eval(v,Unary(n,a))->Eval(value v,Unary(n,value a))
                |Eval(v,Binary(n,a,b))->Eval(value v,Binary(n,value a,value b))
                |Eval(v,r)->Eval(value v,r)
                |Acquire(v,k,p)->let source=value {id=p.root;typ=p.typ;span=p.span}in
                  Acquire(value v,k,place_of_value source)
                |_->assert false in
              let at node={op with scope=header.scope;node}in
              prefix:= !prefix@[at(Storage_live id);at node];deaths:=at(Storage_dead id)::!deaths)hoisted;
            let preheader=Array.length !blocks in
            let redirect = function
              |Jump id when id=header.id->Jump preheader
              |Branch(v,a,b)->Branch(v,(if a=header.id then preheader else a),(if b=header.id then preheader else b))
              |t->t in
            blocks:=Array.mapi(fun id (b:block)->
              if List.mem id members then {b with operations=List.map(fun op->match value_definition op with
                |Some old when Hashtbl.mem ids old->
                  let v=value_of_local f.locals.(old)in {op with node=Acquire(v,Copy,place_of_value(Hashtbl.find ids old))}
                |_->op)b.operations}
              else {b with terminator=redirect b.terminator})!blocks;
            let b=(!blocks).(exit)in
            (!blocks).(exit)<-{b with operations= !deaths@b.operations};
            blocks:=Array.append !blocks [|{id=preheader;scope=header.scope;operations= !prefix;terminator=Jump header.id}|];
            if !entry=header.id then entry:=preheader;
            reports:={function_name=f.name;header=header.id;scope=header.scope;span=condition.span;
              hoisted=List.length hoisted;arithmetic=List.length !roots}::!reports
          end
        |_->())
    |_->())f.blocks;
  {f with blocks= !blocks;locals= !locals;scopes;entry= !entry},List.rev !reports
