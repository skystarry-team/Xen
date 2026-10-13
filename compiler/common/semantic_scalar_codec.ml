(* SPDX-License-Identifier: Apache-2.0 *)
(* Cache only nontrapping scalar forward rewrites. Metadata comes from the
   current checked input; disk records cannot introduce calls or ownership ops. *)
open Ast
open Semantic_ir
let encode operations (constants,copies,common) =
  let line op=match op.node with
    | Storage_live id->Printf.sprintf "live %d" id
    | Storage_dead id->Printf.sprintf "dead %d" id
    | Drop p->Printf.sprintf "drop %d" p.root
    | Acquire(v,k,p)->Printf.sprintf "acquire %d %s %d" v.id (if k=Read then "read" else "copy")p.root
    | Initialize(p,v)->Printf.sprintf "initialize %d %d" p.root v.id
    | Eval(v,Int_lit n)->Printf.sprintf "integer %d %Ld" v.id n
    | Eval(v,Bool_lit b)->Printf.sprintf "boolean %d %d" v.id(if b then 1 else 0)
    | Eval(v,Unary(n,a))->Printf.sprintf "unary %d %s %d" v.id n a.id
    | Eval(v,Binary(n,a,b))->Printf.sprintf "binary %d %s %d %d" v.id n a.id b.id
    | _->invalid_arg "non-scalar cache operation" in
  String.concat "\n"(Printf.sprintf "%d %d %d" constants copies common::List.map line operations)
let decode (f:func) originals text = try
  let invalid()=invalid_arg "scalar cache format" in
  let number s=int_of_string s in
  let local id=if id<0||id>=Array.length f.locals then invalid()else f.locals.(id)in
  let value (v:value) id=let id=number id in
    if (local id).typ<>v.typ then invalid();{v with id}in
  let result op id=let v=match op.node with Eval(v,_)|Acquire(v,_,_)->v|_->invalid()in
    if number id<>v.id then invalid();v in
  let operation (op:operation) line =
    let node=match String.split_on_char ' ' line,op.node with
      | ["live";id],Storage_live n when number id=n->Storage_live n
      | ["dead";id],Storage_dead n when number id=n->Storage_dead n
      | ["drop";id],Drop p when number id=p.root && p.projections=[]->Drop p
      | ["acquire";id;kind;root],Acquire(v,k,p) when number id=v.id && p.projections=[] &&
          ((kind="read" && k=Read)||(kind="copy" && k=Copy))->
          let root=value {id=p.root;typ=p.typ;span=p.span}root in Acquire(v,k,{p with root=root.id})
      | ["acquire";id;"copy";root],Eval(v,_)->
          ignore(result op id);let root=value v root in Acquire(v,Copy,place_of_value root)
      | ["initialize";root;id],Initialize(p,v) when number root=p.root && p.projections=[]->
          Initialize(p,value v id)
      | ["integer";id;n],(Eval _|Acquire _)->let v=result op id in
          if not(Type_desc.is_integer v.typ)then invalid();Eval(v,Int_lit(Int64.of_string n))
      | ["boolean";id;b],(Eval _|Acquire _) when b="0"||b="1"->let v=result op id in
          if v.typ<>Bool then invalid();Eval(v,Bool_lit(b="1"))
      | ["unary";id;n;a],Eval(v,Unary(name,operand)) when n=name->
          ignore(result op id);Eval(v,Unary(n,value operand a))
      | ["binary";id;n;a;b],Eval(v,Binary(name,left,right)) when n=name->
          ignore(result op id);Eval(v,Binary(n,value left a,value right b))
      | _->invalid() in {op with node} in
  match String.split_on_char '\n' text with
  | stats::lines when List.length lines=List.length originals->
      (match String.split_on_char ' ' stats with
       | [c;p;e]->let c=number c and p=number p and e=number e in
           let count=List.length originals in
           if c<0||c>count||p<0||p>2*count||e<0||e>count then invalid();
           Some(List.map2 operation originals lines,(c,p,e))
       | _->None)
  | _->None
  with Failure _|Invalid_argument _->None
