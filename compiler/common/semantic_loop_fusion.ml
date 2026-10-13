(* SPDX-License-Identifier: Apache-2.0 *)
(* Horizontal fusion of independent, equally-sized counted scalar loops. *)
open Ast
open Semantic_ir
module G = Semantic_opt_graph
module I = G.I
type report = { function_name:string; alias:string; left:block_id; right:block_id;
                fused:bool; reason:string }
type counted = { induction:local_id; bound:G.expression; typ:typ }

let private_header (f:func) (header:block) =
  let writes=(G.access header.operations).writes in
  let initialized=ref I.empty and definitions=ref I.empty in
  let private_local id=f.locals.(id).temporary && f.locals.(id).scope=header.scope in
  List.for_all(fun(op:operation)->
    let read_before_write=List.exists(fun id->I.mem id writes && not(I.mem id !initialized))(uses op)in
    let safe=not read_before_write && match op.node with
      | Storage_live id|Storage_dead id|Drop{root=id;projections=[];_}->private_local id
      | _->Option.fold ~none:false ~some:(fun id->private_local id && not(I.mem id !definitions))(G.definition op)in
    (match op.node with Storage_live id|Storage_dead id->initialized:=I.remove id !initialized
      | _->Option.iter(fun id->initialized:=I.add id !initialized;definitions:=I.add id !definitions)(G.definition op));
    safe)header.operations

let counted (f:func) (loop:G.loop) =
  let header=f.blocks.(loop.header) in
  let expression=G.expressions header.operations in
  let condition=match header.terminator with Branch(v,_,_)->expression v.id|_->G.Unknown in
  match condition with
  | G.Binary_expr("<",G.Input induction,(G.Input _|G.Constant _ as bound))
      when Type_desc.is_integer f.locals.(induction).typ && not f.locals.(induction).temporary ->
    let body=List.concat_map(fun id->f.blocks.(id).operations)loop.body in
    let writes=List.filter(fun op->G.definition op=Some induction)body in
    let step=(G.expressions body)induction in
    let header_writes=(G.access header.operations).writes in
    let bound_stable=match bound with G.Input id->not(I.mem id loop.access.writes)|_->true in
    if private_header f header && List.length writes=1 && step=G.Binary_expr("+",G.Input induction,G.Constant 1L) &&
       not(I.mem induction header_writes) && bound_stable
    then Some{induction;bound;typ=f.locals.(induction).typ} else None
  | _ -> None

let initial_values (f:func) (loop:G.loop) =
  let pred=G.predecessors f in
  let rec before seen id =
    if List.mem id seen then None else
    let incoming=List.filter(fun p->not(List.mem p loop.body))pred.(id) in
    match incoming with
    | [] when id=f.entry->Some []
    | [p] when f.blocks.(p).terminator=Jump id->
        Option.map(fun ops->ops @ f.blocks.(p).operations)(before(id::seen)p)
    | _ -> None in
  Option.map G.expressions(before [] loop.header)

let optimize_function ~safe_node (original:func) =
  let current=ref original and reports=ref [] and attempts=Hashtbl.create 16 and budget=ref 32 in
  let rec run () =
    let f= !current in
    let loops=G.straight_loops ~safe_node f in
    let predecessors=G.predecessors f in
    let by_header=Hashtbl.create 16 in List.iter(fun(l:G.loop)->Hashtbl.add by_header l.header l)loops;
    let pair (first:G.loop) =
      let rec next seen id =
        if Hashtbl.mem by_header id then Some(Hashtbl.find by_header id,List.rev seen)
        else if List.mem id seen || List.mem id first.body || id=first.header then None
        else match f.blocks.(id).terminator with Jump target->next(id::seen)target|_->None in
      next [] first.exit in
    let chosen=List.find_map(fun(first:G.loop)->match pair first with
      | Some(second,bridge) when not(Hashtbl.mem attempts(first.header,second.header))->
        Hashtbl.add attempts(first.header,second.header)();
        let bridge_entry=ref first.header in
        let exclusive_bridge=List.for_all(fun id->let exclusive=id<>f.entry &&
          predecessors.(id)=[!bridge_entry]in bridge_entry:=id;exclusive)bridge in
        let expected=List.sort_uniq compare[!bridge_entry;List.hd(List.rev second.body)]in
        let exclusive_header=second.header<>f.entry &&
          List.sort_uniq compare predecessors.(second.header)=expected in
        let reason=if first.scope<>second.scope then "different lexical scope" else
          if not(exclusive_bridge && exclusive_header)then "external entry into bridge or second header" else
          if not(private_header f f.blocks.(second.header))then "second header changes observable or carried state" else
          let transparent id=let b=f.blocks.(id) in b.scope=first.scope &&
            List.for_all(fun(op:operation)->op.scope=first.scope && match op.node with
              | Storage_dead id|Drop{root=id;projections=[];_}->
                  f.locals.(id).temporary && (Type_desc.is_integer f.locals.(id).typ || f.locals.(id).typ=Bool)
              | _->false)b.operations in
          if not(List.for_all transparent bridge) then "effect or initialization between loops" else
          match counted f first,counted f second with
          | Some a,Some b when a.induction<>b.induction && a.typ=b.typ && a.bound=b.bound->
            let conflict a b=not(I.is_empty(I.inter a.G.writes(I.union b.G.reads b.G.writes)))in
            if conflict first.access second.access || conflict second.access first.access
            then "cross-loop read/write dependence" else
            (* Body must not observe a header temporary whose initialization is
               skipped when the second header is removed from the iteration. *)
            let header_defs=(G.access f.blocks.(second.header).operations).writes in
            let body_reads=(G.access(List.concat_map(fun id->f.blocks.(id).operations)second.body)).reads in
            if not(I.is_empty(I.inter header_defs body_reads))then "body depends on second header temporary" else
            (match initial_values f first with
             | Some values->(match values a.induction,values b.induction with
                 | G.Constant x,G.Constant y when x=y->"fused"
                 | _->"initial induction values are not identical constants")
             | None->"initial induction values are not provable")
          | _->"different bounds, types or non-unit induction" in
        let fused=reason="fused" && !budget>0 in
        reports:={function_name=f.name;alias=G.scope_alias f first.scope;
          left=first.header;right=second.header;fused;
          reason=(if reason="fused" && !budget=0 then "fusion budget" else reason)}::!reports;
        if fused then Some(first,second) else None
      | _->None)loops in
    match chosen with
    | None->()
    | Some(first,second)->
      decr budget;
      let blocks=Array.copy f.blocks in
      let first_tail=List.hd(List.rev first.body) and second_tail=List.hd(List.rev second.body) in
      blocks.(first_tail)<-{blocks.(first_tail)with terminator=Jump(List.hd second.body)};
      blocks.(second_tail)<-{blocks.(second_tail)with terminator=Jump first.header};
      (* Keep the last header evaluation and its original storage cleanup.
         Equal trip counts prove its condition is false after the fused loop. *)
      blocks.(second.header)<-{blocks.(second.header)with terminator=Jump second.exit};
      current:={f with blocks};run () in
  run ();!current,List.rev !reports
