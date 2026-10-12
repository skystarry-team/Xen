(* SPDX-License-Identifier: Apache-2.0 *)
open Ast
open Semantic_ir
module M = Machine_ir
module T = Type_desc
module R = Linux_runtime
module H = Heap_runtime

exception Unsupported of Backend_intf.error
let unsupported ?span message =
  raise(Unsupported {span;message="aarch64-linux: "^message})
type env = {
  m:M.t; program:program; func:func; slots:int array;
  flags:(int * int,int)Hashtbl.t;
  box_helpers:(typ,string)Hashtbl.t; box_queue:typ Queue.t;
  result_slot:int; epilogue:string;
}
let layout program name = List.find(fun(l:struct_layout)->l.name=name)program.layouts
let size program = function
  |Named name->(layout program name).size|typ->(T.describe typ).size
let validate_type program span typ =
  (* Function signatures can refer back to their containing aggregate without
     introducing a recursive value layout. Visit each named type once per path. *)
  let rec visit seen = function
    |I8|U8|I16|U16|I32|U32|I64|U64|F32|F64|Bool|Unit|String->()
    |Ref(_,t)|Box t->visit seen t
    |Function(args,result)->List.iter(visit seen)(result::args)
    |Named n when List.mem n seen->()
    |Named n->List.iter(fun(f:struct_field)->visit(n::seen)f.typ)(layout program n).fields
    |typ->unsupported ~span ("type "^string_of_typ typ^" is not implemented in the initial ARM64 backend")
  in visit [] typ

let address e reg id = M.offset e.m reg 29 (-e.slots.(id))
let load e reg (v:value) =
  if v.typ=Unit then M.int e.m reg 0 else begin
    address e 15 v.id;
    M.load e.m ~bytes:(size e.program v.typ) ~signed:(T.is_signed_int v.typ) reg 15 0
  end
let store e (v:value) reg =
  if v.typ<>Unit then begin address e 15 v.id;
    M.store e.m ~bytes:(size e.program v.typ) reg 15 0 end
let load_float e reg (v:value) =
  load e 0 v;M.fp_from_bits e.m ~single:(v.typ=F32) reg 0
let store_float e (v:value) reg =
  M.fp_to_bits e.m ~single:(v.typ=F32) 0 reg;store e v 0
let float_constant m reg number =
  M.imm m 1 (Int64.bits_of_float number);M.fp_from_bits m ~single:false reg 1

(* Byte copy uses only x9..x12, x16; argument registers survive parameter copies.
   Self-copy is safe. Checked IR stages replacements before writing a place. *)
let copy m bytes =
  if bytes>0 then begin
    let loop=M.fresh m "copy_" in M.int m 11 bytes;M.label m loop;
    M.load m ~bytes:1 12 10 0;M.store m ~bytes:1 12 9 0;
    M.offset m 9 9 1;M.offset m 10 10 1;M.offset m 11 11 (-1);
    M.cmp_zero m 11;M.cond m 1 loop
  end
let place_address e reg (p:place) =
  address e reg p.root;
  List.iter(function
    |Field field->M.offset e.m reg reg field.offset
    |Deref->M.load e.m reg reg 0
    |Element _->unsupported ~span:p.span "collection projections are not implemented")p.projections
let copy_value e (dst:value) (src:value) =
  address e 9 dst.id;address e 10 src.id;copy e.m (size e.program dst.typ)
let rec owned_leaves program offset = function
  |(String|Box _)as typ->[offset,typ]
  |Named n->List.concat_map(fun(f:struct_field)->owned_leaves program (offset+f.offset) f.typ)
      (layout program n).fields
  |_->[]
let box_helper m helpers pending typ = match Hashtbl.find_opt helpers typ with
  |Some name->name
  |None->let name=M.fresh m "box_type_drop_" in
      (* Register before chasing child types, including mutually recursive ones. *)
      Hashtbl.add helpers typ name;Queue.add typ pending;name
let flag_offset e p leaf =
  let offset=List.fold_left(fun acc->function
    |Field f->Option.map(fun n->n+f.offset)acc|_->None)(Some 0)p.projections in
  Option.bind offset(fun offset->Hashtbl.find_opt e.flags(p.root,offset+leaf))
let set_flags e p yes =
  List.iter(fun(off,_)->Option.iter(fun flag->M.offset e.m 15 29 (-flag);
    M.int e.m 9 (if yes then 1 else 0);M.store e.m 9 15 0)(flag_offset e p off))
    (owned_leaves e.program 0 p.typ)
let forget e p =
  set_flags e p false;
  (* Forget transfers ownership without freeing it. Dereferenced caller storage
     has no flag in this frame; leave its runtime representation inactive too. *)
  List.iter(fun(offset,typ)->place_address e 9 p;M.offset e.m 9 9 offset;
    List.iter(fun d->M.store e.m 31 9 d)(if typ=String then [0;8;16]else[0]))
    (owned_leaves e.program 0 p.typ)
let drop e p =
  List.iter(fun(off,typ)->
    let skip=M.fresh e.m "drop_inactive_" in
    Option.iter(fun flag->M.offset e.m 15 29 (-flag);M.load e.m 9 15 0;
      M.cmp_zero e.m 9;M.cond e.m 0 skip;M.store e.m 31 15 0)(flag_offset e p off);
    place_address e 0 p;M.offset e.m 0 0 off;
    (match typ with
    |String->R.call e.m "runtime_string_drop"
    |Box _->M.address e.m 1 (box_helper e.m e.box_helpers e.box_queue typ);
        R.call e.m "runtime_box_drop"
    |_->assert false);
    M.label e.m skip)(List.rev(owned_leaves e.program 0 p.typ))
let runtime_error e span message =
  let label=M.fresh e.m "error_" and after=M.fresh e.m "after_error_" in
  M.branch e.m after;M.label e.m label;
  R.fail e.m (Printf.sprintf "%s:%d:%d: xen runtime error: %s\n"
    span.file span.line span.column message);
  M.label e.m after;label
let depth_enter e span =
  let error=runtime_error e span "maximum call depth exceeded" in
  M.address e.m 9 "call_depth";M.load e.m 10 9 0;M.int e.m 11 4096;
  M.cmp e.m 10 11;M.cond e.m 2 error;
  M.offset e.m 10 10 1;M.store e.m 10 9 0
let depth_exit e =
  M.address e.m 9 "call_depth";M.load e.m 10 9 0;
  M.offset e.m 10 10 (-1);M.store e.m 10 9 0
let comparison unsigned = function
  |"=="->0|"!="->1|"<"->if unsigned then 3 else 11
  |"<="->if unsigned then 9 else 13|">"->if unsigned then 8 else 12
  |">="->if unsigned then 2 else 10|_->assert false
let string_parts e pointer length (v:value) =
  address e 15 v.id;M.load e.m pointer 15 0;M.load e.m length 15 8
let string_equal e (v:value) operator a b =
  let m=e.m in
  let unequal=M.fresh m "unequal_" and loop=M.fresh m "compare_"
  and equal=M.fresh m "equal_" and done_=M.fresh m "compared_" in
  string_parts e 0 2 a;string_parts e 1 3 b;
  M.cmp m 2 3;M.cond m 1 unequal;M.label m loop;
  M.cmp_zero m 2;M.cond m 0 equal;
  M.load m ~bytes:1 4 0 0;M.load m ~bytes:1 5 1 0;
  M.cmp m 4 5;M.cond m 1 unequal;
  M.offset m 0 0 1;M.offset m 1 1 1;M.offset m 2 2 (-1);M.branch m loop;
  M.label m equal;M.int m 0 (if operator="==" then 1 else 0);M.branch m done_;
  M.label m unequal;M.int m 0 (if operator="==" then 0 else 1);M.label m done_;store e v 0
let binary e (v:value) operator (a:value) (b:value) =
  let m=e.m in
  if a.typ=String then begin
    if operator="+" then begin
      address e 0 v.id;address e 1 a.id;address e 2 b.id;R.call m "runtime_string_concat"
    end else string_equal e v operator a b
  end else if T.is_float a.typ then begin
    let single=a.typ=F32 in load_float e 0 a;load_float e 1 b;
    (match operator with
    |"+"|"-"|"*"|"/"->M.fp_binary m ~single operator 0 0 1;store_float e v 0
    |"=="|"!="|"<"|"<="|">"|">="->
        (* FCMP unordered sets NZCV=0011. MI/LS/GT/GE exclude unordered;
           NE deliberately includes it. Integer LT/LE would include NaN. *)
        M.fp_cmp m ~single 0 1;
        let cond=match operator with
          |"=="->0|"!="->1|"<"->4|"<="->9|">"->12|_->10 in
        M.cset m 0 cond;store e v 0
    |_->unsupported ~span:v.span ("Float operator "^operator^" is not implemented"))
  end else begin
    (* Error stubs must precede operands: the branch over them preserves registers
       but their setup is ordinary code, not part of the evaluated expression. *)
    let division=operator="/" || operator="%" in
    let error_zero=if division then runtime_error e v.span
      (if operator="/" then "division by zero" else "remainder by zero") else "" in
    let signed=division && T.is_signed_int a.typ in
    let error_overflow=if signed then runtime_error e v.span
      (if operator="/" then "signed division overflow" else "signed remainder overflow")else "" in
    load e 0 a;load e 1 b;
    (match operator with
    |"+"->M.add m 0 0 1|"-"->M.sub m 0 0 1|"*"->M.mul m 0 0 1
    |"/"|"%"->
        M.cmp_zero m 1;M.cond m 0 error_zero;
        if signed then begin
          let safe=M.fresh m "divide_" in
          M.imm m 2 (T.min_signed(T.bits a.typ));M.cmp m 0 2;M.cond m 1 safe;
          M.imm m 2 (-1L);M.cmp m 1 2;M.cond m 0 error_overflow;M.label m safe
        end;
        M.rr m (if signed then 0x9ac00c00 else 0x9ac00800) 2 0 1;
        if operator="%" then (M.mul m 2 2 1;M.sub m 0 0 2)else M.mov m 0 2
    |("=="|"!="|"<"|"<="|">"|">=")->
        M.cmp m 0 1;M.cset m 0 (comparison(T.is_unsigned_int a.typ)operator)
    |_->unsupported ~span:v.span ("operator "^operator^" is not implemented"));
    store e v 0
  end
let conversion e ?message (v:value) (a:value) =
  let error=runtime_error e v.span (Option.value message
    ~default:("numeric conversion to "^string_of_typ v.typ^" failed")) in
  let m=e.m in
  if T.is_integer a.typ && T.is_float v.typ then begin
    load e 0 a;M.fp_of_int m ~single:(v.typ=F32) ~unsigned:(T.is_unsigned_int a.typ) 0 0;
    store_float e v 0
  end else if T.is_float a.typ then begin
    load_float e 0 a;
    if a.typ=F32 then M.fp_convert m ~single:false 0 0;
    let bound number cond=float_constant m 1 number;
      M.fp_cmp m ~single:false 0 1;M.cond m cond error in
    if T.is_integer v.typ then begin
      M.fp_cmp m ~single:false 0 0;M.cond m 6 error;
      let bits=T.bits v.typ in
      let lower,upper=if T.is_signed_int v.typ then
          Int64.to_float(T.min_signed bits),Float.ldexp 1. (bits-1)
        else 0.,Float.ldexp 1. bits in
      (* Check the input, before truncation, as on x86-64. *)
      bound lower 4;bound upper 10;
      M.fp_to_int m ~single:false ~unsigned:(T.is_unsigned_int v.typ) 0 0;store e v 0
    end else begin
      if v.typ=F32 then begin
        if a.typ=F64 then begin
          M.fp_cmp m ~single:false 0 0;M.cond m 6 error;
          bound (-3.4028234663852886e38) 4;bound 3.4028234663852886e38 12
        end;
        M.fp_convert m ~single:true 0 0
      end;
      store_float e v 0
    end
  end else begin
  let bits=T.bits v.typ in load e 0 a;
  let bound number cond=M.imm m 1 number;M.cmp m 0 1;M.cond m cond error in
  if T.is_signed_int v.typ then begin
    if T.is_unsigned_int a.typ then bound(T.max_signed bits)8
    else if bits<64 then (bound(T.min_signed bits)11;bound(T.max_signed bits)12)
  end else begin
    if T.is_signed_int a.typ then (M.cmp_zero m 0;M.cond m 11 error);
    if bits<64 then bound(T.max_unsigned bits)8
  end;store e v 0
  end
let output e (a:value) =
  let m=e.m in
  match a.typ with
  |String->string_parts e 1 2 a;M.int m 0 1;R.call m "runtime_write"
  |Bool->
      let no=M.fresh m "false_" and done_=M.fresh m "bool_printed_" in
      load e 0 a;M.cmp_zero m 0;M.cond m 0 no;
      R.write_constant m 1 "true";M.branch m done_;M.label m no;
      R.write_constant m 1 "false";M.label m done_
  |typ when T.is_integer typ->load e 0 a;
      M.int m 1 (if T.is_signed_int typ then 1 else 0);R.call m "runtime_integer"
  |F32|F64->load_float e 0 a;
      if a.typ=F32 then M.fp_convert m ~single:false 0 0;
      M.fp_to_bits m ~single:false 0 0;R.call m "runtime_float"
  |_->unsupported ~span:a.span ("printing "^string_of_typ a.typ^" is not implemented")
let call e (v:value) name args =
  let m=e.m in
  match name,args with
  |("print"|"println"),[a]->output e a;if name="println" then R.write_constant m 1 "\n"
  |"len",[a]->address e 15 a.id;M.load m 0 15 8;store e v 0
  |"arg_count",[]->M.address m 15 "argc";M.load m 0 15 0;store e v 0
  |"arg",[a]->
      let missing=M.fresh m "arg_missing_" and scan=M.fresh m "arg_scan_"
      and done_=M.fresh m "arg_done_" in
      load e 0 a;M.address m 15 "argc";M.load m 1 15 0;
      M.cmp m 0 1;M.cond m 2 missing;
      M.address m 15 "argv";M.load m 1 15 0;M.int m 2 8;M.mul m 0 0 2;
      M.add m 0 1 0;M.load m 0 0 0;M.mov m 1 0;M.int m 2 0;
      M.label m scan;M.load m ~bytes:1 3 1 0;M.cmp_zero m 3;M.cond m 0 done_;
      M.offset m 1 1 1;M.offset m 2 2 1;M.branch m scan;
      M.label m missing;R.fail m "xen runtime error: missing program argument\n";M.label m done_;
      address e 15 v.id;M.store m 0 15 0;M.store m 2 15 8;M.store m 31 15 16
  |"assert",[a]->
      let ok=M.fresh m "assert_ok_" in load e 0 a;M.cmp_zero m 0;M.cond m 1 ok;
      R.fail m "assertion failed\n";M.label m ok
  |"assert_msg",[a;message]->
      let ok=M.fresh m "assert_ok_" in load e 0 a;M.cmp_zero m 0;M.cond m 1 ok;
      R.write_constant m 2 "assertion failed: ";string_parts e 1 2 message;
      M.int m 0 2;R.call m "runtime_write";R.write_constant m 2 "\n";R.exit m 1;M.label m ok
  |"panic",[message]->string_parts e 1 2 message;M.int m 0 2;
      R.call m "runtime_write";R.write_constant m 2 "\n";R.exit m 1
  |name,[a] when String.starts_with ~prefix:"__convert_" name->conversion e v a
  |"float",[a]->conversion e v a
  |"int",[a]->conversion e ~message:"Float cannot be converted to Int" v a
  |"int_to_str",[a]->load e 0 a;address e 1 v.id;R.call m "runtime_int_to_string"
  |_->
      if not(List.exists(fun(f:func)->f.name=name)e.program.functions)then
        unsupported ~span:v.span ("builtin '"^name^"' is not implemented");
      List.iteri(fun reg(a:value)->address e reg a.id)args;
      address e 8 v.id;R.call m ("fn_"^name)
let rvalue e (v:value) node =
  let m=e.m in
  match node with
  |Int_lit n->M.imm m 0 n;store e v 0
  |Float_lit n->M.imm m 0 (if v.typ=F32 then
      Int64.of_int32(Int32.bits_of_float n)else Int64.bits_of_float n);store e v 0
  |Bool_lit b->M.int m 0 (if b then 1 else 0);store e v 0
  |String_lit s->
      M.address m 0 (M.constant m s);M.int m 1(String.length s);
      address e 15 v.id;M.store m 0 15 0;M.store m 1 15 8;M.store m 31 15 16
  |Unary("-",a) when T.is_float a.typ->
      load_float e 0 a;M.fp_neg m ~single:(a.typ=F32) 0 0;store_float e v 0
  |Unary("-",a)->load e 0 a;M.sub m 0 31 0;store e v 0
  |Unary("!",a)->load e 0 a;M.cmp_zero m 0;M.cset m 0 0;store e v 0
  |Binary(op,a,b)->binary e v op a b
  |Call(name,args)->call e v name args
  |Function_address name->M.address m 0 ("fn_"^name);store e v 0
  |Indirect_call(callee,args)->
      List.iteri(fun reg(a:value)->address e reg a.id)args;
      address e 8 v.id;load e 17 callee;M.word m (0xd63f0000 lor (17 lsl 5))
  |Struct_lit(_,fields)->List.iter(fun((field:struct_field),(a:value))->
      address e 9 v.id;M.offset m 9 9 field.offset;
      address e 10 a.id;copy m (size e.program a.typ))fields
  |Box_new a->
      let error=runtime_error e v.span "Box allocation failed" in
      M.int m 0 (H.box_bytes(size e.program a.typ));R.call m "runtime_alloc";
      M.imm m 9 (-4095L);M.cmp m 0 9;M.cond m 2 error;
      M.offset m 0 0 H.box_header_bytes;store e v 0;
      M.mov m 9 0;address e 10 a.id;copy m (size e.program a.typ)
  |Box_take a->
      load e 10 a;address e 9 v.id;copy m (size e.program v.typ);
      load e 0 a;M.offset m 0 0 (-H.box_header_bytes);
      M.int m 1 (H.box_bytes(size e.program v.typ));R.call m "runtime_unmap"
  |Exchange(target,a)->load e 10 target;address e 9 v.id;copy m(size e.program v.typ);
      load e 9 target;address e 10 a.id;copy m(size e.program a.typ)
  |Syscall _->unsupported ~span:v.span
      "raw syscalls and platform-dependent stdlib modules are not implemented; x86-64 syscall numbers cannot run on ARM64"
  |_->unsupported ~span:v.span "this operation is not implemented in the initial ARM64 backend"
let operation e (op:operation) = match op.node with
  |Storage_live _|Storage_dead _->()
  |Logical_call_enter _->depth_enter e op.span
  |Logical_call_exit _->depth_exit e
  |Eval(v,node)->rvalue e v node;
      if e.func.locals.(v.id).owned then set_flags e (place_of_value v) true
  |Acquire(v,kind,p)->place_address e 10 p;address e 9 v.id;
      copy e.m(size e.program v.typ);
      if kind=Clone then List.iter(fun(off,typ)->match typ with
        |String->address e 0 v.id;M.offset e.m 0 0 off;R.call e.m "runtime_string_clone"
        |_->unsupported ~span:v.span "move-only Box cannot be cloned")
          (owned_leaves e.program 0 v.typ);
      if kind=Move then forget e p;
      if e.func.locals.(v.id).owned then set_flags e (place_of_value v) true
  |Borrow(v,_,_,p)->place_address e 0 p;store e v 0
  |Initialize(p,v)->place_address e 9 p;address e 10 v.id;copy e.m(size e.program v.typ);
      set_flags e p true
  |Drop p->drop e p
  |Forget p->forget e p
  |Drop_flag(p,yes)->set_flags e p yes
  |Replace _->unsupported ~span:op.span "unelaborated replacement in checked IR"
let emit_function m program box_helpers box_queue (func:func) =
  let next=ref 8 in
  let slots=Array.map(fun(l:local)->next:= !next+T.align_up(max 1(size program l.typ))8;!next)func.locals in
  let flags=Hashtbl.create 32 in
  Array.iter(fun(l:local)->if l.owned then List.iter(fun(off,_)->
    next:= !next+8;Hashtbl.add flags(l.id,off)!next)(owned_leaves program 0 l.typ))func.locals;
  let frame=T.align_up !next 16 in
  (* Result pointer is at fp-8; local regions grow below it. *)
  let e={m;program;func;slots;flags;box_helpers;box_queue;
    result_slot=8;epilogue=M.fresh m "return_"}in
  M.label m ("fn_"^func.name);
  M.word m 0xa9bf7bfd; (* stp x29,x30,[sp,#-16]! *)
  M.word m 0x910003fd; (* mov x29,sp *)
  M.offset m 31 31 (-frame);M.offset m 15 29 (-8);M.store m 8 15 0;
  (* Initialize flags without touching incoming x0..x5 argument pointers. *)
  Hashtbl.iter(fun _ flag->M.offset m 15 29 (-flag);M.store m 31 15 0)flags;
  List.iteri(fun reg id->M.mov m 10 reg;address e 9 id;copy m(size program func.locals.(id).typ))func.params;
  List.iter(fun id->set_flags e(place_of_value(value_of_local func.locals.(id)))true)func.params;
  depth_enter e func.span;
  let block_label id=Printf.sprintf "block_%d_%d" func.id id in
  M.branch m (block_label func.entry);
  Array.iter(fun(b:block)->M.label m (block_label b.id);
    List.iter(operation e)b.operations;
    match b.terminator with
    |Jump id->M.branch m (block_label id)
    |Branch(v,yes,no)->load e 0 v;M.cmp_zero m 0;M.cond m 1(block_label yes);M.branch m(block_label no)
    |Return value->Option.iter(fun(v:value)->M.offset m 15 29 (-e.result_slot);
        M.load m 9 15 0;address e 10 v.id;copy m(size program v.typ))value;M.branch m e.epilogue
    |Stop->M.word m 0xd4200000 (* brk #0: unreachable is never a normal return *))func.blocks;
  M.label m e.epilogue;depth_exit e;
  M.word m 0x910003bf; (* mov sp,x29 *)
  M.word m 0xa8c17bfd; (* ldp x29,x30,[sp],#16 *)
  M.ret m
let generate ?(jit=true) ?(jit_report=false) checked =
  try
    if jit || jit_report then unsupported "JIT is not implemented; use --jit=off without --jit-report";
    let program=Semantic_ir.program checked in Semantic_ir.verify program;
    List.iter(fun(f:func)->validate_type program f.span f.return_type;
      Array.iter(fun(l:local)->validate_type program l.span l.typ)f.locals)program.functions;
    let m=M.create() in
    List.iter(M.global m)["call_depth";"argc";"argv"];
    M.label m "_start";
    M.load m 0 31 0;M.offset m 0 0 (-1);M.address m 15 "argc";M.store m 0 15 0;
    M.offset m 0 31 16;M.address m 15 "argv";M.store m 0 15 0;
    (* Entry returns Unit; reserve a valid result area for the internal ABI. *)
    M.offset m 31 31 (-16);M.offset m 8 31 0;
    R.call m ("fn_"^program.entry);R.exit m 0;
    let box_helpers=Hashtbl.create 16 and box_queue=Queue.create() in
    R.emit m;List.iter(emit_function m program box_helpers box_queue)program.functions;
    while not(Queue.is_empty box_queue)do
      let typ=Queue.take box_queue in
      let element=match typ with Box t->t|_->assert false in
      let leaves=List.rev(owned_leaves program 0 element)|>List.map(fun(off,typ)->
        off,(match typ with String->None|Box _->Some(box_helper m box_helpers box_queue typ)
          |_->assert false))in
      H.emit_box_helper m (Hashtbl.find box_helpers typ)
        ~bytes:(H.box_bytes(size program element))leaves
    done;
    Ok(Elf_writer.static_linux ~entry:0 m)
  with Unsupported error->Error error
    |M.Error message->Error({span=None;message="aarch64-linux: "^message}:Backend_intf.error)
let write path executable =
  let channel=open_out_bin path in
  Fun.protect ~finally:(fun()->close_out channel)(fun()->output_bytes channel executable);
  Unix.chmod path 0o755
