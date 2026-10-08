(* SPDX-License-Identifier: Apache-2.0 *)
open Ast
module Ir = Typed_ast
module S = Set.Make(String)
module T = Type_desc

type diagnostic = {
  span : span;
  message : string;
  notes : (span * string) list;
  help : string option;
}
exception Invalid of diagnostic
type binding = { typ : typ; mutable_ : bool; ir_name : string }
type signature = { params : typ list; result : typ; span : span }

let invalid ?(notes=[]) ?help span message = raise (Invalid { span; message; notes; help })
let canonical = T.canonicalize
let rec source_type_name = function
  | I64 -> "Int (I64)" | F64 -> "Float (F64)"
  | Ptr I64 -> "Ptr<Int> (Ptr<I64>)" | Vec I64 -> "Vec<Int> (Vec<I64>)" | Vec F64 -> "Vec<Float> (Vec<F64>)"
  | Ref(m,t)->"&"^(if m then "mut " else "")^source_type_name t
  | t -> string_of_typ t
let numeric_conversion_name = function
  | I8 -> "i8" | U8 -> "u8" | I16 -> "i16" | U16 -> "u16"
  | I32 -> "i32" | U32 -> "u32" | I64 -> "i64" | U64 -> "u64"
  | F32 -> "f32" | F64 -> "f64"
  | _ -> invalid_arg "numeric_conversion_name"
let require span expected actual = if expected <> actual then
  let help =
    let expected = canonical expected and actual = canonical actual in
    if T.is_numeric expected && T.is_numeric actual then
      Some ("convert explicitly with " ^ numeric_conversion_name expected ^ "(...)")
    else None
  in
  invalid ?help span
    (Printf.sprintf "expected %s, found %s" (source_type_name expected) (source_type_name actual))
let layout_table : (string, Ir.struct_layout) Hashtbl.t = Hashtbl.create 16
let managed = function String | Vec _ | Box _ -> true | Named n -> (Hashtbl.find layout_table n).managed | _ -> false
(* Ptr itself remains a copyable non-owning descriptor.  An aggregate that wraps
   one is deliberately linear, however: copying the wrapper would make it far
   too easy to free through one copy and keep using another. *)
let rec aggregate_field_move_only_seen seen = function
  | Ptr _ | File | Box _ -> true
  | Vec t -> move_only_seen seen t
  | Named n ->
      if S.mem n seen then false else
      List.exists (fun (f:Ir.struct_field) -> aggregate_field_move_only_seen (S.add n seen) f.typ)
        (Hashtbl.find layout_table n).fields
  | _ -> false
and move_only_seen seen = function
  | File | Box _ -> true
  | Vec t -> move_only_seen seen t
  | Named n ->
      if S.mem n seen then false else
      List.exists (fun (f:Ir.struct_field) -> aggregate_field_move_only_seen (S.add n seen) f.typ)
        (Hashtbl.find layout_table n).fields
  | _ -> false
let aggregate_field_move_only typ = aggregate_field_move_only_seen S.empty typ
let move_only typ = move_only_seen S.empty typ
let rec equality_capable = function t when T.is_numeric t->true|Bool|String->true|Vec t->equality_capable t|_->false
let referable typ = match canonical typ with Unit|Ref _|Slice _ -> false | _ -> true
let contains_slice typ =
  let rec loop seen = function
    | Slice _->true|Box t|Vec t|Ptr t|Ref(_,t)->loop seen t
    | Named n->
        if S.mem n seen then false else
        (match Hashtbl.find_opt layout_table n with
         | Some l->List.exists(fun (f:Ir.struct_field)->loop(S.add n seen)f.typ)l.fields
         | None->false)
    | Apply(_,ts)|Tuple ts->List.exists(loop seen)ts
    | Function(ts,r)->List.exists(loop seen)(r::ts)|_->false
  in loop S.empty typ
let contains_ptr typ =
  let rec loop seen = function
    | Ptr _ -> true
    | Ref (_,t) | Box t | Vec t | Slice t -> loop seen t
    | Named n ->
        if S.mem n seen then false else
        (match Hashtbl.find_opt layout_table n with
         | Some l -> List.exists (fun (f:Ir.struct_field) -> loop (S.add n seen) f.typ) l.fields
         | None -> false)
    | Apply (n,ts) as applied ->
        let concrete=string_of_typ applied in
        List.exists(loop seen)ts ||
        (not(S.mem concrete seen) && match Hashtbl.find_opt layout_table concrete with
         | Some l->List.exists(fun(f:Ir.struct_field)->loop(S.add concrete seen)f.typ)l.fields
         | None->not(S.mem n seen) && (match Hashtbl.find_opt layout_table n with
             | Some l->List.exists(fun(f:Ir.struct_field)->loop(S.add n seen)f.typ)l.fields
             | None->false))
    | Tuple ts -> List.exists (loop seen) ts
    | Function(ts,r) -> List.exists (loop seen) (r::ts)
    | _ -> false
  in loop S.empty typ
let rec raw_safe = function
  | I8|U8|I16|U16|I32|U32|I64|U64|F32|F64|Bool -> true
  | Named n -> let l=Hashtbl.find layout_table n in
      (not l.managed) && List.for_all(fun (f:Ir.struct_field)->raw_safe f.typ)l.fields
  | _ -> false

let decimal_compare a b =
  let trim s = let rec loop i = if i+1<String.length s && s.[i]='0' then loop(i+1) else i in
    String.sub s (loop 0) (String.length s-loop 0) in
  let a=trim a and b=trim b in
  if String.length a<>String.length b then compare(String.length a)(String.length b) else String.compare a b
let unsigned_limit = function
  | U8 -> "255" | U16 -> "65535" | U32 -> "4294967295" | U64 -> "18446744073709551615"
  | I8 -> "127" | I16 -> "32767" | I32 -> "2147483647" | I64 -> "9223372036854775807"
  | _ -> invalid_arg "unsigned_limit"
let signed_min_magnitude = function
  | I8 -> "128" | I16 -> "32768" | I32 -> "2147483648" | I64 -> "9223372036854775808"
  | _ -> invalid_arg "signed_min_magnitude"
let parse_u64_bits digits =
  String.fold_left(fun n c->Int64.add(Int64.mul n 10L)(Int64.of_int(Char.code c-48)))0L digits
let checked_integer_literal span typ ~negative digits =
  let typ=canonical typ in
  if not(T.is_integer typ) then invalid span("integer literal cannot have type "^string_of_typ typ);
  if negative then begin
    if not(T.is_signed_int typ) then invalid span("negative literal is outside "^string_of_typ typ^" range");
    if decimal_compare digits (signed_min_magnitude typ)>0 then invalid span("integer literal is outside "^string_of_typ typ^" range");
    Int64.neg(parse_u64_bits digits)
  end else begin
    if decimal_compare digits (unsigned_limit typ)>0 then invalid span("integer literal is outside "^string_of_typ typ^" range");
    parse_u64_bits digits
  end
let rounded_float span typ value = match canonical typ with
  | F64 -> value
  | F32 -> let x=Int32.float_of_bits(Int32.bits_of_float value) in
      if classify_float x=FP_infinite && classify_float value<>FP_infinite then invalid span "float literal is outside F32 range";x
  | t -> invalid span("float literal cannot have type "^string_of_typ t)

let normalize_modes modes = List.filter (fun mode -> List.mem mode modes) [Explc; Jit; Bb]
let union_modes a b = normalize_modes (a @ b)

let check_internal ~entry (program : Ast.program) =
 try
  Hashtbl.clear layout_table;
  let declarations=Hashtbl.create 16 in
  let builtin_types=["Int";"Float";"I8";"U8";"I16";"U16";"I32";"U32";"I64";"U64";"F32";"F64";"Bool";"String";"File";"Vec";"Slice";"Ptr";"Unit"] in
  List.iter(fun(d:struct_decl)->
    if List.mem d.struct_name builtin_types then invalid d.struct_span("builtin type name '"^d.struct_name^"' is reserved");
    if Hashtbl.mem declarations d.struct_name then invalid d.struct_span("duplicate struct '"^d.struct_name^"'");
    if d.fields=[] then invalid d.struct_span "struct must declare at least one field";
    let names=Hashtbl.create 8 in List.iter(fun f->if Hashtbl.mem names f.field_name then invalid f.field_span("duplicate field '"^f.field_name^"'") else Hashtbl.add names f.field_name ())d.fields;
    Hashtbl.add declarations d.struct_name d)program.structs;
  let visiting=Hashtbl.create 16 in
  let rec reject_unresolved_field_type span = function
    | (Apply _|Type_var _) as typ->invalid span("unresolved struct field type "^string_of_typ typ)
    | Box t|Vec t|Slice t|Ptr t|Ref(_,t)->reject_unresolved_field_type span t
    | Tuple ts->List.iter(reject_unresolved_field_type span)ts
    | Function(ts,result)->List.iter(reject_unresolved_field_type span)(result::ts)
    | _->() in
  let rec resolve name span = match Hashtbl.find_opt layout_table name with Some x->x|None->
    if Hashtbl.mem visiting name then invalid span("recursive value layout involving '"^name^"'");
    let d=match Hashtbl.find_opt declarations name with Some d->d|None->invalid span("unknown type '"^name^"'") in
    Hashtbl.add visiting name ();
    let offset=ref 0 and max_alignment=ref 1 and has_managed=ref false in
    let fields=List.map(fun f->
      let typ=canonical f.field_type in
      reject_unresolved_field_type f.field_span typ;
      let desc=match typ with
      | Unit when String.length f.field_name >= 10 && String.sub f.field_name 0 10 = "__payload_"->T.describe Unit
      | Ref _|Unit -> invalid f.field_span("unsupported struct field type "^string_of_typ typ)
      (* Vec has a fixed representation, so its element layout is resolved by
         the declaration pass instead of being chased while the owner layout
         is active.  This also handles A -> Vec<B> -> A without mistaking the
         final value edge for an unbounded layout cycle. *)
      | Box _ -> T.describe (Box I64)
      | Vec _ -> T.describe (Vec I64)
      | Slice t -> resolve_nested f.field_span t;T.describe (Slice I64)
      | Ptr t -> resolve_nested f.field_span t;T.describe (Ptr I64)
      | Named n->let l=resolve n f.field_span in { (T.describe Unit) with size=l.size;alignment=l.alignment;trivial_copy=not l.managed;drop=(if l.managed then T.Drop_struct else T.No_drop) }
      | _->T.describe typ in
      let here=T.align_up !offset desc.alignment in offset:=here+desc.size;max_alignment:=max !max_alignment desc.alignment;
      has_managed:=!has_managed || desc.drop<>T.No_drop;
      {Ir.name=f.field_name;typ;offset=here;owner_size=0})d.fields in
    let size=T.align_up !offset !max_alignment in
    let layout = { Ir.name; fields; size; alignment = !max_alignment; managed = !has_managed } in
    let layout={layout with fields=List.map(fun f->{f with Ir.owner_size=layout.size})layout.fields} in
    Hashtbl.remove visiting name;Hashtbl.add layout_table name layout;layout
  and resolve_nested span = function
    | Named n when Hashtbl.mem visiting n -> ()
    | Named n -> ignore(resolve n span)
    | Box t|Vec t|Slice t|Ptr t|Ref(_,t) -> resolve_nested span t
    | Apply(_,types)|Tuple types -> List.iter(resolve_nested span)types
    | Function(params,result) -> List.iter(resolve_nested span)(result::params)
    | _ -> ()
  in
  List.iter(fun(d:struct_decl)->ignore(resolve d.struct_name d.struct_span))program.structs;
  let rec validate_type span = function
    | Named n when not(Hashtbl.mem layout_table n)->invalid span("unknown type '"^n^"'")
    | Box t->validate_type span t;
        if contains_slice t || contains_ptr t || (match t with Ref _->true|_->false)then
          invalid span ("unsupported Box element type "^string_of_typ t)
    | Vec t->validate_type span t;if contains_slice t then invalid span("unsupported Vec element type "^string_of_typ t);(match t with Ref _|Ptr _|Type_var _->invalid span("unsupported Vec element type "^string_of_typ t)|_->())
    | Slice t->validate_type span t;(match t with Ref _|Slice _|Ptr _|Type_var _->invalid span("unsupported Slice element type "^string_of_typ t)|_->())
    | Ptr t->validate_type span t;if not(raw_safe(canonical t))then invalid span("Ptr element type "^string_of_typ t^" is not raw-safe POD")
    | Ref(_,t)->validate_type span t
    | Function(xs,r)->List.iter(validate_type span)xs;validate_type span r
    | _->() in
  List.iter(fun(d:struct_decl)->List.iter(fun field->validate_type field.field_span
    (canonical field.field_type))d.fields)program.structs;
  if List.mem Jit program.global_mode_set then
    invalid {file="<program>";line=1;column=1}
      "global jit mode is not supported; use #scope[jit] for experimental scalar JIT";
  let signatures = Hashtbl.create 16 in
  let conversions=["i8";"u8";"i16";"u16";"i32";"u32";"i64";"u64";"f32";"f64"] in
  let builtins = conversions @ ["print";"println";"len";"arg";"arg_count";"assert";"assert_msg";"panic";"float";"int";"int_to_str";"zeros";"repeat";"read_text";"read_ints";"read_floats";"open_read";"open_write";"raw_alloc_int";"raw_load_int";"raw_store_int";"raw_free_int";"raw_alloc";"raw_load";"raw_store";"raw_free";"ptr_addr";"syscall0";"syscall1";"syscall2";"syscall3";"syscall4";"syscall5";"syscall6"] in
  List.iter (fun (f:func) ->
    List.iter(fun(p:param)->validate_type p.span p.typ)f.params;validate_type f.span f.return_type;
    let effective_modes = union_modes program.global_mode_set f.mode_set in
    if List.mem f.name builtins then invalid f.span ("builtin name '"^f.name^"' is reserved");
    if Hashtbl.mem signatures f.name then invalid f.span ("duplicate function '"^f.name^"'");
    if List.mem Jit effective_modes then invalid f.span "function-level jit mode is not supported; use #scope[jit] for experimental scalar JIT";
    if List.length f.params > 6 then invalid f.span "functions support at most six parameters";
    let explc = List.mem Explc effective_modes in
    let bb = List.mem Bb effective_modes in
    if (List.exists (fun (p:param) -> contains_ptr p.typ) f.params || contains_ptr f.return_type) && not bb
    then invalid f.span "Ptr<Int> in a function signature requires #![bb]";
    let is_method=String.starts_with ~prefix:"__method$" f.name in
    let explicit_params=if is_method then List.tl f.params else f.params in
    if (List.exists (fun (p:param) -> match p.typ with Ref _ -> true | _ -> false) explicit_params) && not explc
    then invalid f.span "reference parameters require #![explc]";
    (match f.return_type with Ref _ -> invalid f.span "references cannot be returned" | t when contains_slice t->invalid f.span "Slice values cannot be returned" | _ -> ());
    Hashtbl.add signatures f.name {params=List.map (fun (p:param)->canonical p.typ) f.params;result=canonical f.return_type;span=f.span}) program.functions;
  if not (Hashtbl.mem signatures entry) then invalid {file="<program>";line=1;column=1} "program requires fn main()";
  let main=Hashtbl.find signatures entry in
  if main.params<>[] || main.result<>Unit then invalid main.span "main must have type fn main() -> Unit";

  let copy_env = Hashtbl.copy in
  let current_module = ref None in
  let local_call_name env name =
    if Hashtbl.mem env name then Some name else
      let short=match String.rindex_opt name '.'with Some i->String.sub name(i+1)(String.length name-i-1)|None->name in
      match !current_module with Some m when name=m^"."^short && Hashtbl.mem env short->Some short|_->None in
  let current_try_return = ref Unit in
  let current_loop = ref false in
  let capability_boundary=ref {file="<program>";line=1;column=1}in
  let capability_error span mode message =
    invalid ~notes:[!capability_boundary,"enclosing function or scope does not provide "^string_of_mode mode]
      ~help:("add "^string_of_mode mode^" only to the function or #scope that needs this operation") span message in
  let unique = ref 0 in
  let fresh_binding name = incr unique; Printf.sprintf "%s$%d" name !unique in
  let rec expression ~explc ~bb ?mode_set ?expected ?(transfer=Ir.Clone) env (v:expr) : Ir.expr =
    let mode_set = match mode_set with Some modes -> modes | None -> normalize_modes
      ((if explc then [Explc] else []) @ if bb then [Bb] else []) in
    let recur=expression in
    let expression ~explc ~bb ?mode_set:override ?expected ?transfer env v =
      recur ~explc ~bb ~mode_set:(Option.value ~default:mode_set override) ?expected ?transfer env v in
    let make ?(transfer=Ir.Direct) typ node =
      validate_type v.span typ;
      {Ir.node;typ;span=v.span;transfer;mode_set} in
    let args_exact name wanted args = if List.length args <> wanted then invalid v.span
      (Printf.sprintf "%s expects %d argument%s" name wanted (if wanted=1 then "" else "s")) in
    let lower_call_args args lower = List.mapi lower args in
    let box_borrow mut source (raw:Ir.expr) =
      let rec root (x:Ast.expr)=match x.node with Var n->Some n|Field(r,_)|Unary("*",r)->root r|_->None in
      (match root source with
       |Some n->(match Hashtbl.find_opt env n with
          |Some {typ=Ref(false,_);_} when mut->invalid source.span "cannot mutably borrow Box through a shared reference"
          |Some b when mut && not(b.mutable_ || (match b.typ with Ref(true,_)->true|_->false))->
              invalid source.span "mutable Box borrow requires a mutable owner"
          |Some _->()|None->invalid source.span "Box borrow requires a local owner")
       |None->invalid source.span "Box borrow requires a local owner");
      let t=match raw.typ with Box t|Ref(_,Box t)->t|_->invalid source.span "expected Box" in
      make (Ref(mut,t))(Ir.Box_borrow(mut,raw)) in
    let result:Ir.expr=match v.node with
    | Int_lit digits ->
        let typ=match Option.map canonical expected with Some t when T.is_integer t->t|_->I64 in
        make typ (Ir.Int_lit(checked_integer_literal v.span typ ~negative:false digits))
    | Float_lit x ->
        let typ=match Option.map canonical expected with Some t when T.is_float t->t|_->F64 in
        make typ (Ir.Float_lit(rounded_float v.span typ x))
    | String_lit s -> make String (Ir.String_lit s) | Bool_lit b -> make Bool (Ir.Bool_lit b)
    | Call("$box_new",args)->
        args_exact "box" 1 args;
        let t=match expected with Some(Box t)->Some t|_->None in
        let x=expression ~explc ~bb ?expected:t env(List.hd args)in
        make (Box x.typ)(Ir.Box_new x)
    | Generic_call("$box_new",[t],args)->
        args_exact "box" 1 args;let t=canonical t in validate_type v.span(Box t);
        let x=expression ~explc ~bb ~expected:t env(List.hd args)in require x.span t x.typ;
        make(Box t)(Ir.Box_new x)
    | Generic_call("$inactive_box",[t],[])->make(Box(canonical t))(Ir.Int_lit 0L)
    | Call("$unit",[])->make Unit(Ir.Int_lit 0L)
    | Intrinsic(kind,types,args)->
        if args<>[] || List.length types<>1 then
          invalid v.span (Core_modules.name kind^" expects one type argument and no value arguments");
        let typ=canonical(List.hd types) in validate_type v.span typ;
        let named n=let l=Hashtbl.find layout_table n in
          {(T.describe Unit) with size=l.size;alignment=l.alignment} in
        let descriptor=T.describe ~named typ in
        make I64(Ir.Int_lit(Int64.of_int(match kind with Size_of->descriptor.size|Align_of->descriptor.alignment)))
    | Var name when not(Hashtbl.mem env name) ->
        let wanted=if String.contains name '.' then name else match !current_module with Some m->m^"."^name|None->name in
        let candidates=Hashtbl.fold(fun n s xs->if n=wanted then(n,s)::xs else xs)signatures[] in
        (match candidates with
         | [(target,s)]->make(Function(s.params,s.result))(Ir.Function_address target)
         | _->invalid v.span("unknown local or concrete function '"^name^"'"))
    | Vec_lit values ->
        let element_expected=match expected with Some(Vec t)->Some t|_->None in
        if values=[] && element_expected=None then invalid v.span "cannot infer element type of empty vector literal";
        let values=List.map(expression ~explc ~bb ?expected:element_expected env)values in
        let element=match element_expected,values with Some t,_->t|None,x::_->x.typ|_->assert false in
        (match element with Ref _|Slice _|Ptr _|Type_var _->invalid v.span("unsupported vector element type "^string_of_typ element)|_->());
        List.iter(fun(x:Ir.expr)->require x.span element x.typ)values;make(Vec element)(Ir.Vec_lit values)
    | Struct_lit(name,values)->
        let layout=match Hashtbl.find_opt layout_table name with Some l->l|None->invalid v.span("unknown struct '"^name^"'") in
        if List.exists (fun (f:Ir.struct_field) -> contains_ptr f.typ) layout.fields && not bb then
          invalid v.span "constructing a struct with Ptr fields requires #![bb]";
        let given=Hashtbl.create 8 in List.iter(fun(n,_,sp)->if Hashtbl.mem given n then invalid sp("duplicate literal field '"^n^"'") else Hashtbl.add given n ())values;
        List.iter(fun(n,_,sp)->if not(List.exists(fun(f:Ir.struct_field)->f.name=n)layout.fields)then invalid sp("unknown field '"^n^"' for "^name))values;
        let ordered=List.map(fun(f:Ir.struct_field)->match List.find_opt(fun(n,_,_)->n=f.name)values with
          |None->invalid v.span("missing field '"^f.name^"' for "^name)
          |Some(_,x,_)->let x=expression ~explc ~bb ~expected:f.typ ~transfer:(if move_only f.typ then Ir.Move else Ir.Clone)env x in require x.span f.typ x.typ;f,x)layout.fields in
        make(Named name)(Ir.Struct_lit(layout,ordered))
    | Field(receiver,name)->
        let receiver=expression ~explc ~bb ~transfer:Ir.Direct env receiver in
        let receiver=match receiver.typ with Ref(_,Named _)->make(match receiver.typ with Ref(_,t)->t|_->assert false)(Ir.Deref receiver)|_->receiver in
        (match receiver.typ with Named n->let layout=Hashtbl.find layout_table n in
          let field=match List.find_opt(fun(f:Ir.struct_field)->f.name=name)layout.fields with Some f->f|None->invalid v.span("unknown field '"^name^"' for "^n) in
          if contains_ptr field.typ && not bb then invalid v.span "accessing a Ptr field requires #![bb]";
          let rec through_reference (r:Ir.expr)=match r.node with
            |Ir.Deref _->true|Ir.Field(r,_)->through_reference r|_->false in
          let field_transfer=if move_only field.typ && transfer<>Ir.Direct then Ir.Move
            else if managed field.typ then
              (if through_reference receiver && transfer<>Ir.Direct then Ir.Clone
               else if transfer=Ir.Move then Ir.Move else if transfer=Ir.Direct then Ir.Direct else Ir.Clone)
            else if transfer=Ir.Direct then Ir.Direct else Ir.Copy in
          make ~transfer:field_transfer field.typ (Ir.Field(receiver,field))
        |_->invalid receiver.span "field access expects a struct")
    | Try value->
        let value=expression ~explc ~bb ~transfer:Ir.Move env value in
        let result_layout typ label=match typ with
          |Named n when String.length n >= 6 && String.sub n 0 6 = "Result"->
              let layout=Hashtbl.find layout_table n in
              let field name=match List.find_opt(fun(f:Ir.struct_field)->f.name=name)layout.fields with
                |Some f->f|None->invalid v.span("malformed "^label^" Result layout") in
              layout,field "__payload_Ok",field "__payload_Err"
          |_->invalid v.span(label^" must be Result<T,E>") in
        let input,ok_field,err_field=result_layout value.typ "? operand" in
        let output,out_ok,out_err=result_layout !current_try_return "current function return type" in
        require v.span err_field.typ out_err.typ;
        make ~transfer ok_field.typ(Ir.Try(value,input,ok_field,err_field,output,out_ok,out_err))
    | Var name -> (match Hashtbl.find_opt env name with
        | None->invalid v.span("unknown local '"^name^"'")
        | Some b->let tr=if move_only b.typ && transfer<>Ir.Direct then Ir.Move else if managed b.typ then transfer
            else if transfer=Ir.Direct then Ir.Direct else Ir.Copy in
          make ~transfer:tr b.typ(Ir.Var b.ir_name))
    | Borrow (mutable_, target) ->
        if not explc then capability_error v.span Explc "references require #![explc]";
        (match target.node with
         | Var name -> (match Hashtbl.find_opt env name with
             | None->invalid target.span("unknown local '"^name^"'")
             | Some b when not(referable b.typ)->invalid target.span("cannot reference "^string_of_typ b.typ)
             | Some b when mutable_ && not b.mutable_->invalid target.span "mutable borrow requires a mutable local"
             | Some b->               make(Ref(mutable_,b.typ))(Ir.Address b.ir_name))
         | Unary("*",reference)->
             let reference=expression ~explc ~bb ~transfer:Ir.Direct env reference in
             (match reference.typ with
              |Box _->box_borrow mutable_ (match target.node with Unary(_,x)->x|_->assert false) reference
              |Ref(_,t)->if mutable_ then invalid target.span "mutable reborrow is not supported";
                  make(Ref(false,t))(Ir.Shared_reborrow reference)
              |_->invalid target.span "reborrow expects a reference")
         | _->invalid target.span "borrow target must be a local variable")
    | Unary ("*",r) ->
        let r=expression ~explc ~bb ~transfer:Ir.Direct env r in
        let r=match r.typ with Box _->box_borrow false (match v.node with Unary(_,x)->x|_->assert false) r|_->r in
        (match r.typ with Ref(_,t) when move_only t && transfer<>Ir.Direct->
             invalid r.span("cannot move "^string_of_typ t^" through a reference")
         | Ref(_,t)->make ~transfer:(if managed t && transfer<>Ir.Direct then Ir.Clone else if transfer<>Ir.Direct then Ir.Copy else Ir.Direct)t(Ir.Deref r)
         | _->invalid r.span "dereference expects a reference")
    | Unary("-",({node=Int_lit digits;_} as x))->
        let typ=match Option.map canonical expected with Some t when T.is_integer t->t|_->I64 in
        make typ(Ir.Int_lit(checked_integer_literal x.span typ ~negative:true digits))
    | Unary(op,x)->let x=expression ~explc ~bb ?expected env x in (match op with
        | "-" when T.is_signed_int x.typ||T.is_float x.typ->make x.typ(Ir.Unary(op,x))
        | "!"->require x.span Bool x.typ;make Bool(Ir.Unary(op,x))
        | "-"->invalid x.span "unary - expects a signed integer or float"|_->invalid v.span("unknown unary operator '"^op^"'"))
    | Binary(op,a,b)->let operand_expected=match expected with Some t when T.is_numeric(canonical t)&&List.mem op["+";"-";"*";"/";"%"]->Some(canonical t)|_->None in
        let a=expression ~explc ~bb ?expected:operand_expected ~transfer:Ir.Direct env a in let b=expression ~explc ~bb ~expected:a.typ ~transfer:Ir.Direct env b in
        if (match a.typ with Ref _->true|_->false) then invalid a.span "reference equality and arithmetic are not supported";
        if a.typ=File then invalid a.span "File equality and arithmetic are not supported";
        if (match a.typ with Function _->true|_->false) then invalid a.span "function values do not support equality or arithmetic";
        (match a.typ with Vec t when not(equality_capable t)->invalid a.span ("Vec equality is not supported for element type "^string_of_typ t)|_->());
        if contains_ptr a.typ then invalid a.span "Ptr<Int> equality and arithmetic are not supported";
        if (match a.typ with Named _->true|_->false) then invalid a.span "struct equality and arithmetic are not supported";
        let typ=match op with
        | "+" when a.typ=String->require b.span String b.typ;String
        | "+"|"-"|"*"|"/"->if not(T.is_numeric a.typ) then invalid a.span "arithmetic expects a numeric type";require b.span a.typ b.typ;a.typ
        | "%"->if not(T.is_integer a.typ)then invalid a.span "expected Int integer operand";require b.span a.typ b.typ;a.typ
        | "<"|"<="|">"|">="->if not(T.is_numeric a.typ) then invalid a.span "comparison expects a numeric type";require b.span a.typ b.typ;Bool
        | "=="|"!="->require b.span a.typ b.typ;Bool
        | "&&"|"||"->require a.span Bool a.typ;require b.span Bool b.typ;Bool|_->invalid v.span("unknown binary operator '"^op^"'") in make typ(Ir.Binary(op,a,b))
    | Index(receiver,index)->
        let receiver=expression ~explc ~bb ~transfer:Ir.Direct env receiver in
        let receiver=match receiver.typ with Ref(_,Vec _)->make (match receiver.typ with Ref(_,t)->t|_->assert false)(Ir.Deref receiver)|_->receiver in
        let index=expression ~explc ~bb ~expected:I64 env index in require index.span I64 index.typ;
        (match receiver.typ with
         | Vec t->if move_only t then invalid v.span("cannot read move-only "^string_of_typ t^" from Vec by index");make t(Ir.Index(receiver,index))
         | Slice t->if move_only t then invalid v.span("cannot read move-only "^string_of_typ t^" from Slice by index");make t(Ir.Slice_get(receiver,index))
         |_->invalid receiver.span "indexing expects Vec or Slice")
    | Method(receiver,name,args)->
        let raw=expression ~explc ~bb ~transfer:Ir.Direct env receiver in
        (match raw.typ with Named owner when
          (match List.find_opt(fun(f:Ir.struct_field)->f.name=name)(Hashtbl.find layout_table owner).fields with
           |Some {typ=Function _;_}->true|_->false) ->
          let field=List.find(fun(f:Ir.struct_field)->f.name=name)(Hashtbl.find layout_table owner).fields in
          (match field.typ with Function(params,result)->
            if List.length args<>List.length params then invalid v.span(Printf.sprintf "function field expects %d arguments" (List.length params));
            if List.exists(function Ref _->true|_->false)params && not explc then invalid v.span "passing references requires #![explc]";
            if (List.exists contains_ptr params || contains_ptr result) && not bb then invalid v.span "passing or receiving Ptr requires #![bb]";
            let callee=make field.typ(Ir.Field(raw,field)) in
            let args=lower_call_args args(fun i x->let t=List.nth params i in
              expression ~explc ~bb ~expected:t ~transfer:(if move_only t then Ir.Move else Ir.Clone)env x) in
            List.iter2(fun(x:Ir.expr)t->require x.span t x.typ)args params;make result(Ir.Indirect_call(callee,args))
           |_->assert false)
        | Box t | Ref(_,Box t) ->
          args_exact name 0 args;
          (match name with
           | "as_ref"->box_borrow false receiver raw
           | "as_mut"->box_borrow true receiver raw
           | "into_inner"->(match raw.typ with Ref _->invalid receiver.span "into_inner requires an owned Box"|_->());
               let x=expression ~explc ~bb ~transfer:Ir.Move env receiver in make t(Ir.Box_take x)
           |_->invalid v.span("unknown Box method '"^name^"'"))
        | String ->
          (match name with
           | "len"->args_exact name 0 args;make I64(Ir.Call("len",[raw]))
           | "as_bytes"->args_exact name 0 args;(match receiver.node with Var _->()|_->invalid receiver.span "String byte view source must be a local");
               let zero=make I64(Ir.Int_lit 0L)in make(Slice U8)(Ir.Slice_make(raw,zero,make I64(Ir.Call("len",[raw]))))
           | _->invalid v.span("unknown String method '"^name^"'"))
        | File | Ref(_,File) ->
          let mutable_target () = match receiver.node, raw.typ with
            | Var _, Ref(true,File) -> raw
            | Var n, File -> (match Hashtbl.find_opt env n with
                | Some b when b.mutable_ ->  make (Ref(true,File)) (Ir.Address b.ir_name)
                | _ -> invalid receiver.span "mutating File method requires a mutable local")
            | _, Ref(false,File) -> invalid receiver.span "mutating File method requires &mut File"
            | _ -> invalid receiver.span "mutating File method requires a mutable File or &mut File receiver" in
          let shared_target () = match raw.typ with
            | File -> (match receiver.node with Var n -> let b=Hashtbl.find env n in make (Ref(false,File)) (Ir.Address b.ir_name) | _ -> invalid receiver.span "File method receiver must be a local")
            | Ref(_,File) -> raw | _ -> assert false in
          (match name with
           | "read" -> args_exact name 0 args; make String (Ir.File_read (mutable_target ()))
           | "write" -> args_exact name 1 args; let value=expression ~explc ~bb ~expected:String ~transfer:Ir.Direct env (List.hd args) in make Unit (Ir.File_write(mutable_target (),value))
           | "close" -> args_exact name 0 args; make Unit (Ir.File_close (mutable_target ()))
           | "is_open" -> args_exact name 0 args; make Bool (Ir.File_is_open (shared_target ()))
           | _ -> invalid v.span ("unknown File method '"^name^"'"))
        | Slice element ->
          (match name with
           | "len"->args_exact name 0 args;make I64(Ir.Slice_len raw)
           | "get"->args_exact name 1 args;if move_only element then invalid v.span("cannot get move-only "^string_of_typ element^" from Slice");let i=expression ~explc ~bb ~expected:I64 env(List.hd args)in require i.span I64 i.typ;make element(Ir.Slice_get(raw,i))
           | _->invalid v.span("unknown Slice method '"^name^"'"))
        | Ptr _ ->
          (match name with
           | "$bounds_len"->args_exact name 0 args;make I64(Ir.Ptr_len raw)
           | _->invalid v.span("unknown Ptr method '"^name^"'"))
        | _ ->
        let r=match raw.typ with Ref(_,Vec _)->make (match raw.typ with Ref(_,t)->t|_->assert false)(Ir.Deref raw)|_->raw in
        let element=match r.typ with Vec t->t|_->invalid receiver.span "method receiver must be Vec or File" in
        let mutable_target()=match receiver.node,raw.typ with
          | Var _,Ref(true,Vec _)->raw
          | Var n,Vec _->(match Hashtbl.find_opt env n with Some b when b.mutable_->make (Ref(true,b.typ))(Ir.Address b.ir_name)|_->invalid receiver.span "mutating vector method requires a mutable local")
          | Field _,Vec _->
              let rec mutable_root (value:Ast.expr) = match value.node with
                | Var n->Some n | Field(owner,_)->mutable_root owner | _->None in
              (match mutable_root receiver,raw.node with
               | Some n,Ir.Field(owner,field)->
                   (match Hashtbl.find_opt env n with
                    | Some {typ=Named _;mutable_=true;_}
                    | Some {typ=Ref(true,Named _);_}->

                        make (Ref(true,raw.typ))(Ir.Field_address(owner,field))
                    | _->invalid receiver.span "mutating vector method requires a field of a mutable local")
               | _->invalid receiver.span "mutating vector method requires a mutable Vec or &mut Vec receiver")
          | _->invalid receiver.span "mutating vector method requires a mutable Vec or &mut Vec receiver" in
        (match name with
        | "len"->args_exact name 0 args;make I64(Ir.Vec_len r)
        | "get"->args_exact name 1 args;if move_only element then invalid v.span("cannot get move-only "^string_of_typ element^" from Vec");let i=expression ~explc ~bb ~expected:I64 env(List.hd args)in require i.span I64 i.typ;make element(Ir.Vec_get(r,i))
        | "set"->args_exact name 2 args;let target=mutable_target() in
              let i=expression ~explc ~bb ~expected:I64 env(List.nth args 0)in
              let x=expression ~explc ~bb ~expected:element ~transfer:(if move_only element then Ir.Move else Ir.Clone) env(List.nth args 1)in
              require i.span I64 i.typ;require x.span element x.typ;make Unit(Ir.Vec_set(target,i,x))
        | "push"->args_exact name 1 args;let target=mutable_target()in
              let x=expression ~explc ~bb ~expected:element ~transfer:(if move_only element then Ir.Move else Ir.Clone)env(List.hd args)in
              require x.span element x.typ;make Unit(Ir.Vec_push(target,x))
        | "pop"->args_exact name 0 args;make element(Ir.Vec_pop(mutable_target()))
        | "into_string"->args_exact name 0 args;if element<>U8 then invalid v.span "into_string requires Vec<U8>";
            let moved=expression ~explc ~bb ~expected:(Vec U8) ~transfer:Ir.Move env receiver in make String(Ir.Call("$vec_into_string",[moved]))
        | "as_slice"->args_exact name 0 args;(match receiver.node with Var _->()|_->invalid receiver.span "Slice source must be a local Vec");let zero=make I64(Ir.Int_lit 0L)in make(Slice element)(Ir.Slice_make(r,zero,make I64(Ir.Vec_len r)))
        | "slice"->args_exact name 2 args;(match receiver.node with Var _->()|_->invalid receiver.span "Slice source must be a local Vec");let a=expression ~explc ~bb ~expected:I64 env(List.nth args 0)and b=expression ~explc ~bb ~expected:I64 env(List.nth args 1)in require a.span I64 a.typ;require b.span I64 b.typ;make(Slice element)(Ir.Slice_make(r,a,b))
        | _->invalid v.span("unknown Vec method '"^name^"'")))
    | Generic_call(("raw_alloc" as n),[t],args)->if not bb then capability_error v.span Bb (n^" requires #![bb]");let t=canonical t in if not(raw_safe t)then invalid v.span("raw memory element type "^string_of_typ t^" is not raw-safe POD");args_exact n 1 args;let c=expression ~explc ~bb ~expected:I64 env(List.hd args)in require c.span I64 c.typ;make(Ptr t)(Ir.Raw_alloc(t,c))
    | Generic_call("$inactive_ptr",[t],[])->make(Ptr(canonical t))(Ir.Call("$inactive_pair",[]))
    | Generic_call("$inactive_slice",[t],[])->make(Slice(canonical t))(Ir.Call("$inactive_pair",[]))
    | Generic_call(("raw_load" as n),types,args)->if not bb then capability_error v.span Bb (n^" requires #![bb]");args_exact n 2 args;let p=expression ~explc ~bb ~transfer:Ir.Direct env(List.hd args)in let t=match p.typ with Ptr t->t|_->invalid p.span(n^" expects Ptr<T>")in (match types with []->()|[x]->require v.span t(canonical x)|_->invalid v.span(n^" expects at most one type argument"));if not(raw_safe t)then invalid v.span("raw memory element type "^string_of_typ t^" is not raw-safe POD");let i=expression ~explc ~bb ~expected:I64 env(List.nth args 1)in require i.span I64 i.typ;make t(Ir.Raw_load(t,p,i))
    | Generic_call(("raw_store" as n),types,args)->if not bb then capability_error v.span Bb (n^" requires #![bb]");args_exact n 3 args;let p=expression ~explc ~bb ~transfer:Ir.Direct env(List.hd args)in let t=match p.typ with Ptr t->t|_->invalid p.span(n^" expects Ptr<T>")in (match types with []->()|[x]->require v.span t(canonical x)|_->invalid v.span(n^" expects at most one type argument"));if not(raw_safe t)then invalid v.span("raw memory element type "^string_of_typ t^" is not raw-safe POD");let i=expression ~explc ~bb ~expected:I64 env(List.nth args 1)and x=expression ~explc ~bb ~expected:t env(List.nth args 2)in require i.span I64 i.typ;require x.span t x.typ;make Unit(Ir.Raw_store(t,p,i,x))
    | Generic_call(("raw_free" as n),types,args)->if not bb then capability_error v.span Bb (n^" requires #![bb]");args_exact n 1 args;let p=expression ~explc ~bb ~transfer:Ir.Direct env(List.hd args)in let t=match p.typ with Ptr t->t|_->invalid p.span(n^" expects Ptr<T>")in (match types with []->()|[x]->require v.span t(canonical x)|_->invalid v.span(n^" expects at most one type argument"));make Unit(Ir.Raw_free(t,p))
    | Generic_call(("ptr_addr" as n),types,args)->if not bb then capability_error v.span Bb (n^" requires #![bb]");args_exact n 1 args;let p=expression ~explc ~bb ~transfer:Ir.Direct env(List.hd args)in let t=match p.typ with Ptr t->t|_->invalid p.span(n^" expects Ptr<T>")in (match types with []->()|[x]->require v.span t(canonical x)|_->invalid v.span(n^" expects at most one type argument"));make I64(Ir.Ptr_addr(t,p))
    | Call(("raw_alloc" as n),_)->invalid v.span(n^" requires an explicit type argument")
    | Call(("raw_load"|"raw_store"|"raw_free"|"ptr_addr" as n),args)->expression ~explc ~bb env {v with node=Generic_call(n,[],args)}
    | Call(("syscall0"|"syscall1"|"syscall2"|"syscall3"|"syscall4"|"syscall5"|"syscall6" as n),args)->if not bb then capability_error v.span Bb (n^" requires #![bb]");let arity=Char.code n.[7]-Char.code '0' in args_exact n(arity+1)args;let xs=List.map(fun x->let x=expression ~explc ~bb ~expected:I64 env x in require x.span I64 x.typ;x)args in make I64(Ir.Syscall xs)
    | Call(("raw_alloc_int" as n),args)->if not bb then capability_error v.span Bb (n^" requires #![bb]");args_exact n 1 args;let count=expression ~explc ~bb ~expected:I64 env(List.hd args)in require count.span I64 count.typ;make(Ptr I64)(Ir.Raw_alloc(I64,count))
    | Call(("raw_load_int" as n),args)->if not bb then capability_error v.span Bb (n^" requires #![bb]");args_exact n 2 args;let p=expression ~explc ~bb ~expected:(Ptr I64) env(List.nth args 0)and i=expression ~explc ~bb ~expected:I64 env(List.nth args 1)in require p.span (Ptr I64) p.typ;require i.span I64 i.typ;make I64(Ir.Raw_load(I64,p,i))
    | Call(("raw_store_int" as n),args)->if not bb then capability_error v.span Bb (n^" requires #![bb]");args_exact n 3 args;let p=expression ~explc ~bb ~expected:(Ptr I64) env(List.nth args 0)and i=expression ~explc ~bb ~expected:I64 env(List.nth args 1)and x=expression ~explc ~bb ~expected:I64 env(List.nth args 2)in require p.span (Ptr I64) p.typ;require i.span I64 i.typ;require x.span I64 x.typ;make Unit(Ir.Raw_store(I64,p,i,x))
    | Call(("raw_free_int" as n),args)->if not bb then capability_error v.span Bb (n^" requires #![bb]");args_exact n 1 args;let p=expression ~explc ~bb ~expected:(Ptr I64) env(List.hd args)in require p.span (Ptr I64) p.typ;make Unit(Ir.Raw_free(I64,p))
    | Call(("open_read"|"open_write" as n),args)->args_exact n 1 args;let path=expression ~explc ~bb ~expected:String ~transfer:Ir.Direct env(List.hd args)in require path.span String path.typ;make File(Ir.Call(n,[path]))
    | Call(("zeros" as n),args)->args_exact n 1 args;let count=expression ~explc ~bb ~expected:I64 env(List.hd args)in require count.span I64 count.typ;make(Vec I64)(Ir.Call(n,[count]))
    | Call(("repeat" as n),args)->args_exact n 2 args;let value=expression ~explc ~bb ~transfer:Ir.Direct env(List.nth args 0)in
        if value.typ<>I64&&value.typ<>F64 then invalid value.span "repeat value must be Int or Float";
        let count=expression ~explc ~bb ~expected:I64 env(List.nth args 1)in require count.span I64 count.typ;make(Vec value.typ)(Ir.Call(n,[value;count]))
    | Call(("read_text"|"read_ints"|"read_floats" as n),args)->args_exact n 1 args;let path=expression ~explc ~bb ~expected:String ~transfer:Ir.Direct env(List.hd args)in require path.span String path.typ;
        make (if n="read_text" then String else if n="read_ints" then Vec I64 else Vec F64) (Ir.Call(n,[path]))
    | Call(("print"|"println" as n),args)->args_exact n 1 args;let x=expression ~explc ~bb ~transfer:Ir.Direct env(List.hd args)in
        if not(T.is_numeric x.typ)&&x.typ<>Bool&&x.typ<>String&&(match x.typ with Vec(I64|F64)->false|_->true)then invalid x.span (n^" accepts Int/Float and all numeric scalars, Bool, String, or Vec");make Unit(Ir.Call(n,[x]))
    | Call("len",args)->args_exact"len" 1 args;let x=expression ~explc ~bb ~transfer:Ir.Direct env(List.hd args)in(match x.typ with String|Vec _->make I64(Ir.Call("len",[x]))|Slice _->make I64(Ir.Slice_len x)|Ref(_, (String|Vec _))->let d=make(match x.typ with Ref(_,t)->t|_->assert false)(Ir.Deref x)in make I64(Ir.Call("len",[d]))|_->invalid x.span "len expects String, Vec, or Slice")
    | Call("arg_count",args)->args_exact"arg_count" 0 args;make I64(Ir.Call("arg_count",[]))
    | Call("arg",args)->args_exact"arg" 1 args;let x=expression ~explc ~bb ~expected:I64 env(List.hd args)in require x.span I64 x.typ;make String(Ir.Call("arg",[x]))
    | Call(("assert"as n),args)->args_exact n 1 args;let x=expression ~explc ~bb ~expected:Bool env(List.hd args)in require x.span Bool x.typ;make Unit(Ir.Call(n,[x]))
    | Call(("assert_msg"as n),args)->args_exact n 2 args;let a=expression ~explc ~bb ~expected:Bool env(List.nth args 0)and b=expression ~explc ~bb ~expected:String ~transfer:Ir.Direct env(List.nth args 1)in require a.span Bool a.typ;require b.span String b.typ;make Unit(Ir.Call(n,[a;b]))
    | Call(("panic"as n),args)->args_exact n 1 args;let x=expression ~explc ~bb ~expected:String ~transfer:Ir.Direct env(List.hd args)in require x.span String x.typ;make Unit(Ir.Call(n,[x]))
    | Call(("float"as n),args)->args_exact n 1 args;let x=expression ~explc ~bb ~expected:I64 env(List.hd args)in require x.span I64 x.typ;make F64(Ir.Call(n,[x]))
    | Call(("int"as n),args)->args_exact n 1 args;let x=expression ~explc ~bb ~expected:F64 env(List.hd args)in require x.span F64 x.typ;make I64(Ir.Call(n,[x]))
    | Call(("i8"|"u8"|"i16"|"u16"|"i32"|"u32"|"i64"|"u64"|"f32"|"f64" as n),args)->
        args_exact n 1 args;
        let target=match n with "i8"->I8|"u8"->U8|"i16"->I16|"u16"->U16|"i32"->I32|"u32"->U32|"i64"->I64|"u64"->U64|"f32"->F32|_->F64 in
        (match (List.hd args).node with
         | Int_lit digits when T.is_integer target->ignore(checked_integer_literal (List.hd args).span target ~negative:false digits)
         | Unary("-",{node=Int_lit digits;span;_})when T.is_integer target->ignore(checked_integer_literal span target ~negative:true digits)
         | Float_lit f when T.is_integer target->
             let lo,hi=match target with I8->(-128.,128.)|U8->(0.,256.)|I16->(-32768.,32768.)|U16->(0.,65536.)
               |I32->(-2147483648.,2147483648.)|U32->(0.,4294967296.)|I64->(-9223372036854775808.,9223372036854775808.)
               |U64->(0.,18446744073709551616.)|_->assert false in
             if classify_float f=FP_nan||classify_float f=FP_infinite||f<lo||f>=hi then invalid (List.hd args).span(n^" conversion is outside target range")
         | Float_lit f when target=F32->ignore(rounded_float (List.hd args).span F32 f)
         | _->());
        let raw=List.hd args in
        let x=match raw.node with
          |Int_lit _->expression ~explc ~bb ~expected:(if T.is_integer target then target else U64) ~transfer:Ir.Direct env raw
          |Unary("-",{node=Int_lit _;_})->expression ~explc ~bb ~expected:(if T.is_signed_int target then target else I64) ~transfer:Ir.Direct env raw
          |_->expression ~explc ~bb ~transfer:Ir.Direct env raw in
        if not(T.is_numeric x.typ)then invalid x.span(n^" expects a numeric value");
        make target(Ir.Call("__convert_"^n,[x]))
    | Call(("int_to_str"as n),args)->args_exact n 1 args;let x=expression ~explc ~bb ~expected:I64 env(List.hd args)in require x.span I64 x.typ;make String(Ir.Call(n,[x]))
    | Call("$inactive_file",[])->make File(Ir.Int_lit(-1L))
    | Call("$consume",[x])->let x=expression ~explc ~bb ~transfer:Ir.Move env x in {x with transfer=Ir.Move}
    | Call(name,args) when Option.is_some(local_call_name env name)->
        if List.length args>6 then invalid v.span "calls support at most six arguments";
        let local=Option.get(local_call_name env name)in
        let b=Hashtbl.find env local in
        (match b.typ with Function(params,result)->
          if List.length args<>List.length params then invalid v.span(Printf.sprintf "function value expects %d arguments" (List.length params));
          if List.exists(function Ref _->true|_->false)params && not explc then invalid v.span "passing references requires #![explc]";
          if (List.exists contains_ptr params || contains_ptr result) && not bb then invalid v.span "passing or receiving Ptr requires #![bb]";
          let callee=make b.typ(Ir.Var b.ir_name) in
          let args=lower_call_args args(fun i x->let t=List.nth params i in
            expression ~explc ~bb ~expected:t ~transfer:(if move_only t then Ir.Move else Ir.Clone)env x) in
          List.iter2(fun(x:Ir.expr)t->require x.span t x.typ)args params;
          make result(Ir.Indirect_call(callee,args))
        |_->invalid v.span("local '"^name^"' is not callable"))
    | Call(name,args)->if List.length args>6 then invalid v.span "calls support at most six arguments";(match Hashtbl.find_opt signatures name with
        | None->invalid v.span("unknown function '"^name^"'")|Some s->if List.length args<>List.length s.params then invalid v.span(Printf.sprintf"function '%s' expects %d arguments"name(List.length s.params));
          let is_method=String.starts_with ~prefix:"__method$" name in
          if List.exists(function Ref _->true|_->false)(if is_method then List.tl s.params else s.params) && not explc then capability_error v.span Explc "passing references requires #![explc]";
          if (List.exists contains_ptr s.params || contains_ptr s.result) && not bb then capability_error v.span Bb "passing or receiving Ptr<Int> requires #![bb]";
          let args=lower_call_args args(fun i (x:expr)->let t=List.nth s.params i in
            if is_method&&i=0 then match t,x.node with
            | Ref(m,target),Var n->(match Hashtbl.find_opt env n with
                | Some b when b.typ=target && (not m || b.mutable_)->make t(Ir.Address b.ir_name)
                | Some b when b.typ=target->invalid x.span "mutable method receiver requires a mutable local"
                | _->let value=expression ~explc ~bb ~expected:t ~transfer:Ir.Direct env x in require x.span t value.typ;value)
            | Ref(m,target),Field(owner,field_name)->
                let owner=expression ~explc ~bb ~transfer:Ir.Direct env owner in
                (match owner.typ with
                 | Ref(owner_mut,Named n) when not m || owner_mut->
                     let field=match List.find_opt(fun(f:Ir.struct_field)->f.name=field_name)(Hashtbl.find layout_table n).fields with
                       |Some f->f|None->invalid x.span("unknown field '"^field_name^"' for "^n) in
                     require x.span target field.typ;make t(Ir.Field_address(owner,field))
                 | Ref(false,Named _)->invalid x.span "mutable method receiver requires a mutable field"
                 | _->invalid x.span "method field receiver requires a referenced struct")
            | _->let value=expression ~explc ~bb ~expected:t ~transfer:(if move_only t then Ir.Move else Ir.Clone) env x in require x.span t value.typ;value
            else expression ~explc ~bb ~expected:t ~transfer:(if move_only t then Ir.Move else Ir.Clone) env x) in
          List.iter2(fun(x:Ir.expr)t->require x.span t x.typ)args s.params;make s.result(Ir.Call(name,args)))
    | If_expr(condition,yes,no)->
        let condition=expression ~explc ~bb ~mode_set ~expected:Bool env condition in require condition.span Bool condition.typ;
        let yes_env=copy_env env and no_env=copy_env env in
        let acquisition=if transfer=Ir.Direct then Ir.Clone else transfer in
        let yes=expression ~explc ~bb ~mode_set ?expected ~transfer:acquisition yes_env yes in
        let no=expression ~explc ~bb ~mode_set ~expected:yes.typ ~transfer:acquisition no_env no in require no.span yes.typ no.typ;
        make ~transfer yes.typ(Ir.If_expr(condition,yes,no))
    | Match_control(scr_name,result_type,scrutinee,arms)->
        let enclosing_loop= !current_loop in
        let scrutinee=expression ~explc ~bb ~mode_set env scrutinee in
        let scr_name_ir=fresh_binding scr_name in
        let match_env=copy_env env in
        Hashtbl.add match_env scr_name {typ=scrutinee.typ;mutable_=false;ir_name=scr_name_ir};
        let arms=List.map(fun(pattern,condition,body,tail)->
          let arm_env=copy_env match_env in
          let condition=expression ~explc ~bb ~mode_set ~expected:Bool arm_env condition in
          let body,ends=statements arm_env !current_try_return mode_set enclosing_loop body in
          current_loop:=enclosing_loop;
          let acquisition=if transfer=Ir.Direct then Ir.Clone else transfer in
          let tail=if ends then None else Option.map(expression ~explc ~bb ~mode_set ~expected:result_type ~transfer:acquisition arm_env)tail in
          if not ends then require v.span result_type (match tail with None->Unit|Some x->x.typ);
          pattern,condition,body,tail)arms in
        current_loop:=enclosing_loop;
        make ~transfer result_type(Ir.Match_control(scr_name_ir,scrutinee,arms))
    | Generic_call _ | Generic_struct_lit _ | Tuple_lit _ | Tuple_index _ | Variant_lit _ | Match _ ->
        invalid v.span "generic, tuple, enum, or match expression is not lowered yet" in
    (* A contextual shared reference is a child loan, never a type-only cast
       of the parent's mutable authority. Implicit receivers keep their gate. *)
    match Option.map canonical expected,result.typ with
    |Some(Ref(false,t)),Ref(true,u) when t=u->make(Ref(false,t))(Ir.Shared_reborrow result)
    |_->result


  and statements ?(initial=[]) ?boundary env return_type mode_set in_loop values =
    let previous_boundary= !capability_boundary in
    Option.iter(fun span->capability_boundary:=span)boundary;
    let explc=List.mem Explc mode_set and bb=List.mem Bb mode_set in
    let expression ~explc ~bb ?mode_set:override ?expected ?transfer env v =
      expression ~explc ~bb ~mode_set:(Option.value ~default:mode_set override) ?expected ?transfer env v in
    let declared=Hashtbl.create 16 in List.iter(fun n->Hashtbl.add declared n ())initial;
    let rec go terminated out=function
      | []->List.rev out,terminated
      | (s:stmt)::rest->if terminated then invalid s.span "unreachable statement";
        current_loop := in_loop;
        let make node={Ir.node;span=s.span} in
        let lowered,ends=match s.node with
        | Let(mut,n,annotation,x)->if Hashtbl.mem declared n then invalid s.span("duplicate local '"^n^"'");let annotation=Option.map canonical annotation in let transfer=match annotation with Some t when move_only t->Ir.Move|_->Ir.Clone in let x=expression ~explc ~bb ?expected:annotation ~transfer env x in Option.iter(fun t->require x.span t x.typ)annotation;
          if contains_ptr x.typ && not bb then capability_error x.span Bb "Ptr<Int> bindings require #![bb]";
          (match x.typ with Ref _ when not explc->capability_error x.span Explc "reference bindings require #![explc]"|_->());
          let ir_name=fresh_binding n in
          Hashtbl.add declared n ();Hashtbl.replace env n {typ=x.typ;mutable_=mut;ir_name};
          make(Ir.Let(ir_name,x)),false
        | Let_pattern(mut,p,annotation,x)->
          let annotation=Option.map canonical annotation in
          let x=expression ~explc ~bb ?expected:annotation env x in
          Option.iter(fun t->require x.span t x.typ)annotation;
          if contains_ptr x.typ && not bb then capability_error x.span Bb "Ptr bindings require #![bb]";
          let names=Hashtbl.create 8 in
          let rec bindings typ path p=match p.pattern_node with
            |Wildcard_pattern->[]
            |Binding_pattern n->
                if Hashtbl.mem names n then invalid p.pattern_span("duplicate pattern binding '"^n^"'");
                if Hashtbl.mem declared n then invalid p.pattern_span("duplicate local '"^n^"'");
                (match typ with Ref _ when not explc->capability_error p.pattern_span Explc "reference bindings require #![explc]"|_->());
                Hashtbl.add names n ();[n,typ,path,p.pattern_span]
            |Tuple_pattern ps->
                let fs=match typ with Named n when String.starts_with ~prefix:"$Tuple<" n->(Hashtbl.find layout_table n).fields
                  |_->invalid p.pattern_span("tuple pattern cannot match "^string_of_typ typ) in
                if List.length ps<>List.length fs then invalid p.pattern_span(Printf.sprintf "tuple pattern expects %d elements"(List.length fs));
                List.concat(List.map2(fun p (f:Ir.struct_field)->bindings f.typ(path@[f])p)ps fs)
            |_->invalid p.pattern_span "let pattern supports bindings, _, and nested tuples" in
          let bindings=bindings x.typ [] p in
          let bindings=List.map(fun(n,typ,path,span)->
            let ir_name=fresh_binding n in
            Hashtbl.add declared n ();Hashtbl.replace env n {typ;mutable_=mut;ir_name};
            ir_name,path,span)bindings in
          make(Ir.Let_pattern(x,bindings)),false
        | Assign(n,x)->(match Hashtbl.find_opt env n with None->invalid s.span("unknown local '"^n^"'")|Some b when(match b.typ with Ref _->true|_->false)->invalid s.span "reference bindings cannot be reassigned"|Some b when not b.mutable_->invalid s.span("cannot assign immutable local '"^n^"'")|Some b->let self=match x.node with Var q->q=n|_->false in if self&&move_only b.typ then invalid x.span("cannot move a "^string_of_typ b.typ^" into itself");let x=expression ~explc ~bb ~expected:b.typ ~transfer:(if move_only b.typ then Ir.Move else Ir.Clone)env x in require x.span b.typ x.typ;make(Ir.Assign(b.ir_name,x)),false)
        | Field_assign(n,field_name,x)->(match Hashtbl.find_opt env n with
          |None->invalid s.span("unknown local '"^n^"'")|Some b when not b.mutable_ && (match b.typ with Ref(true,Named _)->false|_->true)->invalid s.span("cannot assign field of immutable local '"^n^"'")
          |Some b->match b.typ with Named sn->let l=Hashtbl.find layout_table sn in let f=match List.find_opt(fun(f:Ir.struct_field)->f.name=field_name)l.fields with Some f->f|None->invalid s.span("unknown field '"^field_name^"' for "^sn)in
            let x=expression ~explc ~bb ~expected:f.typ ~transfer:(if move_only f.typ then Ir.Move else Ir.Clone)env x in require x.span f.typ x.typ;
            make(Ir.Field_assign(b.ir_name,f,x)),false
          |Ref(true,Named sn)->let l=Hashtbl.find layout_table sn in let f=match List.find_opt(fun(f:Ir.struct_field)->f.name=field_name)l.fields with Some f->f|None->invalid s.span("unknown field '"^field_name^"' for "^sn)in
            let target={Ir.node=Ir.Var b.ir_name;typ=b.typ;span=s.span;transfer=Ir.Direct;mode_set} in
            let x=expression ~explc ~bb ~expected:f.typ ~transfer:(if move_only f.typ then Ir.Move else Ir.Clone)env x in require x.span f.typ x.typ;make(Ir.Ref_field_assign(target,f,x)),false
          |Ref(false,Named _)->invalid s.span "cannot assign a field through a shared reference"
          |_->invalid s.span "field assignment expects a struct local")
        | Deref_assign(r,x)->let r=expression ~explc ~bb ~transfer:Ir.Direct env r in(match r.typ with Ref(true,t)->let x=expression ~explc ~bb ~expected:t ~transfer:(if move_only t then Ir.Move else Ir.Clone)env x in require x.span t x.typ;make(Ir.Ref_set(r,x)),false|Ref(false,_)->invalid r.span "cannot assign through a shared reference"|_->invalid r.span "dereference assignment expects &mut T")
        | Index_assign(r,i,x)->let raw=expression ~explc ~bb ~transfer:Ir.Direct env r in let target,element=match r.node,raw.typ with
            | Var n,Vec t->(match Hashtbl.find env n with b when b.mutable_->{Ir.node=Ir.Address b.ir_name;typ=Ref(true,b.typ);span=r.span;transfer=Ir.Direct;mode_set},t|_->invalid r.span "index assignment requires a mutable vector local")
            | Var _,Ref(true,Vec t)->raw,t|_,Ref(false,Vec _)->invalid r.span "index assignment requires &mut Vec"|_->invalid r.span "index assignment expects Vec" in
          let i=expression ~explc ~bb ~expected:I64 env i and x=expression ~explc ~bb ~expected:element ~transfer:(if move_only element then Ir.Move else Ir.Clone) env x in require i.span I64 i.typ;require x.span element x.typ;make(Ir.Vec_set_stmt(target,i,x)),false
        | Expr x->let x=expression ~explc ~bb ~transfer:Ir.Direct env x in
          let ends=match x.node with Ir.Call("panic",_)->true|Ir.Match_control(_,_,arms)->List.for_all(fun(_,_,b,_)->b.Ir.terminated)arms|_->false in make(Ir.Expr x),ends
        | Return x->let x=Option.map(expression ~explc ~bb ~expected:return_type ~transfer:Ir.Move env)x in require s.span return_type(match x with None->Unit|Some x->x.typ);make(Ir.Return x),true
        | If(c,a,b)->let c=expression ~explc ~bb ~mode_set ~expected:Bool env c in require c.span Bool c.typ;
          let a,at=statements(copy_env env)return_type mode_set in_loop a in
          let b,bt=statements(copy_env env)return_type mode_set in_loop b in make(Ir.If(c,a,b)),at&&bt
        | While(c,b)->let c=expression ~explc ~bb ~mode_set ~expected:Bool env c in require c.span Bool c.typ;
          let b,_=statements(copy_env env)return_type mode_set true b in make(Ir.While(c,b)),false
        | For _->invalid s.span "for statement was not lowered"
        | Block body->let scoped=copy_env env in let body,ends=statements ~boundary:s.span scoped return_type mode_set in_loop body in make(Ir.Block body),ends
        | Scope(added,body)->let inner_modes=union_modes mode_set added in let scoped=copy_env env in
          let body,ends=statements ~boundary:s.span scoped return_type inner_modes in_loop body in
          make(Ir.Scope body),ends
        | Break->if not in_loop then invalid s.span "break outside loop";make Ir.Break,true
        | Continue->if not in_loop then invalid s.span "continue outside loop";make Ir.Continue,true in
        go ends(lowered::out)rest
    in let lowered,terminated=go false [] values in
    capability_boundary:=previous_boundary;
    {Ir.mode_set;statements=lowered;terminated},terminated in
  let functions=List.map(fun(f:func)->capability_boundary:=f.span;
    let base=match String.index_opt f.name '<'with Some i->String.sub f.name 0 i|None->f.name in
    let owner=if String.starts_with ~prefix:"__method$" base then
        let ending=String.rindex base '$'in String.sub base 9 (ending-9)else base in
    current_module:=(match String.rindex_opt owner '.'with Some i->Some(String.sub owner 0 i)|None->None);
    let mode_set=union_modes program.global_mode_set f.mode_set in
    let params=List.map(fun(p:param)->{p with typ=canonical p.typ})f.params and return_type=canonical f.return_type in
    current_try_return := return_type;
    let env=Hashtbl.create 16 in List.iter(fun(p:param)->if Hashtbl.mem env p.name then invalid p.span("duplicate parameter '"^p.name^"'");Hashtbl.add env p.name {typ=p.typ;mutable_=false;ir_name=p.name})params;
    let body,ends=statements ~initial:(List.map(fun(p:param)->p.name)params) env return_type mode_set false f.body in
    if return_type<>Unit&&not ends then invalid f.span("function '"^f.name^"' may fall through without returning a value");
    {Ir.name=f.name;mode_set;params;return_type;body;span=f.span})program.functions in
  Ok {Ir.enums=program.enums; layouts=List.map(fun(d:struct_decl)->Hashtbl.find layout_table d.struct_name)program.structs;functions;entry}
 with Invalid d->Error d

let rec uses_range_expr (e:expr) = match e.node with
  | Struct_lit("Range",_) -> true
  | Unary(_,x)|Borrow(_,x)|Field(x,_)|Tuple_index(x,_)|Try x -> uses_range_expr x
  | Binary(_,a,b)|Index(a,b) -> uses_range_expr a||uses_range_expr b
  | Call(_,xs)|Generic_call(_,_,xs)|Intrinsic(_,_,xs)|Vec_lit xs|Tuple_lit xs -> List.exists uses_range_expr xs
  | Method(x,_,xs)->uses_range_expr x||List.exists uses_range_expr xs
  | Struct_lit(_,fs)|Generic_struct_lit(_,_,fs)->List.exists(fun(_,x,_)->uses_range_expr x)fs
  | Variant_lit(_,_,_,x)->Option.fold ~none:false ~some:uses_range_expr x
  | Match(x,arms)->uses_range_expr x||List.exists(fun(a:match_arm)->uses_range_stmts a.body||Option.fold ~none:false ~some:uses_range_expr a.tail)arms
  | If_expr(c,a,b)->List.exists uses_range_expr[c;a;b]
  | Match_control _->assert false
  | Int_lit _|Float_lit _|String_lit _|Bool_lit _|Var _->false
and uses_range_stmt (s:stmt) = match s.node with
  | Let(_,_,_,x)|Let_pattern(_,_,_,x)|Assign(_,x)|Field_assign(_,_,x)|Expr x->uses_range_expr x
  | Index_assign(a,b,x)->List.exists uses_range_expr[a;b;x]
  | Deref_assign(a,b)->uses_range_expr a||uses_range_expr b
  | Return x->Option.fold ~none:false ~some:uses_range_expr x
  | If(c,a,b)->uses_range_expr c||uses_range_stmts a||uses_range_stmts b
  | While(c,b)->uses_range_expr c||uses_range_stmts b
  | For(_,x,b)->uses_range_expr x||uses_range_stmts b
  | Block b|Scope(_,b)->uses_range_stmts b
  | Break|Continue->false
and uses_range_stmts xs = List.exists uses_range_stmt xs

let program_uses_range program = List.exists(fun(f:func)->uses_range_stmts f.body)program.functions

let add_prelude program =
  let reserved=["Option";"Result";"Range"] in
  match List.find_opt(fun (d:enum_decl)->List.mem d.enum_name reserved)program.enums,
        List.find_opt(fun (d:struct_decl)->List.mem d.struct_name reserved)program.structs with
  | Some d,_->Error{span=d.enum_span;message="prelude type name '"^d.enum_name^"' is reserved";notes=[];help=None}
  | _,Some d->Error{span=d.struct_span;message="prelude type name '"^d.struct_name^"' is reserved";notes=[];help=None}
  | None,None->let p=Prelude.program() in
      let range=program_uses_range program in Ok{program with
      structs=(if range then p.structs@program.structs else program.structs);
      enums=p.enums@program.enums;
      functions=(if range then p.functions@program.functions else program.functions)}

let finish = function
  | Error d->Error d
  | Ok typed->try Ok(Semantic_analysis.check(Semantic_lower.lower typed))with Semantic_ir.Invalid(span,message)->Error{span;message;notes=[];help=None}
    |Semantic_analysis.Diagnostic(span,message,notes)->Error{span;message;notes;help=None}

let validate_tests program = List.iter(fun(f:func)->if f.is_test &&
  (f.type_params<>[] || f.params<>[] || f.return_type<>Unit)then
    invalid f.span "test functions must be nongeneric, parameterless, and return Unit")program.functions

let check ?(entry="main") program = try
  validate_tests program;
  finish (match add_prelude program with
  | Error d->Error d
  | Ok program->match Monomorph.run program with
  | Error d->Error{span=d.span;message=d.message;notes=[];help=d.help}
  | Ok program->check_internal ~entry program)
  with Invalid d->Error d

let check_project ?(entry_function="main") ~(entry_module:string) (programs : Ast.program list) =
  let uses_range=List.exists program_uses_range programs in
  let builtins = ["print";"println";"len";"arg";"arg_count";"assert";"assert_msg";
    "panic";"float";"int";"int_to_str";"zeros";"repeat";"read_text";"read_ints";
    "read_floats";"open_read";"open_write";"raw_alloc_int";"raw_load_int";
    "raw_store_int";"raw_free_int";"raw_alloc";"raw_load";"raw_store";"raw_free";"ptr_addr";
    "syscall0";"syscall1";"syscall2";"syscall3";"syscall4";"syscall5";"syscall6";
    "box";"i8";"u8";"i16";"u16";"i32";"u32";"i64";"u64";"f32";"f64"] in
  let module_name p = match p.module_decl with Some(n,_)->n | None->"$entry" in
  let qualify module_ imports span name =
    if name="Option"||name="Result"||name="Range" then name else match String.rindex_opt name '.' with
    | None -> module_^"."^name
    | Some i ->
        let owner=String.sub name 0 i in
        match List.find_opt(fun i->i.import_name=owner ||
          Option.fold ~none:false ~some:(fun(n,_)->n=owner)i.import_alias)imports with
        |Some dependency->dependency.import_name ^ String.sub name i (String.length name-i)
        |None->invalid span ("module '"^owner^"' is not directly imported") in
  let user_box module_=List.exists(fun p->module_name p=module_ &&
      (List.exists(fun(d:struct_decl)->d.struct_name="Box")p.structs ||
       List.exists(fun(d:enum_decl)->d.enum_name="Box")p.enums))programs in
  let builtin_box module_ imports span n =
    if n="Box" && not(user_box module_)then true
    else if String.contains n '.' then qualify module_ imports span n="core.box.Box" else false in
  let rec map_type module_ imports span = function
    | Named n->Named(qualify module_ imports span n)
    | Apply(n,ts) when builtin_box module_ imports span n->
        (match ts with [t]->Box(map_type module_ imports span t)|_->invalid span "Box expects 1 type argument")
    | Box t->Box(map_type module_ imports span t)
    | Vec t->Vec(map_type module_ imports span t)
    | Slice t->Slice(map_type module_ imports span t)
    | Ptr t->Ptr(map_type module_ imports span t)
    | Ref(m,t)->Ref(m,map_type module_ imports span t)
    | Apply(n,ts)->Apply(qualify module_ imports span n,List.map(map_type module_ imports span)ts)
    | Tuple ts->Tuple(List.map(map_type module_ imports span)ts)
    | Function(ts,r)->Function(List.map(map_type module_ imports span)ts,map_type module_ imports span r)
    | t->t in
  let call_name module_ imports span n =
    let declared_box=n="box" && List.exists(fun p->module_name p=module_ &&
      List.exists(fun(f:func)->f.name="box")p.functions)programs in
    if declared_box then qualify module_ imports span n
    else if List.mem n builtins then n else qualify module_ imports span n in
  let rec map_expr module_ imports (e:Ast.expr) =
    let m=map_expr module_ imports in
    let node=match e.node with
    | Unary(op,x)->Unary(op,m x)|Binary(op,a,b)->Binary(op,m a,m b)
    | Call(n,xs)->let n=call_name module_ imports e.span n in
        (match Core_modules.intrinsic n with Some kind->Intrinsic(kind,[],List.map m xs)|None->Call(n,List.map m xs))
    | Generic_call(n,ts,xs)->let n=call_name module_ imports e.span n in
        let ts=List.map(map_type module_ imports e.span)ts in
        (match Core_modules.intrinsic n with Some kind->Intrinsic(kind,ts,List.map m xs)|None->Generic_call(n,ts,List.map m xs))
    | Intrinsic(kind,ts,xs)->Intrinsic(kind,List.map(map_type module_ imports e.span)ts,List.map m xs)
    | Vec_lit xs->Vec_lit(List.map m xs)|Index(a,b)->Index(m a,m b)
    | Tuple_lit xs->Tuple_lit(List.map m xs)
    | Variant_lit(n,ts,v,x)->Variant_lit(qualify module_ imports e.span n,List.map(map_type module_ imports e.span)ts,v,Option.map m x)
    | Match(x,arms)->
        let rec pattern p =
          let pattern_node=match p.pattern_node with
          | Variant_pattern(owner,v,payload)->Variant_pattern(qualify module_ imports p.pattern_span owner,v,Option.map pattern payload)
          | Tuple_pattern ps->Tuple_pattern(List.map pattern ps)
          | Literal_pattern x->Literal_pattern(m x)
          | (Wildcard_pattern|Binding_pattern _)as n->n in {p with pattern_node} in
        Match(m x,List.map(fun a->{a with pattern=pattern a.pattern;
          body=List.map(map_stmt module_ imports)a.body;tail=Option.map m a.tail})arms)
    | If_expr(c,a,b)->If_expr(m c,m a,m b)
    | Method(_, ("iter"|"enumerate"),[]) when module_<>"std.iter" && not(List.exists(fun i->i.import_name="std.iter")imports)->
        invalid e.span "iterator factory requires explicit 'use std.iter;'"
    | Method(r,n,xs)->Method(m r,n,List.map m xs)|Borrow(b,x)->Borrow(b,m x)
    | Struct_lit(n,fs)->Struct_lit(qualify module_ imports e.span n,List.map(fun(n,x,s)->n,m x,s)fs)
    | Generic_struct_lit(n,ts,fs)->Generic_struct_lit(qualify module_ imports e.span n,List.map(map_type module_ imports e.span)ts,List.map(fun(n,x,s)->n,m x,s)fs)
    | Field(r,n)->Field(m r,n)
    | Tuple_index(r,n)->Tuple_index(m r,n)
    | Try x->Try(m x)
    | Match_control _ -> assert false
    | Var n when String.contains n '.'->Var(qualify module_ imports e.span n)
    | (Int_lit _|Float_lit _|String_lit _|Bool_lit _|Var _) as n->n in
    {e with node}
  and map_stmt module_ imports (s:Ast.stmt) =
    let e=map_expr module_ imports and ss=List.map(map_stmt module_ imports) in
    let node=match s.node with
    | Let(m,n,t,x)->Let(m,n,Option.map(map_type module_ imports s.span)t,e x)
    | Let_pattern(m,p,t,x)->Let_pattern(m,p,Option.map(map_type module_ imports s.span)t,e x)
    | Assign(n,x)->Assign(n,e x)|Field_assign(n,f,x)->Field_assign(n,f,e x)
    | Index_assign(a,b,x)->Index_assign(e a,e b,e x)|Deref_assign(a,b)->Deref_assign(e a,e b)
    | Expr x->Expr(e x)|Return x->Return(Option.map e x)
    | If(c,a,b)->If(e c,ss a,ss b)|While(c,b)->While(e c,ss b)|For(p,x,b)->For(p,e x,ss b)|Block b->Block(ss b)|Scope(m,b)->Scope(m,ss b)
    | (Break|Continue) as n->n in {s with node} in
  try
    List.iter validate_tests programs;
    let structs=(if uses_range then (Prelude.program()).structs else []) @ List.concat_map(fun p->let m=module_name p and imports=p.imports in
      List.map(fun(d:struct_decl)->{d with struct_name=m^"."^d.struct_name;
        fields=List.map(fun f->{f with field_type=map_type m imports f.field_span f.field_type})d.fields})p.structs)programs in
    let functions=List.concat_map(fun p->let m=module_name p and imports=p.imports in
      List.map(fun(f:func)->let name=if String.starts_with ~prefix:"__method$" f.name then
          match String.split_on_char '$' f.name with ["__method";owner;method_]->"__method$"^m^"."^owner^"$"^method_|_->assert false
        else m^"."^f.name in {f with name;
        mode_set=union_modes p.global_mode_set f.mode_set;
        params=List.map(fun(q:param)->{q with typ=map_type m imports q.span q.typ})f.params;
        return_type=map_type m imports f.span f.return_type;
        body=List.map(map_stmt m imports)f.body})p.functions)programs @
      (if uses_range then (Prelude.program()).functions else []) in
    List.iter(fun p->
      List.iter(fun (d:enum_decl)->if List.mem d.enum_name ["Option";"Result";"Range"]then invalid d.enum_span("prelude type name '"^d.enum_name^"' is reserved"))p.enums;
      List.iter(fun (d:struct_decl)->if List.mem d.struct_name ["Option";"Result";"Range"]then invalid d.struct_span("prelude type name '"^d.struct_name^"' is reserved"))p.structs)programs;
    let enums=(Prelude.program()).enums @ List.concat_map(fun p->let m=module_name p and imports=p.imports in
      List.map(fun(d:enum_decl)->{d with enum_name=m^"."^d.enum_name;
        variants=List.map(fun v->{v with payload=Option.map(map_type m imports v.variant_span)v.payload})d.variants})p.enums)programs in
    let merged={module_decl=None;imports=[];global_mode_set=[];structs;enums;functions} in
    (match Monomorph.run merged with Error d->Error{span=d.span;message=d.message;notes=[];help=d.help}
     |Ok merged->finish(check_internal ~entry:(entry_module^"."^entry_function) merged))
  with Invalid d->Error d
