(* SPDX-License-Identifier: Apache-2.0 *)
open Ast

(* Common contracts contain no CPU register names or instruction encodings. *)
let validate ?(tuple_fields=fun _->None) spec result inputs =
  let fail message = Error ("asm " ^ message) in
  let unique xs = List.length xs=List.length(List.sort_uniq String.compare xs) in
  let outputs=List.map fst spec.output_registers in
  if not spec.volatile then fail "must preserve volatile effects"
  else if String.trim spec.template="" then fail "template cannot be empty"
  else if List.length inputs<>List.length spec.input_registers then fail "input arity mismatch"
  else if not(List.for_all Type_desc.is_integer inputs) then fail "inputs must be integer scalars"
  else if not(unique spec.input_registers && unique spec.clobbers && unique outputs)then fail "duplicate register constraint"
  else if List.exists(fun r->List.mem r spec.input_registers)spec.clobbers then fail "input/clobber overlap"
  else if List.exists(fun r->List.mem r spec.clobbers)outputs then fail "output/clobber overlap"
  else if List.exists(fun(r,tied)->List.mem r spec.input_registers<>tied)spec.output_registers then fail "use inout for a tied input/output register"
  else if outputs=[] && result<>Unit then fail "without out/inout must return Unit"
  else if List.length outputs<>List.length spec.output_types then fail "output type count must match out/inout count"
  else if not(List.for_all Type_desc.is_integer spec.output_types)then fail "output types must be integer scalars"
  else match spec.output_types with
  |[] when result=Unit->Ok()
  |[t] when result=t->Ok()
  |_::_::_ when tuple_fields result=Some spec.output_types->Ok()
  |_->fail "result type differs from output types/tuple layout"

exception Error of string
let fail message = raise(Error("asm: "^message))

(* Deliberately closed syntax: no directives, labels, branches or host assembler. *)
let operands text =
  let start=ref 0 and bracket=ref false and parts=ref [] in
  let add stop =
    let part=String.trim(String.sub text !start (stop- !start))in
    if part=""then fail "empty operand";
    parts:=part::!parts;start:=stop+1 in
  String.iteri(fun i->function
    |'['->if !bracket then fail "nested memory brackets"else bracket:=true
    |']'->if not !bracket then fail "unmatched memory bracket"else bracket:=false
    |',' when not !bracket->add i
    |_->())text;
  if !bracket then fail "unclosed memory bracket";
  if String.trim text=""then []else(add(String.length text);List.rev !parts)

let bracketed text =
  let n=String.length text in
  if n>2 && text.[0]='[' && text.[n-1]=']'then
    Some(String.trim(String.sub text 1(n-2)))
  else None

let instructions template =
  let text=String.map(function '\n'|'\r'->';'|'\t'->' '|c->c)template in
  List.filter_map(fun line->let line=String.trim line in
    if line=""then None else
    let split=String.index_opt line ' ' in
    let name,args=match split with None->line,[]|Some i->
      String.sub line 0 i,
      operands(String.sub line(i+1)(String.length line-i-1))in
    Some(name,args))(String.split_on_char ';' text)

(* Stack storage belongs to one template. Never release the compiler's frame,
   and restore SP before backend output capture uses it again. *)
let stack () =
  let depth=ref 0L in
  let reserve n =
    if n<0L || !depth>Int64.sub Int64.max_int n then fail "stack depth overflow";
    depth:=Int64.add !depth n in
  let release n =
    if n<0L || n> !depth then fail "stack adjustment exceeds allocated stack space";
    depth:=Int64.sub !depth n in
  let finish ()=if !depth<>0L then fail "stack pointer must be restored before asm ends"in
  reserve,release,finish

(* Aliases share physical ownership, but initialization tracks valid low bits.
   A 32-bit write may define 64 bits; 8/16-bit writes preserve undefined high bits. *)
let registers ?(input_types=[]) spec ~canonical ~width ~written_bits register =
  let all=spec.input_registers @ spec.clobbers @ List.map fst spec.output_registers in
  List.iter(fun r->ignore(register r))all;
  let roots xs=List.map canonical xs in
  let unique xs=List.length xs=List.length(List.sort_uniq String.compare xs)in
  let ins=roots spec.input_registers and outs=roots(List.map fst spec.output_registers)and scratch=roots spec.clobbers in
  if not(unique ins && unique outs && unique scratch)then fail "overlapping register aliases";
  if List.exists(fun r->List.mem r ins)scratch then fail "input/clobber register alias overlap";
  if List.exists(fun r->List.mem r outs)scratch then fail "output/clobber register alias overlap";
  List.iter(fun(r,tied)->if List.mem(canonical r)ins<>tied then fail "use inout for overlapping input/output aliases")spec.output_registers;
  if input_types<>[] then begin
    if List.length input_types<>List.length ins then fail "input type arity mismatch";
    List.iter2(fun r t->if Type_desc.bits t>width r then fail("input type exceeds register width '"^r^"'"))spec.input_registers input_types
  end;
  if List.length spec.output_types<>List.length outs then fail "output type count mismatch";
  List.iter2(fun(r,_)t->if Type_desc.bits t>width r then fail("output type exceeds register width '"^r^"'"))spec.output_registers spec.output_types;
  let initialized=Hashtbl.create 16 in
  List.iter(fun r->Hashtbl.add initialized(canonical r)(width r))spec.input_registers;
  let read r=ignore(register r);
    if Option.value ~default:0(Hashtbl.find_opt initialized(canonical r))<width r then
      fail("read of uninitialized register '"^canonical r^"' ("^r^")")in
  let write r=ignore(register r);let root=canonical r in
    if not(List.mem root scratch || List.mem root outs)then fail("write to undeclared output/clobber '"^r^"'");
    let old=Option.value ~default:0(Hashtbl.find_opt initialized root)in
    Hashtbl.replace initialized root(max old(written_bits r))in
  let finish ()=List.iter(fun(r,_)->read r)spec.output_registers in
  read,write,finish
