(* SPDX-License-Identifier: Apache-2.0 *)
(* Xen-owned runtime code in generated user executables has the additional
   MIT OR Apache-2.0 permission specified in the root LICENSE. Compiler source
   and the compiler executable remain Apache-2.0 only. *)
open Ast
open Semantic_ir
module M = Machine_ir
module T = Type_desc

type error = Backend_intf.error
exception Unsupported of error
let unsupported ?span message = raise (Unsupported { span; message })

module type Runtime = Runtime_intf.S
module Make(R : Runtime) = struct
module Output = Output_runtime.Make(R)
module Heap = Heap_runtime.Make(R)
module Collection = Collection_runtime.Make(R)
module File = File_runtime.Make(R)
module Compilation() = struct
(* Active source function frames, including the entry function. *)
let max_call_depth = 4096

type env = {
  slots : (int, int) Hashtbl.t; output : M.t; locals : local array;
  flags : ((int * int), int) Hashtbl.t;
  mutable stack_depth : int; mutable scratch : int;
}

let layouts : (string, struct_layout) Hashtbl.t = Hashtbl.create 16
let is_managed = function String | Vec _ -> true | Named n -> (Hashtbl.find layouts n).managed | _ -> false
let is_pair = function Ptr _ | Slice _ -> true | _ -> false
let rec descriptor typ = T.describe ~named:(fun n->let l=Hashtbl.find layouts n in
  let fields=List.map(fun (f:struct_field)->descriptor f.typ)l.fields in
  { T.size=l.size;alignment=l.alignment;
    trivial_copy=List.for_all(fun d->d.T.trivial_copy)fields;
    move_only=List.exists(fun d->d.T.move_only)fields ||
      List.exists(fun (f:struct_field)->match f.typ with Ptr _->true|_->false)l.fields;
    drop=(if List.exists(fun d->d.T.drop<>T.No_drop)fields then T.Drop_struct else T.No_drop);
    equality=List.for_all(fun d->d.T.equality)fields }) typ
let is_owned typ = match typ with
  | String | Vec _ | File | Box _ -> true
  | Named _ -> let d=descriptor typ in d.T.move_only || d.T.drop<>T.No_drop
  | _ -> false
let slot_size typ = (descriptor typ).size
let element_stride typ = max 1 (T.align_up (descriptor typ).size (descriptor typ).alignment)
let is_float typ = T.is_float typ
let aggregate_bias size = max 0 (size-8)
let runtime_type_name name =
  let out=Buffer.create(String.length name*2) in
  String.iter(fun c->Buffer.add_string out(Printf.sprintf "%02x" (Char.code c)))name;
  Buffer.contents out
let requested_vec_helpers : (string,typ) Hashtbl.t = Hashtbl.create 32
let vec_helper_label typ suffix =
  "__xen_vec_type_"^runtime_type_name(string_of_typ typ)^"_"^suffix
let request_vec_helper typ =
  let label=vec_helper_label typ "" in Hashtbl.replace requested_vec_helpers label typ
let clone_runtime = function
  | String -> "__xen_string_clone"
  | Vec _ as typ -> request_vec_helper typ;vec_helper_label typ "clone"
  | _ -> assert false
let drop_runtime = function
  | String -> "__xen_string_drop"
  | (Vec _|Box _) as typ -> request_vec_helper typ;vec_helper_label typ "drop"
  | _ -> assert false
let prepare_vec_stride output = function
  | Vec(Vec t)->M.bytes output[0x48;0xc7;0xc6];M.u32 output(Int64.of_int(element_stride t))
  | Vec t when t<>String->M.bytes output[0x48;0xc7;0xc6];M.u32 output(Int64.of_int(element_stride t))|_->()
let vec_equal_runtime = function Vec String->"__xen_vec_string_equal"|Vec(Vec String)->"__xen_vec_nested_string_equal"
  |Vec(Vec F64)->"__xen_vec_nested_f64_equal"|Vec(Vec F32)->"__xen_vec_nested_f32_equal"
  |Vec(Vec _)->"__xen_vec_nested_equal"|Vec F64->"__xen_vec_float_equal"
  |Vec F32->"__xen_vec_f32_equal"|Vec _->"__xen_vec_bytes_equal"|_->assert false

let serial = ref 0
let fresh prefix = incr serial; Printf.sprintf ".L_%s_%d" prefix !serial
let mov_rax_imm output value = M.bytes output [0x48;0xb8]; M.u64 output value
let load_int env name span = match Hashtbl.find_opt env.slots name with
  | Some offset -> M.bytes env.output [0x48;0x8b;0x85]; M.u32 env.output (Int64.of_int (-offset))
  | None -> unsupported ~span ("cannot resolve local '" ^ string_of_int name ^ "'")
let load_float env name span = match Hashtbl.find_opt env.slots name with
  | Some offset -> M.bytes env.output [0xf2;0x0f;0x10;0x85]; M.u32 env.output (Int64.of_int (-offset))
  | None -> unsupported ~span ("cannot resolve local '" ^ string_of_int name ^ "'")
let load_scalar env typ name span = match Hashtbl.find_opt env.slots name with
  | None->unsupported ~span ("cannot resolve local '"^string_of_int name^"'")
  | Some offset->let out=env.output in
      (match T.canonical typ with
       | I8->M.bytes out[0x48;0x0f;0xbe;0x85]|U8|Bool->M.bytes out[0x0f;0xb6;0x85]
       | I16->M.bytes out[0x48;0x0f;0xbf;0x85]|U16->M.bytes out[0x0f;0xb7;0x85]
       | I32->M.bytes out[0x48;0x63;0x85]|U32->M.bytes out[0x8b;0x85]
       | _->M.bytes out[0x48;0x8b;0x85]);M.u32 out(Int64.of_int(-offset))
let store_scalar_disp output typ displacement =
  (match (descriptor typ).size with 1->M.bytes output[0x88;0x85]|2->M.bytes output[0x66;0x89;0x85]
   |4->M.bytes output[0x89;0x85]|_->M.bytes output[0x48;0x89;0x85]);M.u32 output(Int64.of_int displacement)
let load_scalar_ptr output typ = match T.canonical typ with
  | I8->M.bytes output[0x48;0x0f;0xbe;0x00]|U8|Bool->M.bytes output[0x0f;0xb6;0x00]
  | I16->M.bytes output[0x48;0x0f;0xbf;0x00]|U16->M.bytes output[0x0f;0xb7;0x00]
  | I32->M.bytes output[0x48;0x63;0x00]|U32|F32->M.bytes output[0x8b;0x00]
  | _->M.bytes output[0x48;0x8b;0x00]
let load_string env name span = match Hashtbl.find_opt env.slots name with
  | Some offset ->
      M.bytes env.output [0x48;0x8b;0x85]; M.u32 env.output (Int64.of_int (-(offset + 16)));
      M.bytes env.output [0x48;0x8b;0x95]; M.u32 env.output (Int64.of_int (-(offset + 8)));
      M.bytes env.output [0x48;0x8b;0x8d]; M.u32 env.output (Int64.of_int (-offset))
  | None -> unsupported ~span ("cannot resolve local '" ^ string_of_int name ^ "'")
let load_managed = load_string
let load_ptr env name span = match Hashtbl.find_opt env.slots name with
  | Some offset ->
      M.bytes env.output [0x48;0x8b;0x85]; M.u32 env.output (Int64.of_int (-(offset + 8)));
      M.bytes env.output [0x48;0x8b;0x95]; M.u32 env.output (Int64.of_int (-offset))
  | None -> unsupported ~span ("cannot resolve local '" ^ string_of_int name ^ "'")
let descriptor_to_stack env =
  M.bytes env.output [0x48;0x83;0xec;0x18;0x48;0x89;0x04;0x24;0x48;0x89;0x54;0x24;0x08;0x48;0x89;0x4c;0x24;0x10];
  env.stack_depth <- env.stack_depth + 24
let descriptor_from_stack env =
  M.bytes env.output [0x48;0x8b;0x04;0x24;0x48;0x8b;0x54;0x24;0x08;0x48;0x8b;0x4c;0x24;0x10;0x48;0x83;0xc4;0x18];
  env.stack_depth <- env.stack_depth - 24
let runtime_message output span message =
  let label = fresh "runtime_message" in
  let text = Printf.sprintf "%s:%d:%d: xen runtime error: %s\n"
    span.file span.line span.column message in
  M.add_rodata output label text;
  label, String.length text

let emit_error_stub output span message =
  let label = fresh "runtime_error" in
  let after = fresh "runtime_error_after" in
  let constant, length = runtime_message output span message in
  M.branch output [0xe9] after;
  M.label output label;
  M.bytes output [0xbf;0x02;0x00;0x00;0x00;0x48;0x8d;0x35];
  M.rip_rel32 output M.Rodata constant;
  M.bytes output [0xba]; M.u32 output (Int64.of_int length);
  R.write output; R.exit output 1;
  M.label output after;
  label

let aligned_call env target =
  let padded = env.stack_depth mod 16 <> 0 in
  if padded then M.bytes env.output [0x48;0x83;0xec;0x08];
  M.branch env.output [0xe8] target;
  if padded then M.bytes env.output [0x48;0x83;0xc4;0x08]

let push_rax env = M.u8 env.output 0x50; env.stack_depth <- env.stack_depth + 8
let pop_reg env bytes = M.u8 env.output 0x58; M.bytes env.output bytes; env.stack_depth <- env.stack_depth - 8
let push_xmm0 env =
  M.bytes env.output [0x48;0x83;0xec;0x08;0xf2;0x0f;0x11;0x04;0x24];
  env.stack_depth <- env.stack_depth + 8
let normalize_rax output typ = match T.canonical typ with
  | I8->M.bytes output[0x48;0x0f;0xbe;0xc0]|U8->M.bytes output[0x0f;0xb6;0xc0]
  | I16->M.bytes output[0x48;0x0f;0xbf;0xc0]|U16->M.bytes output[0x0f;0xb7;0xc0]
  | I32->M.bytes output[0x48;0x63;0xc0]|U32->M.bytes output[0x89;0xc0]
  | _->()
let push_float env typ =
  M.bytes env.output [0x48;0x83;0xec;0x08];
  M.bytes env.output (if typ=F32 then [0xf3;0x0f;0x11;0x04;0x24] else [0xf2;0x0f;0x11;0x04;0x24]);
  env.stack_depth<-env.stack_depth+8
let pop_float env typ index =
  let modrm=0x04 lor(index lsl 3) in M.bytes env.output((if typ=F32 then [0xf3;0x0f;0x10]else[0xf2;0x0f;0x10])@[modrm;0x24;0x48;0x83;0xc4;0x08]);env.stack_depth<-env.stack_depth-8

let emit_value env (v:value) =
  let output=env.output and name=v.id in
  if v.typ=Unit then mov_rax_imm output 0L
  else if (match v.typ with Named _->true|_->false)then begin
    let offset=Hashtbl.find env.slots name in
    M.bytes output[0x48;0x8d;0x85];M.u32 output(Int64.of_int(-(offset+aggregate_bias(slot_size v.typ))))
  end else if v.typ=F64 then load_float env name v.span
  else if v.typ=F32 then begin M.bytes output[0xf3;0x0f;0x10;0x85];M.u32 output(Int64.of_int(-Hashtbl.find env.slots name))end
  else if is_pair v.typ then load_ptr env name v.span
  else if is_managed v.typ then load_managed env name v.span
  else if T.is_integer v.typ||v.typ=Bool then load_scalar env v.typ name v.span
  else load_int env name v.span

let emit_exchange_at_address env (result:value) (value:value) =
  let output=env.output in
  push_rax env;
      M.bytes output[0x48;0x89;0xc6;0x48;0x8d;0xbd];M.u32 output(Int64.of_int(-(env.scratch+aggregate_bias(slot_size result.typ))));
      M.bytes output[0xb9];M.u32 output(Int64.of_int(slot_size result.typ));M.bytes output[0xf3;0xa4];
      M.bytes output[0x48;0x8b;0x3c;0x24;0x48;0x8d;0xb5];
      M.u32 output(Int64.of_int(-(Hashtbl.find env.slots value.id+aggregate_bias(slot_size value.typ))));
      M.bytes output[0xb9];M.u32 output(Int64.of_int(slot_size value.typ));M.bytes output[0xf3;0xa4;0x48;0x83;0xc4;8];env.stack_depth<-env.stack_depth-8;
      emit_value env result

let rec emit_rvalue env (expression:value) node =
  let output = env.output in
  match node with
  | Int_lit value -> M.bytes output [0x48;0xb8];M.u64 output value
  | Float_lit value ->
      let label = fresh "float" in
      if expression.typ=F32 then begin
        M.add_rodata_u64 output label(Int64.of_int32(Int32.bits_of_float value));
        M.bytes output[0xf3;0x0f;0x10;0x05]
      end else begin M.add_rodata_u64 output label (Int64.bits_of_float value);M.bytes output [0xf2;0x0f;0x10;0x05] end;
      M.rip_rel32 output M.Rodata label
  | String_lit bytes ->
      if bytes = "" then (mov_rax_imm output 0L; M.bytes output [0x48;0x31;0xd2;0x48;0x31;0xc9])
      else begin
        let label = fresh "string" in M.add_rodata output label bytes;
        M.bytes output [0x48;0x8d;0x05]; M.rip_rel32 output M.Rodata label;
        M.bytes output [0x48;0xc7;0xc2]; M.u32 output (Int64.of_int (String.length bytes));
        M.bytes output [0x48;0x31;0xc9]
      end
  | Bool_lit value -> M.bytes output [0x48;0xb8];M.u64 output (if value then 1L else 0L)
  | Struct_lit (layout,fields) ->
      List.iter(fun((field:struct_field),(v:value))->
        emit_value env v;
        let displacement= -(env.scratch+aggregate_bias layout.size-field.offset)in
        if v.typ=Unit then ()
        else if v.typ=F64||v.typ=F32 then begin M.bytes output[(if v.typ=F32 then 0xf3 else 0xf2);0x0f;0x11;0x85];M.u32 output(Int64.of_int displacement)end
        else if (match v.typ with Named _->true|_->false)then begin
          M.bytes output[0x48;0x89;0xc6;0x48;0x8d;0xbd];M.u32 output(Int64.of_int displacement);
          M.bytes output[0x48;0xc7;0xc1];M.u32 output(Int64.of_int(slot_size v.typ));M.bytes output[0xf3;0xa4]
        end else if is_managed v.typ then begin
          M.bytes output[0x48;0x89;0x85];M.u32 output(Int64.of_int displacement);
          M.bytes output[0x48;0x89;0x95];M.u32 output(Int64.of_int(displacement+8));
          M.bytes output[0x48;0x89;0x8d];M.u32 output(Int64.of_int(displacement+16))
        end else if is_pair v.typ then begin
          M.bytes output[0x48;0x89;0x85];M.u32 output(Int64.of_int displacement);
          M.bytes output[0x48;0x89;0x95];M.u32 output(Int64.of_int(displacement+8))
        end else if T.is_integer v.typ||v.typ=Bool then store_scalar_disp output v.typ displacement
        else begin M.bytes output[0x48;0x89;0x85];M.u32 output(Int64.of_int displacement)end)fields;
      M.bytes output[0x48;0x8d;0x85];M.u32 output(Int64.of_int(-(env.scratch+aggregate_bias layout.size)))
  | Vec_lit values ->
      let stride=element_stride (match values with x::_->x.typ|[]->(match expression.typ with Vec t->t|_->assert false)) in
      List.iter (fun (value:value) ->
        emit_value env value;M.bytes output[0x48;0x81;0xec];M.u32 output(Int64.of_int stride);env.stack_depth<-env.stack_depth+stride;
        if value.typ=Unit then ()
        else if is_float value.typ then M.bytes output((if value.typ=F32 then[0xf3]else[0xf2])@[0x0f;0x11;0x04;0x24])
        else if (match value.typ with Named _->true|_->false) then begin
          M.bytes output[0x48;0x89;0xc6;0x48;0x89;0xe7;0x48;0xc7;0xc1];M.u32 output(Int64.of_int(slot_size value.typ));M.bytes output[0xf3;0xa4]
        end else if is_managed value.typ then M.bytes output[0x48;0x89;0x04;0x24;0x48;0x89;0x54;0x24;8;0x48;0x89;0x4c;0x24;16]
        else (match (descriptor value.typ).size with
          |1->M.bytes output[0x88;0x04;0x24]|2->M.bytes output[0x66;0x89;0x04;0x24]
          |4->M.bytes output[0x89;0x04;0x24]|_->M.bytes output[0x48;0x89;0x04;0x24])) values;
      mov_rax_imm output (Int64.of_int (List.length values)); M.bytes output [0x48;0x89;0xc7;0x48;0xc7;0xc6];M.u32 output(Int64.of_int stride);
      aligned_call env "__xen_vec_new";
      (* Preserve the descriptor while copying staged elements in source order. *)
      descriptor_to_stack env;
      let count = List.length values in
      List.iteri (fun index (value:value) ->
        let displacement = 24 + ((count - 1 - index) * stride) in
        M.bytes output[0x48;0x8b;0x3c;0x24;0x48;0x81;0xc7];M.u32 output(Int64.of_int(index*stride));
        M.bytes output[0x48;0x8d;0xb4;0x24];M.u32 output(Int64.of_int displacement);
        M.bytes output[0x48;0xc7;0xc1];M.u32 output(Int64.of_int(slot_size value.typ));M.bytes output[0xf3;0xa4]) values;
      descriptor_from_stack env;
      if count > 0 then begin M.bytes output [0x48;0x81;0xc4]; M.u32 output (Int64.of_int (count*stride)); env.stack_depth<-env.stack_depth-count*stride end
  | File_is_open target ->
      emit_value env target; M.bytes output [0x48;0x83;0x38;0x00;0x0f;0x9d;0xc0;0x48;0x0f;0xb6;0xc0]
  | File_close target ->
      emit_value env target; M.bytes output [0x48;0x89;0xc2;0x48;0x8b;0x38;0x48;0x85;0xff];
      let done_=fresh "file_close_done" and error=emit_error_stub output expression.span "file close failed" in
      M.branch output [0x0f;0x88] done_; M.bytes output [0x48;0xc7;0x02;0xff;0xff;0xff;0xff]; R.close output; M.bytes output [0x48;0x3d;0x01;0xf0;0xff;0xff];
      M.branch output [0x0f;0x83] error; M.label output done_; mov_rax_imm output 0L
  | File_read target ->
      emit_value env target; M.bytes output [0x48;0x8b;0x38;0x48;0x85;0xff];
      let closed=emit_error_stub output expression.span "File is closed" and failed=emit_error_stub output expression.span "file read failed" in
      M.branch output [0x0f;0x88] closed; aligned_call env "__xen_file_read";
      M.bytes output [0x48;0x83;0xf9;0xff]; M.branch output [0x0f;0x84] failed
  | File_write (target,value) ->
      emit_value env target; M.bytes output [0x48;0x8b;0x38;0x48;0x85;0xff];
      let closed=emit_error_stub output expression.span "File is closed" and failed=emit_error_stub output expression.span "file write failed" in
      M.branch output [0x0f;0x88] closed; M.bytes output [0x48;0x89;0xf8]; push_rax env; emit_value env value; descriptor_to_stack env;
      M.bytes output [0x48;0x8b;0x7c;0x24;0x18;0x48;0x89;0xc6]; aligned_call env "__xen_file_write";
      push_rax env;
      pop_reg env []; M.bytes output [0x48;0x83;0xc4;0x20]; env.stack_depth<-env.stack_depth-32;
      M.bytes output [0x48;0x85;0xc0]; M.branch output [0x0f;0x88] failed; mov_rax_imm output 0L
  | Index (receiver, index) | Vec_get (receiver, index) ->
      emit_value env receiver; descriptor_to_stack env; emit_value env index;
      let error=emit_error_stub output expression.span "vector index out of bounds" in
      M.bytes output [0x48;0x85;0xc0]; M.branch output [0x0f;0x88] error;
      M.bytes output [0x48;0x3b;0x44;0x24;0x08]; M.branch output [0x0f;0x83] error;
      M.bytes output [0x48;0x8b;0x14;0x24;0x48;0x69;0xc0];M.u32 output(Int64.of_int(element_stride expression.typ));M.bytes output[0x48;0x01;0xd0];
      if expression.typ=F64 then M.bytes output [0xf2;0x0f;0x10;0x00]
      else if expression.typ=F32 then M.bytes output [0xf3;0x0f;0x10;0x00]
      else if expression.typ=String then (M.bytes output[0x48;0x89;0xc7];aligned_call env "__xen_string_clone")
      else if (match expression.typ with Vec _->true|_->false) then begin M.bytes output[0x48;0x89;0xc7];prepare_vec_stride output expression.typ;aligned_call env(clone_runtime expression.typ)end
      else if (match expression.typ with Named _->true|_->false) then begin
        let size=slot_size expression.typ in M.bytes output[0x48;0x89;0xc6;0x48;0x8d;0xbd];M.u32 output(Int64.of_int(-(env.scratch+aggregate_bias size)););
        M.bytes output[0x48;0xc7;0xc1];M.u32 output(Int64.of_int size);M.bytes output[0xf3;0xa4];
        let rec leaves prefix=function Named n->let l=Hashtbl.find layouts n in List.concat_map(fun f->leaves(prefix+f.offset)f.typ)l.fields|(String|Vec _|File|Box _)as t->[prefix,t]|_->[] in
        List.iter(fun(off,t)->if t<>File && (match t with Box _->false|_->true)then begin M.bytes output[0x48;0x8d;0xbd];M.u32 output(Int64.of_int(-(env.scratch+size-8)+off));prepare_vec_stride output t;aligned_call env(clone_runtime t);
          M.bytes output[0x48;0x89;0x85];M.u32 output(Int64.of_int(-(env.scratch+size-8)+off));M.bytes output[0x48;0x89;0x95];M.u32 output(Int64.of_int(-(env.scratch+size-8)+off+8));M.bytes output[0x48;0x89;0x8d];M.u32 output(Int64.of_int(-(env.scratch+size-8)+off+16))end)(leaves 0 expression.typ);
        M.bytes output[0x48;0x8d;0x85];M.u32 output(Int64.of_int(-(env.scratch+aggregate_bias size)))
      end
      else if T.is_integer expression.typ||expression.typ=Bool||expression.typ=File then load_scalar_ptr output expression.typ
      else unsupported ~span:expression.span("native Vec get is not implemented for "^string_of_typ expression.typ);

      M.bytes output [0x48;0x83;0xc4;0x18]; env.stack_depth<-env.stack_depth-24
  | Slice_make (receiver,start,finish) ->
      emit_value env receiver;descriptor_to_stack env;emit_value env start;push_rax env;emit_value env finish;
      let error=emit_error_stub output expression.span "slice range out of bounds" in
      M.bytes output[0x48;0x85;0xc0];M.branch output[0x0f;0x88]error;
      M.bytes output[0x48;0x3b;0x44;0x24;0x10];M.branch output[0x0f;0x87]error;
      M.bytes output[0x48;0x8b;0x0c;0x24;0x48;0x85;0xc9];M.branch output[0x0f;0x88]error;
      M.bytes output[0x48;0x39;0xc1];M.branch output[0x0f;0x87]error;
      (* Vec's current scalar storage lane is eight bytes; Slice shares that physical stride. *)
      let stride=match expression.typ with Slice t->element_stride t|_->assert false in
      M.bytes output[0x48;0x29;0xc8;0x48;0x89;0xc2;0x48;0x8b;0x44;0x24;8;0x48;0x69;0xc9];M.u32 output(Int64.of_int stride);M.bytes output[0x48;0x01;0xc8;0x48;0x83;0xc4;0x20];env.stack_depth<-env.stack_depth-32
  | Slice_len receiver ->
      emit_value env receiver;M.bytes output[0x48;0x89;0xd0]
  | Slice_get(receiver,index) ->
      emit_value env receiver;M.bytes output[0x48;0x83;0xec;0x10;0x48;0x89;0x04;0x24;0x48;0x89;0x54;0x24;8];env.stack_depth<-env.stack_depth+16;
      emit_value env index;let error=emit_error_stub output expression.span "slice index out of bounds" in
      M.bytes output[0x48;0x85;0xc0];M.branch output[0x0f;0x88]error;M.bytes output[0x48;0x3b;0x44;0x24;8];M.branch output[0x0f;0x83]error;
      let stride=element_stride expression.typ in
      M.bytes output[0x48;0x69;0xc0];M.u32 output(Int64.of_int stride);M.bytes output[0x48;0x03;0x04;0x24];
      if expression.typ=F64 then M.bytes output[0xf2;0x0f;0x10;0x00] else if expression.typ=F32 then M.bytes output[0xf3;0x0f;0x10;0x00]
      else if T.is_integer expression.typ||expression.typ=Bool then load_scalar_ptr output expression.typ
      else if expression.typ=String then begin M.bytes output[0x48;0x89;0xc7];aligned_call env "__xen_string_clone" end
      else if (match expression.typ with Vec _->true|_->false) then begin M.bytes output[0x48;0x89;0xc7];prepare_vec_stride output expression.typ;aligned_call env(clone_runtime expression.typ)end
      else if (match expression.typ with Named _->true|_->false) then begin
        let size=slot_size expression.typ in M.bytes output[0x48;0x89;0xc6;0x48;0x8d;0xbd];M.u32 output(Int64.of_int(-(env.scratch+aggregate_bias size)));
        M.bytes output[0x48;0xc7;0xc1];M.u32 output(Int64.of_int size);M.bytes output[0xf3;0xa4];
        let rec leaves prefix=function Named n->let l=Hashtbl.find layouts n in List.concat_map(fun f->leaves(prefix+f.offset)f.typ)l.fields|(String|Vec _|File|Box _)as t->[prefix,t]|_->[] in
        List.iter(fun(off,t)->if t<>File && (match t with Box _->false|_->true)then begin M.bytes output[0x48;0x8d;0xbd];M.u32 output(Int64.of_int(-(env.scratch+size-8)+off));prepare_vec_stride output t;aligned_call env(clone_runtime t);M.bytes output[0x48;0x89;0x85];M.u32 output(Int64.of_int(-(env.scratch+size-8)+off));M.bytes output[0x48;0x89;0x95];M.u32 output(Int64.of_int(-(env.scratch+size-8)+off+8));M.bytes output[0x48;0x89;0x8d];M.u32 output(Int64.of_int(-(env.scratch+size-8)+off+16))end)(leaves 0 expression.typ);
        M.bytes output[0x48;0x8d;0x85];M.u32 output(Int64.of_int(-(env.scratch+aggregate_bias size)))
      end
      else unsupported ~span:expression.span("Slice get is not implemented for "^string_of_typ expression.typ);
      M.bytes output[0x48;0x83;0xc4;0x10];env.stack_depth<-env.stack_depth-16
  | Vec_len receiver -> emit_value env receiver;descriptor_to_stack env;M.bytes output [0x48;0x8b;0x44;0x24;8];

      M.bytes output [0x48;0x83;0xc4;0x18];env.stack_depth<-env.stack_depth-24
  | Vec_set (target,index,value) ->
      let stride=element_stride value.typ in emit_value env target;push_rax env;emit_value env index;push_rax env;emit_value env value;
      M.bytes output[0x48;0x81;0xec];M.u32 output(Int64.of_int stride);env.stack_depth<-env.stack_depth+stride;
      if value.typ=Unit then ()
      else if is_float value.typ then M.bytes output((if value.typ=F32 then[0xf3]else[0xf2])@[0x0f;0x11;0x04;0x24])
      else if (match value.typ with Named _->true|_->false) then begin M.bytes output[0x48;0x89;0xc6;0x48;0x89;0xe7;0x48;0xc7;0xc1];M.u32 output(Int64.of_int(slot_size value.typ));M.bytes output[0xf3;0xa4]end
      else if is_managed value.typ then M.bytes output[0x48;0x89;0x04;0x24;0x48;0x89;0x54;0x24;8;0x48;0x89;0x4c;0x24;16]
      else (match (descriptor value.typ).size with 1->M.bytes output[0x88;0x04;0x24]|2->M.bytes output[0x66;0x89;0x04;0x24]|4->M.bytes output[0x89;0x04;0x24]|_->M.bytes output[0x48;0x89;0x04;0x24]);
      let error=emit_error_stub output expression.span "vector index out of bounds" in
      M.bytes output[0x48;0x8b;0x84;0x24];M.u32 output(Int64.of_int stride);M.bytes output[0x48;0x85;0xc0];M.branch output[0x0f;0x88]error;
      M.bytes output[0x48;0x8b;0xbc;0x24];M.u32 output(Int64.of_int(stride+8));M.bytes output[0x48;0x3b;0x47;8];M.branch output[0x0f;0x83]error;
      M.bytes output[0x48;0x69;0xc0];M.u32 output(Int64.of_int stride);M.bytes output[0x48;0x03;0x07];push_rax env;
      if value.typ=File then begin M.bytes output[0x48;0x8b;0x38;0x48;0x85;0xff];let skip=fresh"vec_set_closed_file" in M.branch output[0x0f;0x88]skip;R.close output;M.label output skip end
      else if (match value.typ with Named _->true|_->false) then begin
        let rec leaves prefix=function Named n->let l=Hashtbl.find layouts n in List.concat_map(fun f->leaves(prefix+f.offset)f.typ)l.fields|(String|Vec _|File|Box _)as t->[prefix,t]|_->[] in
        List.iter(fun(off,t)->M.bytes output[0x48;0x8b;0x3c;0x24];if off<>0 then(M.bytes output[0x48;0x81;0xc7];M.u32 output(Int64.of_int off));
          if t=File then begin M.bytes output[0x48;0x8b;0x3f;0x48;0x85;0xff];let skip=fresh"vec_set_named_file" in M.branch output[0x0f;0x88]skip;R.close output;M.label output skip end
          else aligned_call env(drop_runtime t))(List.rev(leaves 0 value.typ))
      end
      else if is_owned value.typ && (match value.typ with Named _->false|_->true) then begin M.bytes output[0x48;0x89;0xc7];aligned_call env(drop_runtime value.typ)end;
      M.bytes output[0x48;0x8b;0x3c;0x24;0x48;0x8d;0x74;0x24;8;0x48;0xc7;0xc1];M.u32 output(Int64.of_int(slot_size value.typ));M.bytes output[0xf3;0xa4;0x48;0x83;0xc4;8];env.stack_depth<-env.stack_depth-8;
      M.bytes output[0x48;0x81;0xc4];M.u32 output(Int64.of_int(stride+16));env.stack_depth<-env.stack_depth-stride-16;mov_rax_imm output 0L
  | Vec_push (target,value) ->
      let stride=element_stride value.typ in emit_value env target;push_rax env;emit_value env value;
      M.bytes output[0x48;0x81;0xec];M.u32 output(Int64.of_int stride);env.stack_depth<-env.stack_depth+stride;
      if value.typ=Unit then ()
      else if is_float value.typ then M.bytes output((if value.typ=F32 then[0xf3]else[0xf2])@[0x0f;0x11;0x04;0x24])
      else if (match value.typ with Named _->true|_->false) then begin M.bytes output[0x48;0x89;0xc6;0x48;0x89;0xe7;0x48;0xc7;0xc1];M.u32 output(Int64.of_int(slot_size value.typ));M.bytes output[0xf3;0xa4]end
      else if is_managed value.typ then M.bytes output[0x48;0x89;0x04;0x24;0x48;0x89;0x54;0x24;8;0x48;0x89;0x4c;0x24;16]
      else (match (descriptor value.typ).size with 1->M.bytes output[0x88;0x04;0x24]|2->M.bytes output[0x66;0x89;0x04;0x24]|4->M.bytes output[0x89;0x04;0x24]|_->M.bytes output[0x48;0x89;0x04;0x24]);
      M.bytes output[0x48;0x89;0xe6;0x48;0x8b;0xbc;0x24];M.u32 output(Int64.of_int stride);M.bytes output[0x48;0xc7;0xc2];M.u32 output(Int64.of_int stride);
      aligned_call env "__xen_vec_push";M.bytes output[0x48;0x81;0xc4];M.u32 output(Int64.of_int(stride+8));env.stack_depth<-env.stack_depth-stride-8;mov_rax_imm output 0L
  | Vec_pop target ->
      emit_value env target;M.bytes output [0x48;0x89;0xc7];
      let error=emit_error_stub output expression.span "cannot pop from an empty vector" in
      M.bytes output [0x48;0x83;0x7f;0x08;0x00];M.branch output [0x0f;0x84] error;
      if expression.typ=Unit then begin M.bytes output[0x48;0xff;0x4f;8];mov_rax_imm output 0L end
      else if (match expression.typ with Named _->true|_->false) then begin M.bytes output[0x48;0xff;0x4f;8;0x48;0x8b;0x47;8;0x48;0x69;0xc0];M.u32 output(Int64.of_int(element_stride expression.typ));M.bytes output[0x48;0x03;0x07]end
      else if is_managed expression.typ then begin M.bytes output[0x48;0xc7;0xc6];M.u32 output(Int64.of_int(element_stride expression.typ));aligned_call env "__xen_vec_pop" end
      else begin
        M.bytes output[0x48;0xff;0x4f;8;0x48;0x8b;0x47;8;0x48;0x69;0xc0];M.u32 output(Int64.of_int(element_stride expression.typ));
        M.bytes output[0x48;0x03;0x07];load_scalar_ptr output expression.typ
      end;
      if expression.typ=F64 then M.bytes output [0x66;0x48;0x0f;0x6e;0xc0] else if expression.typ=F32 then M.bytes output[0x66;0x0f;0x6e;0xc0]
      else normalize_rax output expression.typ
  | Exchange(target,value) ->
      emit_value env target;emit_exchange_at_address env expression value
  | Vec_replace(target,index,value) ->
      emit_value env target;push_rax env;emit_value env index;
      let error=emit_error_stub output expression.span "vector index out of bounds"in
      M.bytes output[0x48;0x8b;0x14;0x24;0x48;0x85;0xc0];M.branch output[0x0f;0x88]error;
      M.bytes output[0x48;0x3b;0x42;8];M.branch output[0x0f;0x83]error;
      M.bytes output[0x48;0x69;0xc0];M.u32 output(Int64.of_int(element_stride expression.typ));
      M.bytes output[0x48;0x03;0x02;0x48;0x83;0xc4;8];env.stack_depth<-env.stack_depth-8;
      emit_exchange_at_address env expression value
  | Vec_swap(target,left,right) ->
      let element=match target.typ with Ref(true,Vec t)->t|_->assert false in
      let error=emit_error_stub output expression.span "vector index out of bounds" in
      emit_value env target;push_rax env;
      let address index displacement =
        emit_value env index;M.bytes output[0x48;0x8b;0x54;0x24;displacement;0x48;0x85;0xc0];M.branch output[0x0f;0x88]error;
        M.bytes output[0x48;0x3b;0x42;8];M.branch output[0x0f;0x83]error;
        M.bytes output[0x48;0x69;0xc0];M.u32 output(Int64.of_int(element_stride element));M.bytes output[0x48;0x03;0x02]in
      address left 0;push_rax env;address right 8;
      M.bytes output[0x48;0x89;0xc6;0x48;0x8b;0x3c;0x24;0xb9];M.u32 output(Int64.of_int(slot_size element));
      let loop=fresh "vec_swap_bytes" and done_=fresh "vec_swap_done" in
      M.label output loop;M.bytes output[0x48;0x85;0xc9];M.branch output[0x0f;0x84]done_;
      M.bytes output[0x8a;0x17;0x44;0x8a;0x06;0x44;0x88;0x07;0x88;0x16;0x48;0xff;0xc7;0x48;0xff;0xc6;0x48;0xff;0xc9];M.branch output[0xe9]loop;
      M.label output done_;M.bytes output[0x48;0x83;0xc4;16];env.stack_depth<-env.stack_depth-16;mov_rax_imm output 0L
  | Unary ("+", value) -> emit_value env value
  | Unary ("~", value) -> emit_value env value; M.bytes output [0x48;0xf7;0xd0];normalize_rax output expression.typ
  | Unary ("-", value) when expression.typ = F32 ->
      emit_value env value;M.bytes output[0x66;0x0f;0x7e;0xc0;0x35;0;0;0;0x80;0x66;0x0f;0x6e;0xc0]
  | Unary ("-", value) when expression.typ = F64 ->
      emit_value env value;
      M.bytes output [0x66;0x48;0x0f;0x7e;0xc0;0x48;0x0f;0xba;0xf8;0x3f;0x66;0x48;0x0f;0x6e;0xc0]
  | Unary ("-", value) -> emit_value env value; M.bytes output [0x48;0xf7;0xd8];normalize_rax output expression.typ
  | Unary ("!", value) ->
      emit_value env value; M.bytes output [0x48;0x85;0xc0;0x0f;0x94;0xc0;0x48;0x0f;0xb6;0xc0]
  | Unary (operator, _) -> unsupported ~span:expression.span ("unsupported unary operator '" ^ operator ^ "'")
  | Binary (operator, left, right) ->
      if left.typ = String && operator = "+" then begin
        emit_value env left; descriptor_to_stack env; emit_value env right; descriptor_to_stack env;
        M.bytes output [0x48;0x89;0xe6;0x48;0x8d;0x7c;0x24;0x18]; aligned_call env "__xen_string_concat";
        descriptor_to_stack env;


        descriptor_from_stack env; M.bytes output [0x48;0x83;0xc4;0x30]; env.stack_depth <- env.stack_depth - 48
      end else if is_managed left.typ then begin
        emit_value env left;
        M.bytes output [0x48;0x83;0xec;0x18;0x48;0x89;0x04;0x24;0x48;0x89;0x54;0x24;0x08;0x48;0x89;0x4c;0x24;0x10];
        env.stack_depth <- env.stack_depth + 24;
        emit_value env right;
        M.bytes output [0x48;0x83;0xec;0x18;0x48;0x89;0x04;0x24;0x48;0x89;0x54;0x24;0x08;0x48;0x89;0x4c;0x24;0x10;0x48;0x89;0xe6;0x48;0x8d;0x7c;0x24;0x18];
        env.stack_depth <- env.stack_depth + 24;
        if left.typ<>String then (match left.typ with Vec(Vec t)->M.bytes output[0x48;0xc7;0xc2];M.u32 output(Int64.of_int(element_stride t))|Vec t->M.bytes output[0x48;0xc7;0xc2];M.u32 output(Int64.of_int(element_stride t))|_->());
        aligned_call env (if left.typ=String then "__xen_string_equal" else vec_equal_runtime left.typ);
        M.u8 output 0x50;env.stack_depth<-env.stack_depth+8;


        M.u8 output 0x58;env.stack_depth<-env.stack_depth-8;M.bytes output [0x48;0x83;0xc4;0x30]; env.stack_depth <- env.stack_depth - 48;
        if operator = "!=" then M.bytes output [0x48;0x83;0xf0;0x01]
      end else if is_float left.typ then begin
        let p=if left.typ=F32 then 0xf3 else 0xf2 in
        emit_value env left; push_float env left.typ; emit_value env right;
        pop_float env left.typ 1;
        (match operator with
         | "+" -> M.bytes output [p;0x0f;0x58;0xc8]
         | "-" -> M.bytes output [p;0x0f;0x5c;0xc8]
         | "*" -> M.bytes output [p;0x0f;0x59;0xc8]
         | "/" -> M.bytes output [p;0x0f;0x5e;0xc8]
         | ("==" | "!=" | "<" | "<=" | ">" | ">=") as comparison ->
             M.bytes output ((if left.typ=F32 then []else[0x66])@[0x0f;0x2e;0xc8]);
             let ordered = fresh "float_ordered" and done_ = fresh "float_compare_done" in
             M.branch output [0x0f;0x8b] ordered;
             mov_rax_imm output (if comparison = "!=" then 1L else 0L);
             M.branch output [0xe9] done_; M.label output ordered;
             let condition = match comparison with
               | "==" -> 0x94 | "!=" -> 0x95 | "<" -> 0x92
               | "<=" -> 0x96 | ">" -> 0x97 | _ -> 0x93 in
             M.bytes output [0x0f;condition;0xc0;0x48;0x0f;0xb6;0xc0]; M.label output done_
         | _ -> unsupported ~span:expression.span ("unsupported Float operator '" ^ operator ^ "'"));
        if is_float expression.typ then M.bytes output [0x0f;0x28;0xc1]
      end else begin
      emit_value env left; push_rax env; emit_value env right;
      M.bytes output [0x48;0x89;0xc1]; pop_reg env [];
      (match operator with
       | "+" -> M.bytes output [0x48;0x01;0xc8];normalize_rax output expression.typ
       | "-" -> M.bytes output [0x48;0x29;0xc8];normalize_rax output expression.typ
       | "*" -> M.bytes output [0x48;0x0f;0xaf;0xc1];normalize_rax output expression.typ
       | "**" ->
           if T.is_signed_int left.typ then begin
             let invalid=emit_error_stub output expression.span "negative integer exponent" in
             M.bytes output [0x48;0x85;0xc9];M.branch output [0x0f;0x88]invalid
           end;
           let loop=fresh "power_loop" and skip=fresh "power_skip" and done_=fresh "power_done" in
           M.bytes output [0xba;1;0;0;0];M.label output loop;
           M.bytes output [0x48;0x85;0xc9];M.branch output [0x0f;0x84]done_;
           M.bytes output [0xf6;0xc1;1];M.branch output [0x0f;0x84]skip;
           M.bytes output [0x48;0x0f;0xaf;0xd0];M.label output skip;
           M.bytes output [0x48;0x0f;0xaf;0xc0;0x48;0xd1;0xe9];M.branch output [0xe9]loop;
           M.label output done_;M.bytes output [0x48;0x89;0xd0];normalize_rax output expression.typ
       | "&"|"|"|"^" ->
           let opcode=match operator with "&"->0x21|"|"->0x09|_->0x31 in
           M.bytes output [0x48;opcode;0xc8];normalize_rax output expression.typ
       | "<<"|">>" ->
           let invalid=emit_error_stub output expression.span "shift count out of range" in
           (* Unsigned comparison rejects negative counts and full-width U64
              counts before the CPU can mask them. *)
           M.bytes output [0x48;0x83;0xf9;T.bits left.typ];M.branch output [0x0f;0x83] invalid;
           let opcode=if operator="<<"then 0xe0 else if T.is_signed_int left.typ then 0xf8 else 0xe8 in
           M.bytes output [0x48;0xd3;opcode];normalize_rax output expression.typ
       | "/" ->
           let ok = fresh "div_ok" and error_zero = emit_error_stub output expression.span "division by zero"
           and error_overflow = emit_error_stub output expression.span "signed division overflow" in
           M.bytes output [0x48;0x85;0xc9]; M.branch output [0x0f;0x84] error_zero;
           if T.is_unsigned_int left.typ then M.bytes output[0x48;0x31;0xd2;0x48;0xf7;0xf1]
           else begin M.bytes output [0x48;0xba]; M.u64 output(T.min_signed(T.bits left.typ));
             M.bytes output [0x48;0x39;0xd0]; M.branch output [0x0f;0x85] ok;
             M.bytes output [0x48;0x83;0xf9;0xff]; M.branch output [0x0f;0x84] error_overflow;
             M.label output ok; M.bytes output [0x48;0x99;0x48;0xf7;0xf9] end;normalize_rax output expression.typ
       | "%" ->
           let divide = fresh "rem_divide" and error_zero = emit_error_stub output expression.span "remainder by zero"
           and error_overflow=emit_error_stub output expression.span "signed remainder overflow" in
           M.bytes output [0x48;0x85;0xc9]; M.branch output [0x0f;0x84] error_zero;
           if T.is_unsigned_int left.typ then M.bytes output[0x48;0x31;0xd2;0x48;0xf7;0xf1;0x48;0x89;0xd0]
           else begin M.bytes output [0x48;0xba]; M.u64 output(T.min_signed(T.bits left.typ));
             M.bytes output [0x48;0x39;0xd0]; M.branch output [0x0f;0x85] divide;
             M.bytes output [0x48;0x83;0xf9;0xff]; M.branch output [0x0f;0x84] error_overflow;
             M.label output divide; M.bytes output [0x48;0x99;0x48;0xf7;0xf9;0x48;0x89;0xd0] end;normalize_rax output expression.typ
       | ("==" | "!=" | "<" | "<=" | ">" | ">=") as comparison ->
           M.bytes output [0x48;0x39;0xc8];
           let unsigned=T.is_unsigned_int left.typ in
           let condition = match comparison,unsigned with
             | "==",_ -> 0x94 | "!=",_ -> 0x95 | "<",true -> 0x92 | "<=",true->0x96
             | ">",true->0x97 | ">=",true->0x93 | "<",false -> 0x9c
             | "<=",false -> 0x9e | ">",false -> 0x9f | _ -> 0x9d
           in M.bytes output [0x0f;condition;0xc0;0x48;0x0f;0xb6;0xc0]
       | _ -> unsupported ~span:expression.span ("unsupported binary operator '" ^ operator ^ "'")) end
  | Call (("print" | "println" as name), [argument]) ->
      emit_value env argument;
      if argument.typ = String then begin

        M.bytes output [0x48;0x89;0xc6;0x48;0x89;0xd2;0xbf;0x01;0x00;0x00;0x00]; R.write output
      end else if is_managed argument.typ then begin
        descriptor_to_stack env; M.bytes output [0x48;0x89;0xe7];
        aligned_call env (if argument.typ=Vec F64 then "__xen_print_vec_float" else "__xen_print_vec_int");

        M.bytes output [0x48;0x83;0xc4;0x18];env.stack_depth<-env.stack_depth-24
      end else begin
        if argument.typ=F32 then M.bytes output[0xf3;0x0f;0x5a;0xc0]
        else if argument.typ <> F64 then M.bytes output [0x48;0x89;0xc7];
        M.bytes output [0x41;0xbf;1;0;0;0];
        if is_float argument.typ then begin
          (* The float runtime intentionally prints a compact mantissa.  Retain
             the original value across the call so integral finite values can
             keep their floating-point spelling (for example, 1.0 not 1). *)
          push_xmm0 env;
          aligned_call env "__xen_print_float";
          M.bytes output [0xf2;0x0f;0x10;0x04;0x24;0x48;0x83;0xc4;0x08];
          env.stack_depth <- env.stack_depth - 8;
          M.bytes output [0xf2;0x48;0x0f;0x2c;0xc0;0xf2;0x48;0x0f;0x2a;0xc8;0x66;0x0f;0x2e;0xc1];
          let not_integral=fresh "float_not_integral" in
          M.branch output [0x0f;0x8a] not_integral; M.branch output [0x0f;0x85] not_integral;
          M.bytes output [0xbf;1;0;0;0;0x48;0x8d;0x35]; M.rip_rel32 output M.Rodata "__xen_decimal_suffix";
          M.bytes output [0xba;0x02;0x00;0x00;0x00]; R.write output;
          M.label output not_integral
        end else
          aligned_call env (if argument.typ = Bool then "__xen_print_bool" else if T.is_unsigned_int argument.typ then "__xen_print_uint" else "__xen_print_int")
      end;
      if name = "println" then begin
        M.bytes output [0xbf;1;0;0;0;0x48;0x8d;0x35]; M.rip_rel32 output M.Rodata "__xen_newline";
        M.bytes output [0xba;0x01;0x00;0x00;0x00]; R.write output
      end;
      mov_rax_imm output 0L
  | Call ("len", [argument]) ->
      emit_value env argument;descriptor_to_stack env;M.bytes output [0x48;0x8b;0x44;0x24;8];

      M.bytes output [0x48;0x83;0xc4;0x18];env.stack_depth<-env.stack_depth-24
  | Call ("arg_count", []) -> M.bytes output [0x48;0x8b;0x05]; M.rip_rel32 output M.Data "__xen_argc"
  | Call ("arg", [argument]) ->
      emit_value env argument; M.bytes output [0x48;0x89;0xc7]; aligned_call env "__xen_arg"
  | Call (("open_read" | "open_write" as name), [path]) ->
      emit_value env path; descriptor_to_stack env;
      M.bytes output [0x48;0x89;0xc7;0x48;0x89;0xd6;0xba];
      M.u32 output (Int64.of_int(if name="open_read" then R.open_read_flags else R.open_write_flags)); aligned_call env "__xen_file_open";
      push_rax env;
      pop_reg env []; M.bytes output [0x48;0x83;0xc4;0x18]; env.stack_depth<-env.stack_depth-24;
      let nul=emit_error_stub output expression.span "file path contains an embedded NUL" and failed=emit_error_stub output expression.span "file open failed" and ok=fresh "file_open_ok" in
      M.bytes output [0x48;0x3d;0x00;0xf0;0xff;0xff]; M.branch output [0x0f;0x84] nul;
      M.bytes output [0x48;0x85;0xc0]; M.branch output [0x0f;0x89] ok; M.branch output [0xe9] failed; M.label output ok
  | Call ("assert", [argument]) ->
      emit_value env argument; M.bytes output [0x48;0x85;0xc0];
      let ok = fresh "assert_ok" in M.branch output [0x0f;0x85] ok; aligned_call env "__xen_assert_fail"; M.label output ok; mov_rax_imm output 0L
  | Call ("panic", [message]) ->
      emit_value env message; M.bytes output [0x48;0x89;0xc6;0x48;0x89;0xd2]; aligned_call env "__xen_panic"
  | Call ("assert_msg", [condition; message]) ->
      emit_value env condition; let ok = fresh "assert_msg_ok" in
      M.bytes output [0x48;0x85;0xc0]; M.branch output [0x0f;0x85] ok;
      emit_value env message; M.bytes output [0x48;0x89;0xc6;0x48;0x89;0xd2]; aligned_call env "__xen_assert_msg_fail";
      M.label output ok; mov_rax_imm output 0L
  | Call ("float", [argument]) ->
      emit_value env argument; M.bytes output [0xf2;0x48;0x0f;0x2a;0xc0]
  | Call ("$inactive_pair", []) ->
      M.bytes output [0x48;0x31;0xc0;0x48;0x31;0xd2]
  | Call ("$vec_into_string", [value]) ->
      emit_value env value;descriptor_to_stack env;M.bytes output[0x48;0x89;0xe7];aligned_call env "__xen_vec_into_string";
      M.bytes output[0x48;0x83;0xc4;0x18];env.stack_depth<-env.stack_depth-24
  | Call ("int", [argument]) ->
      emit_value env argument;
      let error = emit_error_stub output expression.span "Float cannot be converted to Int" in
      M.bytes output [0x66;0x0f;0x2e;0xc0]; M.branch output [0x0f;0x8a] error;
      let lower = fresh "int_lower" and upper = fresh "int_upper" in
      M.add_rodata_u64 output lower (Int64.bits_of_float (-9223372036854775808.0));
      M.add_rodata_u64 output upper (Int64.bits_of_float 9223372036854775808.0);
      M.bytes output [0xf2;0x0f;0x10;0x0d]; M.rip_rel32 output M.Rodata lower;
      M.bytes output [0x66;0x0f;0x2e;0xc1]; M.branch output [0x0f;0x82] error;
      M.bytes output [0xf2;0x0f;0x10;0x0d]; M.rip_rel32 output M.Rodata upper;
      M.bytes output [0x66;0x0f;0x2e;0xc1]; M.branch output [0x0f;0x83] error;
      M.bytes output [0xf2;0x48;0x0f;0x2c;0xc0]
  | Call ("$math$bits_u64",[argument]) ->
      emit_value env argument;M.bytes output[0x66;0x48;0x0f;0x7e;0xc0]
  | Call ("$math$bits_f64",[argument]) ->
      emit_value env argument;M.bytes output[0x66;0x48;0x0f;0x6e;0xc0]
  | Call ("$math$narrow_f32",[argument]) ->
      emit_value env argument;M.bytes output[0xf2;0x0f;0x5a;0xc0]
  | Call ("$math$sqrt_f64",[argument]) ->
      emit_value env argument;M.bytes output[0xf2;0x0f;0x51;0xc0]
  | Call (name,[argument]) when String.starts_with ~prefix:"__convert_" name ->
      emit_value env argument;
      let target=expression.typ and source=argument.typ in
      let error=emit_error_stub output expression.span ("numeric conversion to "^Ast.string_of_typ target^" failed") in
      if T.is_integer source && T.is_integer target then begin
        if T.is_signed_int target then begin
          let bits=T.bits target in
          if T.is_unsigned_int source then begin
            M.bytes output[0x48;0xb9];M.u64 output(T.max_signed bits);M.bytes output[0x48;0x39;0xc8];M.branch output[0x0f;0x87]error
          end else if bits<64 then begin
            M.bytes output[0x48;0xb9];M.u64 output(T.min_signed bits);M.bytes output[0x48;0x39;0xc8];M.branch output[0x0f;0x8c]error;
            M.bytes output[0x48;0xb9];M.u64 output(T.max_signed bits);M.bytes output[0x48;0x39;0xc8];M.branch output[0x0f;0x8f]error
          end
        end else begin
          if T.is_signed_int source then (M.bytes output[0x48;0x85;0xc0];M.branch output[0x0f;0x88]error);
          if T.bits target<64 then begin M.bytes output[0x48;0xb9];M.u64 output(T.max_unsigned(T.bits target));M.bytes output[0x48;0x39;0xc8];M.branch output[0x0f;0x87]error end
        end;normalize_rax output target
      end else if T.is_integer source && T.is_float target then begin
        let cvt prefix = M.bytes output[prefix;0x48;0x0f;0x2a;0xc0] in
        if T.is_unsigned_int source && T.bits source=64 then begin
          let ordinary=fresh "u64_float_ordinary" and done_=fresh "u64_float_done" in
          M.bytes output[0x48;0x85;0xc0];M.branch output[0x0f;0x89]ordinary;
          M.bytes output[0x48;0x89;0xc1;0x48;0x83;0xe1;1;0x48;0xd1;0xe8;0x48;0x09;0xc8];cvt(if target=F32 then 0xf3 else 0xf2);
          M.bytes output[(if target=F32 then 0xf3 else 0xf2);0x0f;0x58;0xc0];M.branch output[0xe9]done_;M.label output ordinary;cvt(if target=F32 then 0xf3 else 0xf2);M.label output done_
        end else cvt(if target=F32 then 0xf3 else 0xf2)
      end else if T.is_float source && T.is_float target then begin
        if source=F32&&target=F64 then M.bytes output[0xf3;0x0f;0x5a;0xc0]
        else if source=F64&&target=F32 then begin
          M.bytes output[0x66;0x0f;0x2e;0xc0];M.branch output[0x0f;0x8a]error;
          let maxf=fresh "f32_max" and minf=fresh "f32_min" in
          M.add_rodata_u64 output maxf(Int64.bits_of_float 3.4028234663852886e38);M.add_rodata_u64 output minf(Int64.bits_of_float(-3.4028234663852886e38));
          M.bytes output[0xf2;0x0f;0x10;0x0d];M.rip_rel32 output M.Rodata maxf;M.bytes output[0x66;0x0f;0x2e;0xc1];M.branch output[0x0f;0x87]error;
          M.bytes output[0xf2;0x0f;0x10;0x0d];M.rip_rel32 output M.Rodata minf;M.bytes output[0x66;0x0f;0x2e;0xc1];M.branch output[0x0f;0x82]error;
          M.bytes output[0xf2;0x0f;0x5a;0xc0]
        end
      end else if T.is_float source && T.is_integer target then begin
        if source=F32 then M.bytes output[0xf3;0x0f;0x5a;0xc0];
        M.bytes output[0x66;0x0f;0x2e;0xc0];M.branch output[0x0f;0x8a]error;
        let bits=T.bits target in
        let lower,upper=if T.is_signed_int target then Int64.to_float(T.min_signed bits),
          (if bits=64 then 9223372036854775808. else Int64.to_float(Int64.add(T.max_signed bits)1L))
          else 0.,(if bits=64 then 18446744073709551616. else Int64.to_float(Int64.add(T.max_unsigned bits)1L)) in
        let lo=fresh "convert_lower" and hi=fresh "convert_upper" in
        M.add_rodata_u64 output lo(Int64.bits_of_float lower);M.add_rodata_u64 output hi(Int64.bits_of_float upper);
        M.bytes output[0xf2;0x0f;0x10;0x0d];M.rip_rel32 output M.Rodata lo;M.bytes output[0x66;0x0f;0x2e;0xc1];M.branch output[0x0f;0x82]error;
        M.bytes output[0xf2;0x0f;0x10;0x0d];M.rip_rel32 output M.Rodata hi;M.bytes output[0x66;0x0f;0x2e;0xc1];M.branch output[0x0f;0x83]error;
        if target=U64 then begin
          let low=fresh "u64_convert_low" and done_=fresh "u64_convert_done" and two63=fresh "two63" in
          M.add_rodata_u64 output two63(Int64.bits_of_float 9223372036854775808.);M.bytes output[0xf2;0x0f;0x10;0x0d];M.rip_rel32 output M.Rodata two63;
          M.bytes output[0x66;0x0f;0x2e;0xc1];M.branch output[0x0f;0x82]low;M.bytes output[0xf2;0x0f;0x5c;0xc1;0xf2;0x48;0x0f;0x2c;0xc0;0x48;0x0f;0xba;0xe8;0x3f];M.branch output[0xe9]done_;
          M.label output low;M.bytes output[0xf2;0x48;0x0f;0x2c;0xc0];M.label output done_
        end else (M.bytes output[0xf2;0x48;0x0f;0x2c;0xc0];normalize_rax output target)
      end
  | Call ("int_to_str", [argument]) ->
      emit_value env argument; M.bytes output [0x48;0x89;0xc7]; aligned_call env "__xen_int_to_str"
  | Call (("zeros" as name), [count]) ->
      emit_value env count;
      let negative=emit_error_stub output expression.span (name ^ " length cannot be negative") in
      M.bytes output [0x48;0x85;0xc0]; M.branch output [0x0f;0x88] negative;
      M.bytes output [0x48;0x89;0xc7;0xbe;8;0;0;0]; aligned_call env "__xen_vec_new"
  | Call (("repeat" as name), [value;count]) ->
      emit_value env value; if value.typ=F64 then push_xmm0 env else push_rax env;
      emit_value env count;
      let negative=emit_error_stub output expression.span (name ^ " length cannot be negative") in
      M.bytes output [0x48;0x85;0xc0]; M.branch output [0x0f;0x88] negative;
      M.bytes output [0x48;0x89;0xc7;0xbe;8;0;0;0]; aligned_call env "__xen_vec_new";
      descriptor_to_stack env; M.bytes output [0x48;0x8b;0x74;0x24;0x18];
      M.bytes output [0x4c;0x8b;0x14;0x24;0x4c;0x8b;0x5c;0x24;0x08;0x4d;0x31;0xc0];
      let loop=fresh "repeat_fill" and done_=fresh "repeat_done" in
      M.label output loop; M.bytes output [0x4d;0x39;0xd8]; M.branch output [0x0f;0x83] done_;
      M.bytes output [0x4b;0x89;0x34;0xc2;0x49;0xff;0xc0]; M.branch output [0xe9] loop; M.label output done_;
      descriptor_from_stack env; M.bytes output [0x48;0x83;0xc4;0x08]; env.stack_depth<-env.stack_depth-8
  | Call (("read_text"|"read_ints"|"read_floats" as name), [path]) ->
      emit_value env path; descriptor_to_stack env;
      M.bytes output [0x48;0x83;0xec;0x18]; env.stack_depth<-env.stack_depth+24;
      M.bytes output [0x48;0x8b;0x7c;0x24;0x18;0x48;0x8b;0x74;0x24;0x20;0xba];
      M.u32 output (if name="read_text" then 0L else if name="read_ints" then 1L else 2L);
      M.bytes output [0x48;0x89;0xe1]; aligned_call env "__xen_read_builtin";
      push_rax env;

      pop_reg env []; M.bytes output [0x48;0x85;0xc0];
      let ok=fresh "read_builtin_ok" in M.branch output [0x0f;0x84] ok;
      let errors = [1,"file path contains an embedded NUL";2,"file open failed";3,"file read failed";4,"file close failed";
        5,(if name="read_ints" then "invalid integer token" else "invalid float token");
        6,(if name="read_ints" then "integer out of range" else "float out of range");
        7,(if name="read_text" then "string is too large" else "vector is too large");
        8,(if name="read_text" then "string allocation failed" else "vector allocation failed")] in
      List.iter (fun (code,message) -> let next=fresh "read_error_next" in
        M.bytes output [0x48;0x83;0xf8;code]; M.branch output [0x0f;0x85] next;
        M.branch output [0xe9] (emit_error_stub output expression.span message); M.label output next) errors;
      M.label output ok;
      M.bytes output [0x48;0x8b;0x04;0x24;0x48;0x8b;0x54;0x24;0x08;0x48;0x8b;0x4c;0x24;0x10;0x48;0x83;0xc4;0x30];
      env.stack_depth<-env.stack_depth-48
  | Box_new x ->
      let bytes=element_stride x.typ in
      M.bytes output[0xbe];M.u32 output(Int64.of_int bytes);
      R.alloc output;
      let failed=emit_error_stub output expression.span "Box allocation failed"in
      M.bytes output[0x48;0x3d;1;0xf0;0xff;0xff];M.branch output[0x0f;0x83]failed;
      push_rax env;M.bytes output[0x48;0x89;0xc7;0x48;0x8d;0xb5];
      M.u32 output(Int64.of_int(-(Hashtbl.find env.slots x.id+aggregate_bias(slot_size x.typ))));
      M.bytes output[0xb9];M.u32 output(Int64.of_int(slot_size x.typ));M.bytes output[0xf3;0xa4];pop_reg env []
  | Box_take x ->
      emit_value env x;push_rax env;
      M.bytes output[0x48;0x89;0xc6;0x48;0x8d;0xbd];
      M.u32 output(Int64.of_int(-(env.scratch+aggregate_bias(slot_size expression.typ))));
      M.bytes output[0xb9];M.u32 output(Int64.of_int(slot_size expression.typ));M.bytes output[0xf3;0xa4];
      pop_reg env[0x48;0x89;0xc7];M.bytes output[0xbe];M.u32 output(Int64.of_int(element_stride expression.typ));
      R.unmap output;emit_value env expression
  | Raw_alloc (typ, count) ->
      emit_value env count;
      let invalid_count=emit_error_stub output expression.span "raw allocation count must be non-negative"
      and too_large=emit_error_stub output expression.span "raw allocation size overflow"
      and failed=emit_error_stub output expression.span "raw allocation failed"
      and nonzero=fresh "raw_alloc_nonzero" and ok=fresh "raw_alloc_ok" in
      M.bytes output [0x48;0x85;0xc0]; M.branch output [0x0f;0x88] invalid_count; M.branch output [0x0f;0x85] nonzero;
      M.bytes output [0x48;0x31;0xc0;0x48;0x31;0xd2]; M.branch output [0xe9] ok;
      let stride=element_stride typ in
      M.label output nonzero; M.bytes output [0x48;0xb9]; M.u64 output(Int64.div Int64.max_int(Int64.of_int stride));
      M.bytes output [0x48;0x39;0xc8]; M.branch output [0x0f;0x87] too_large;
      push_rax env; M.bytes output [0x48;0x89;0xc6;0x48;0x69;0xf6];M.u32 output(Int64.of_int stride);R.alloc output;
      M.bytes output [0x48;0x3d;0x00;0xf0;0xff;0xff]; M.branch output [0x0f;0x83] failed;
      M.u8 output 0x5a; env.stack_depth<-env.stack_depth-8; M.label output ok
  | Raw_load (typ,pointer,offset) | Volatile_load (typ,pointer,offset) ->
      emit_value env pointer; push_rax env; M.u8 output 0x52; env.stack_depth<-env.stack_depth+8; emit_value env offset;
      let bounds=emit_error_stub output expression.span "raw pointer offset out of bounds" in
      M.bytes output [0x48;0x85;0xc0]; M.branch output [0x0f;0x88] bounds;
      M.bytes output [0x48;0x3b;0x04;0x24]; M.branch output [0x0f;0x83] bounds;
      M.bytes output [0x48;0x8b;0x54;0x24;8;0x48;0x69;0xc0];M.u32 output(Int64.of_int(element_stride typ));M.bytes output[0x48;0x01;0xd0;0x48;0x83;0xc4;0x10];env.stack_depth<-env.stack_depth-16;
      (match typ with
       | F32->M.bytes output[0xf3;0x0f;0x10;0x00]
       | F64->M.bytes output[0xf2;0x0f;0x10;0x00]
       | Named _->let size=slot_size typ in M.bytes output[0x48;0x89;0xc6;0x48;0x8d;0xbd];M.u32 output(Int64.of_int(-(env.scratch+aggregate_bias size)));M.bytes output[0x48;0xc7;0xc1];M.u32 output(Int64.of_int size);M.bytes output[0xf3;0xa4;0x48;0x8d;0x85];M.u32 output(Int64.of_int(-(env.scratch+aggregate_bias size)))
       | _->load_scalar_ptr output typ)
  | Raw_store (typ,pointer,offset,value) | Volatile_store (typ,pointer,offset,value) ->
      emit_value env pointer; push_rax env; M.u8 output 0x52; env.stack_depth<-env.stack_depth+8; emit_value env offset; push_rax env; emit_value env value;
      (match typ with F32|F64->push_float env typ|_->push_rax env);
      let bounds=emit_error_stub output expression.span "raw pointer offset out of bounds" in
      M.bytes output [0x48;0x8b;0x4c;0x24;0x18;0x48;0x8b;0x54;0x24;0x10;0x4c;0x8b;0x44;0x24;0x08;0x4d;0x85;0xc0]; M.branch output [0x0f;0x88] bounds;
      M.bytes output [0x49;0x39;0xd0]; M.branch output [0x0f;0x83] bounds;
      M.bytes output[0x4d;0x69;0xc0];M.u32 output(Int64.of_int(element_stride typ));M.bytes output[0x4a;0x8d;0x3c;0x01];
      (match typ with
       | Named _->M.bytes output[0x48;0x8b;0x34;0x24;0x48;0xc7;0xc1];M.u32 output(Int64.of_int(slot_size typ));M.bytes output[0xf3;0xa4]
       | F32->M.bytes output[0x8b;0x04;0x24;0x89;0x07]
       | F64->M.bytes output[0x48;0x8b;0x04;0x24;0x48;0x89;0x07]
       | _->M.bytes output[0x48;0x8b;0x04;0x24];(match(slot_size typ)with 1->M.bytes output[0x88;0x07]|2->M.bytes output[0x66;0x89;0x07]|4->M.bytes output[0x89;0x07]|_->M.bytes output[0x48;0x89;0x07]));
      M.bytes output [0x48;0x83;0xc4;0x20]; env.stack_depth<-env.stack_depth-32; mov_rax_imm output 0L
  | Raw_free (typ,pointer) ->
      emit_value env pointer; let done_=fresh "raw_free_done" and failed=emit_error_stub output expression.span "raw free failed" in
      M.bytes output [0x48;0x85;0xd2]; M.branch output [0x0f;0x84] done_;
      M.bytes output [0x48;0x89;0xc7;0x48;0x89;0xd6;0x48;0x69;0xf6];M.u32 output(Int64.of_int(element_stride typ));R.unmap output; M.bytes output [0x48;0x85;0xc0]; M.branch output [0x0f;0x88] failed;
      M.label output done_; mov_rax_imm output 0L
  | Ptr_from_addr(typ,address,count)->
      emit_value env address;push_rax env;emit_value env count;
      M.bytes output[0x48;0x89;0xc2];pop_reg env [];
      let invalid=emit_error_stub output expression.span "invalid raw pointer address/count"
      and nonnull=fresh "ptr_nonnull" in
      M.bytes output[0x48;0x85;0xd2];M.branch output[0x0f;0x88]invalid;
      M.bytes output[0x48;0xb9];M.u64 output(Int64.div Int64.max_int(Int64.of_int(element_stride typ)));
      M.bytes output[0x48;0x39;0xca];M.branch output[0x0f;0x87]invalid;
      M.bytes output[0x48;0xa9];M.u32 output(Int64.of_int((descriptor typ).alignment-1));M.branch output[0x0f;0x85]invalid;
      M.bytes output[0x48;0x85;0xc0];M.branch output[0x0f;0x85]nonnull;
      M.bytes output[0x48;0x85;0xd2];M.branch output[0x0f;0x85]invalid;M.label output nonnull;
      M.bytes output[0x48;0x69;0xca];M.u32 output(Int64.of_int(element_stride typ));
      M.bytes output[0x48;0x01;0xc1];M.branch output[0x0f;0x82]invalid
  | Inline_asm(spec,inputs)->
      let module A=Inline_asm in
      let code=try A.assemble ~input_types:(List.map(fun(v:value)->v.typ)inputs)spec with Asm_contract.Error message->unsupported ~span:expression.span message in
      List.iter(fun v->emit_value env v;push_rax env)inputs;
      let n=List.length inputs in
      List.iteri(fun i name->let r=A.register name in
        M.bytes output[if r>=8 then 0x4c else 0x48;0x8b;0x84 lor((r land 7)lsl 3);0x24];
        M.u32 output(Int64.of_int((n-1-i)*8)))spec.input_registers;
      if n>0 then(M.bytes output[0x48;0x81;0xc4];M.u32 output(Int64.of_int(n*8));env.stack_depth<-env.stack_depth-n*8);
      String.iter(fun c->M.u8 output(Char.code c))code;
      (* Capture every output before loading RAX or computing a tuple address. *)
      List.iter(fun(name,_)->let r=A.register name in
        if r>=8 then M.u8 output 0x41;M.u8 output(0x50 lor(r land 7));env.stack_depth<-env.stack_depth+8)spec.output_registers;
      (match spec.output_registers,expression.typ with
       |[],_->mov_rax_imm output 0L
       |[_],_->pop_reg env [];normalize_rax output expression.typ
       |_,Named name->let layout=Hashtbl.find layouts name in
           List.iter(fun(field:struct_field)->pop_reg env [];
             store_scalar_disp output field.typ (-(env.scratch+aggregate_bias layout.size-field.offset)))(List.rev layout.fields);
           M.bytes output[0x48;0x8d;0x85];M.u32 output(Int64.of_int(-(env.scratch+aggregate_bias layout.size)))
       |_->assert false)
  | Cpu_relax->M.bytes output[0xf3;0x90];mov_rax_imm output 0L
  | Memory_fence->M.bytes output[0x0f;0xae;0xf0];mov_rax_imm output 0L
  | Atomic(kind,typ,_,_,pointer::index::values)->
      let width=(descriptor typ).size in
      let invalid=emit_error_stub output expression.span "atomic pointer/index is out of bounds or not naturally aligned"in
      emit_value env pointer;push_rax env;M.u8 output 0x52;env.stack_depth<-env.stack_depth+8;
      emit_value env index;M.bytes output[0x48;0x3b;0x04;0x24];M.branch output[0x0f;0x83]invalid;
      M.bytes output[0x48;0x69;0xc0];M.u32 output(Int64.of_int width);
      M.bytes output[0x48;0x03;0x44;0x24;0x08;0x48;0x83;0xc4;0x10];env.stack_depth<-env.stack_depth-16;
      M.bytes output[0x48;0xa9];M.u32 output(Int64.of_int(width-1));M.branch output[0x0f;0x85]invalid;
      M.bytes output[0x48;0x89;0xc7;0x0f;0xae;0xf0];
      let prefix ()=if width=2 then M.u8 output 0x66 else if width=8 then M.u8 output 0x48 in
      let locked_prefix ()=if width=2 then M.u8 output 0x66;M.u8 output 0xf0;if width=8 then M.u8 output 0x48 in
      let exchange ()=prefix();M.bytes output[if width=1 then 0x86 else 0x87;0x07]in
      let cmpxchg ()=locked_prefix();M.bytes output[0x0f;if width=1 then 0xb0 else 0xb1;0x17]in
      (match kind,values with
       |Atomic_load,[]->M.bytes output[0x48;0x89;0xf8];load_scalar_ptr output typ
       |(Atomic_store|Atomic_exchange),[value]->emit_value env value;exchange()
       |Atomic_compare_exchange,[expected;desired]->
           emit_value env desired;M.bytes output[0x48;0x89;0xc2];emit_value env expected;cmpxchg()
       |(Atomic_fetch_add|Atomic_fetch_sub),[value]->emit_value env value;
           if kind=Atomic_fetch_sub then M.bytes output[0x48;0xf7;0xd8];
           M.bytes output[0x48;0x89;0xc1];locked_prefix();M.bytes output[0x0f;if width=1 then 0xc0 else 0xc1;0x0f];
           M.bytes output[0x48;0x89;0xc8]
       |(Atomic_fetch_and|Atomic_fetch_or|Atomic_fetch_xor),[value]->
           emit_value env value;M.bytes output[0x48;0x89;0xc1;0x48;0x89;0xf8];load_scalar_ptr output typ;
           let retry=fresh "atomic_retry"in M.label output retry;
           M.bytes output[0x48;0x89;0xc2;0x48;(match kind with Atomic_fetch_and->0x21|Atomic_fetch_or->0x09|_->0x31);0xca];
           cmpxchg();M.branch output[0x0f;0x85]retry
       |_->assert false);
      M.bytes output[0x0f;0xae;0xf0];
      if kind=Atomic_store then mov_rax_imm output 0L else normalize_rax output typ
  | Atomic _->assert false
  | Foreign_call(symbol,inputs)->
      let got=M.import output symbol.library symbol.symbol in
      List.iter(fun(v:value)->emit_value env v;
        if T.is_float v.typ then push_float env v.typ else push_rax env)inputs;
      let gp=ref 0 and fp=ref 0 and count=List.length inputs in
      List.iteri(fun i(v:value)->let displacement=(count-1-i)*8 in
        if T.is_float v.typ then begin
          let reg= !fp in incr fp;
          M.bytes output[if v.typ=F32 then 0xf3 else 0xf2;0x0f;0x10;0x84 lor(reg lsl 3);0x24]
        end else begin
          let reg=List.nth[7;6;2;1;8;9] !gp in incr gp;
          M.bytes output[if reg>=8 then 0x4c else 0x48;0x8b;0x84 lor((reg land 7)lsl 3);0x24]
        end;M.u32 output(Int64.of_int displacement))inputs;
      let pad=if env.stack_depth mod 16=0 then 0 else 8 in
      if pad<>0 then M.bytes output[0x48;0x83;0xec;0x08];
      M.bytes output[0xff;0x15];M.rip_rel32 output M.Data got;
      let total=count*8+pad in
      if total>0 then(M.bytes output[0x48;0x81;0xc4];M.u32 output(Int64.of_int total));
      env.stack_depth<-env.stack_depth-count*8;
      if expression.typ=Unit then mov_rax_imm output 0L
      else if T.is_integer expression.typ then normalize_rax output expression.typ
  | Ptr_addr (_,pointer)->emit_value env pointer
  | Ptr_len pointer->emit_value env pointer;M.bytes output[0x48;0x89;0xd0]
  | Syscall arguments ->
      List.iter(fun (a:value)->emit_value env a;push_rax env)arguments;
      let n=List.length arguments in
      R.raw_syscall output ~arity:n;
      env.stack_depth<-env.stack_depth-n*8
  | Function_address name ->
      M.bytes output [0x48;0x8d;0x05];M.rel32 output ("fn_"^name)
  | Indirect_call (callee,arguments) ->
      emit_value env callee;push_rax env;
      emit_call env expression.span None arguments;
      M.bytes output [0x48;0x83;0xc4;0x08];env.stack_depth<-env.stack_depth-8
  | Call (name, arguments) -> emit_call env expression.span (Some name) arguments
and emit_call env call_span target arguments =
      let output=env.output in
      List.iter (fun (argument:value) -> emit_value env argument;
        if (match argument.typ with Named _->true|_->false) then begin
          let size=slot_size argument.typ and staged=T.align_up(slot_size argument.typ)8 in M.bytes output[0x48;0x89;0xc6;0x48;0x81;0xec];M.u32 output(Int64.of_int staged);
          env.stack_depth<-env.stack_depth+staged;M.bytes output[0x48;0x89;0xe7;0x48;0xc7;0xc1];M.u32 output(Int64.of_int size);M.bytes output[0xf3;0xa4]
        end
        else if is_managed argument.typ then begin
          M.bytes output [0x48;0x83;0xec;0x18;0x48;0x89;0x04;0x24;0x48;0x89;0x54;0x24;0x08;0x48;0x89;0x4c;0x24;0x10];
          env.stack_depth <- env.stack_depth + 24
        end else if is_pair argument.typ then begin
          M.bytes output [0x48;0x83;0xec;0x10;0x48;0x89;0x04;0x24;0x48;0x89;0x54;0x24;0x08]; env.stack_depth<-env.stack_depth+16
        end else if is_float argument.typ then push_float env argument.typ else push_rax env) arguments;
      let arg_size (a:value)=match a.typ with Named _->T.align_up(slot_size a.typ)8|_->if is_managed a.typ then 24 else if is_pair a.typ then 16 else 8 in
      let total = List.fold_left (fun n a -> n + arg_size a) 0 arguments in
      let offsets = ref [] and offset = ref total in
      List.iter (fun (a : value) -> offset := !offset - arg_size a; offsets := !offset :: !offsets) arguments;
      let offsets = List.rev !offsets in
      let gp = ref 0 and fp = ref 0 in
      let gp_codes = [|7, false; 6, false; 2, false; 1, false; 0, true; 1, true|] in
      List.iter2 (fun (a : value) displacement ->
        if is_float a.typ then begin
          let modrm = 0x84 lor (!fp lsl 3) in incr fp;
          M.bytes output [(if a.typ=F32 then 0xf3 else 0xf2);0x0f;0x10;modrm;0x24]; M.u32 output (Int64.of_int displacement)
        end else begin
          let code, extended = gp_codes.(!gp) in incr gp;
          if is_managed a.typ || is_pair a.typ || (match a.typ with Named _->true|_->false) then begin
            M.bytes output [(if extended then 0x4c else 0x48);0x8d;0x84 lor (code lsl 3);0x24]; M.u32 output (Int64.of_int displacement)
          end else begin
            M.bytes output [(if extended then 0x4c else 0x48);0x8b;0x84 lor (code lsl 3);0x24]; M.u32 output (Int64.of_int displacement)
          end
        end) arguments offsets;
      if not(Option.fold ~none:false ~some:Numeric_math.is_helper target)then begin
        let error = emit_error_stub output call_span "maximum call depth exceeded" in
        M.bytes output [0x4c;0x8b;0x1d]; M.rip_rel32 output M.Data "__xen_call_depth";
        M.bytes output [0x49;0x81;0xfb]; M.u32 output (Int64.of_int max_call_depth);
        M.branch output [0x0f;0x8d] error
      end;
      (match target with
       | Some name->aligned_call env ("fn_" ^ name)
       | None->M.bytes output [0x4c;0x8b;0x9c;0x24];M.u32 output(Int64.of_int total);
           let pad=if env.stack_depth mod 16=0 then 8 else 0 in
           if pad<>0 then(M.bytes output[0x48;0x83;0xec;0x08];env.stack_depth<-env.stack_depth+8);
           M.bytes output[0x41;0xff;0xd3];
           if pad<>0 then(M.bytes output[0x48;0x83;0xc4;0x08];env.stack_depth<-env.stack_depth-8));
      if total > 0 then begin M.bytes output [0x48;0x81;0xc4]; M.u32 output (Int64.of_int total); env.stack_depth <- env.stack_depth - total end

let rec owned_leaves_at offset = function
  |Named n->List.concat_map(fun(f:struct_field)->owned_leaves_at(offset+f.offset)f.typ)(Hashtbl.find layouts n).fields
  |(String|Vec _|File|Box _)as t->[offset,t]|_->[]

let base_offset env id = let l=env.locals.(id)in Hashtbl.find env.slots id+aggregate_bias(slot_size l.typ)
let emit_place_address env p =
  let output=env.output in
  let current_type=ref env.locals.(p.root).typ in
  M.bytes output[0x48;0x8d;0x85];M.u32 output(Int64.of_int(-base_offset env p.root));
  List.iter(function
    |Field f->current_type:=f.typ;if f.offset<>0 then(M.bytes output[0x48;0x05];M.u32 output(Int64.of_int f.offset))
    |Deref->current_type:=(match !current_type with Ref(_,t)|Box t->t|_->assert false);M.bytes output[0x48;0x8b;0x00]
    |Element v->push_rax env;emit_value env v;
        let element=match !current_type with Vec t|Slice t->t|_->assert false in current_type:=element;
        let error=emit_error_stub output p.span "index out of bounds"in
        M.bytes output[0x48;0x8b;0x14;0x24;0x48;0x85;0xc0];M.branch output[0x0f;0x88]error;
        M.bytes output[0x48;0x3b;0x42;8];M.branch output[0x0f;0x83]error;
        M.bytes output[0x48;0x69;0xc0];M.u32 output(Int64.of_int(element_stride element));M.bytes output[0x48;0x03;0x02;0x48;0x83;0xc4;8];env.stack_depth<-env.stack_depth-8)p.projections
let static_offset p =
  List.fold_left(fun acc->function Field f->Option.map(fun n->n+f.offset)acc|_->None)(Some 0)p.projections
let flag_offset env p leaf = Option.bind(static_offset p)(fun offset->Hashtbl.find_opt env.flags(p.root,offset+leaf))
let set_flags env p yes = List.iter(fun(off,_)->Option.iter(fun flag->M.bytes env.output[0x48;0xc7;0x85];M.u32 env.output(Int64.of_int(-flag));M.u32 env.output(if yes then 1L else 0L))(flag_offset env p off))(owned_leaves_at 0 p.typ)
let emit_forget env p =
  set_flags env p false;
  (* Dereferenced storage belongs to the caller and has no flag in this frame.
     Leave the runtime's inactive representation there after a field move. *)
  List.iter(fun(off,typ)->emit_place_address env p;
    if off<>0 then(M.bytes env.output[0x48;0x05];M.u32 env.output(Int64.of_int off));
    List.iter(fun delta->M.bytes env.output[0x48;0xc7;0x80];M.u32 env.output(Int64.of_int delta);
      M.u32 env.output(if typ=File then 0xffffffffL else 0L))
      (match typ with File|Box _->[0]|_->[0;8;16]))(owned_leaves_at 0 p.typ)
let load_at_address env typ =
  let output=env.output in
  match typ with
  |Unit->mov_rax_imm output 0L
  |Named _->()
  |F32|F64->M.bytes output[(if typ=F32 then 0xf3 else 0xf2);0x0f;0x10;0x00]
  |String|Vec _->M.bytes output[0x48;0x89;0xc6;0x48;0x8b;0x06;0x48;0x8b;0x56;8;0x48;0x8b;0x4e;16]
  |Ptr _|Slice _->M.bytes output[0x48;0x8b;0x50;8;0x48;0x8b;0x00]
  |t when T.is_integer t||t=Bool->load_scalar_ptr output t
  |_->M.bytes output[0x48;0x8b;0x00]
let store_at_address env typ =
  (* Destination in rdi, result registers follow the existing internal ABI. *)
  let output=env.output in match typ with
  |Unit->()
  |Named _->M.bytes output[0x48;0x89;0xc6;0x48;0xc7;0xc1];M.u32 output(Int64.of_int(slot_size typ));M.bytes output[0xf3;0xa4]
  |F32|F64->M.bytes output[(if typ=F32 then 0xf3 else 0xf2);0x0f;0x11;0x07]
  |String|Vec _->M.bytes output[0x48;0x89;0x07;0x48;0x89;0x57;8;0x48;0x89;0x4f;16]
  |Ptr _|Slice _->M.bytes output[0x48;0x89;0x07;0x48;0x89;0x57;8]
  |t when T.is_integer t||t=Bool->M.bytes output(match slot_size typ with 1->[0x88;0x07]|2->[0x66;0x89;0x07]|4->[0x89;0x07]|_->[0x48;0x89;0x07])
  |_->M.bytes output[0x48;0x89;0x07]
let store_value env (v:value) =
  (* LEA leaves result registers intact. *)
  M.bytes env.output[0x48;0x8d;0xbd];M.u32 env.output(Int64.of_int(-base_offset env v.id));store_at_address env v.typ
let emit_drop env p =
  List.iter(fun(off,typ)->
    let output=env.output and skip=fresh "drop_inactive"in
    let flag=flag_offset env p off in
    Option.iter(fun flag->M.bytes output[0x48;0x83;0xbd];M.u32 output(Int64.of_int(-flag));M.u8 output 0;M.branch output[0x0f;0x84]skip;
      M.bytes output[0x48;0xc7;0x85];M.u32 output(Int64.of_int(-flag));M.u32 output 0L)flag;
    emit_place_address env p;if off<>0 then(M.bytes output[0x48;0x05];M.u32 output(Int64.of_int off));
    if typ=File then begin
      M.bytes output[0x48;0x89;0xc2;0x48;0x8b;0x38;0x48;0xc7;0x02;0xff;0xff;0xff;0xff;0x48;0x85;0xff];
      M.branch output[0x0f;0x88]skip;R.close output
    end else begin
      push_rax env;M.bytes output[0x48;0x89;0xc7];aligned_call env(drop_runtime typ);
      pop_reg env [];List.iter(fun delta->M.bytes output[0x48;0xc7;0x80];M.u32 output(Int64.of_int delta);M.u32 output 0L)(match typ with Box _->[0]|_->[0;8;16])
    end;
    M.label output skip)(List.rev(owned_leaves_at 0 p.typ))
let emit_operation env op = match op.node with
  |Storage_live _|Storage_dead _->()
  |Logical_call_enter _->
      let output=env.output in
      let error=emit_error_stub output op.span "maximum call depth exceeded" in
      M.bytes output [0x4c;0x8b;0x1d];M.rip_rel32 output M.Data "__xen_call_depth";
      M.bytes output [0x49;0x81;0xfb];M.u32 output(Int64.of_int max_call_depth);
      M.branch output [0x0f;0x8d] error;
      M.bytes output [0x48;0xff;0x05];M.rip_rel32 output M.Data "__xen_call_depth"
  |Logical_call_exit _->
      M.bytes env.output [0x48;0xff;0x0d];M.rip_rel32 env.output M.Data "__xen_call_depth"
  |Drop p->emit_drop env p
  |Drop_flag(p,yes)->set_flags env p yes
  |Forget p->emit_forget env p
  |Borrow(v,_,_,p)->emit_place_address env p;store_value env v
  |Acquire(v,kind,p)->
      emit_place_address env p;
      load_at_address env p.typ;store_value env v;
      if kind=Clone then List.iter(fun(off,typ)->if typ<>File then begin
        M.bytes env.output[0x48;0x8d;0xbd];M.u32 env.output(Int64.of_int(-base_offset env v.id+off));
        prepare_vec_stride env.output typ;aligned_call env(clone_runtime typ);
        M.bytes env.output[0x48;0x8d;0xbd];M.u32 env.output(Int64.of_int(-base_offset env v.id+off));store_at_address env typ
      end)(owned_leaves_at 0 p.typ);
      if kind=Move then emit_forget env p;
      if env.locals.(v.id).owned then set_flags env(place_of_value v)true
  |Eval(v,r)->env.scratch<-Hashtbl.find env.slots v.id;emit_rvalue env v r;store_value env v;
      if env.locals.(v.id).owned then set_flags env(place_of_value v)true
  |Initialize(p,v)->
      emit_place_address env p;push_rax env;emit_value env v;M.u8 env.output 0x5f;env.stack_depth<-env.stack_depth-8;
      store_at_address env p.typ;set_flags env p true
  |Replace _->unsupported ~span:op.span "unelaborated replacement in checked IR"

let emit_function output (func:func) =
  let epilogue=fresh "epilogue"in
  M.label output("fn_"^func.name);M.bytes output[0x55;0x48;0x89;0xe5];
  if not(Numeric_math.is_helper func.name)then begin
    M.bytes output[0x48;0xff;0x05];M.rip_rel32 output M.Data "__xen_call_depth"
  end;
  let slots=Hashtbl.create 32 and flags=Hashtbl.create 32 and next=ref 8 in
  Array.iter(fun(l:local)->let at=T.align_up !next (descriptor l.typ).alignment in Hashtbl.add slots l.id at;next:=at+max 8(slot_size l.typ))func.locals;
  Array.iter(fun(l:local)->if l.owned then List.iter(fun(off,_)->Hashtbl.add flags(l.id,off)!next;next:= !next+8)(owned_leaves_at 0 l.typ))func.locals;
  let argument_register_base= !next in next:= !next+48;
  let frame=T.align_up (!next-8)16 in M.bytes output[0x48;0x81;0xec];M.u32 output(Int64.of_int frame);
  Hashtbl.iter(fun _ flag->M.bytes output[0x48;0xc7;0x85];M.u32 output(Int64.of_int(-flag));M.u32 output 0L)flags;
  let env={slots;flags;locals=func.locals;output;stack_depth=0;scratch=8}in
  let save_registers = [[0x48;0x89;0xbd];[0x48;0x89;0xb5];[0x48;0x89;0x95];
                        [0x48;0x89;0x8d];[0x4c;0x89;0x85];[0x4c;0x89;0x8d]] in
  List.iteri(fun index instruction->M.bytes output instruction;M.u32 output
    (Int64.of_int(-(argument_register_base+(index*8)))))save_registers;
  let load_saved_gp index register =
    M.bytes output register;M.u32 output(Int64.of_int(-(argument_register_base+(index*8)))) in
  let integer_index = ref 0 and float_index = ref 0 in
  List.iter (fun (param : local) ->
    if (match param.typ with Named _->true|_->false) then begin
      let source_reg = !integer_index in incr integer_index;
      load_saved_gp source_reg [0x48;0x8b;0xb5];let target=Hashtbl.find slots param.id and size=slot_size param.typ in M.bytes output [0x48;0x8d;0xbd];M.u32 output(Int64.of_int(-(target+aggregate_bias size)));
      M.bytes output [0x48;0xc7;0xc1];M.u32 output(Int64.of_int(slot_size param.typ));M.bytes output [0xf3;0xa4]
    end else if is_managed param.typ then begin
      let source_reg = !integer_index in incr integer_index;
      load_saved_gp source_reg [0x4c;0x8b;0x9d];
      let load displacement =
        M.bytes output [0x49;0x8b;0x83]; M.u32 output (Int64.of_int displacement)
      in
      let offset = Hashtbl.find slots param.id in
      load 0; M.bytes output [0x48;0x89;0x85]; M.u32 output (Int64.of_int (-(offset + 16)));
      load 8; M.bytes output [0x48;0x89;0x85]; M.u32 output (Int64.of_int (-(offset + 8)));
      load 16; M.bytes output [0x48;0x89;0x85]; M.u32 output (Int64.of_int (-offset))
    end else if is_pair param.typ then begin
      let source_reg = !integer_index in incr integer_index;
      load_saved_gp source_reg [0x4c;0x8b;0x9d];
      let offset = Hashtbl.find slots param.id in
      M.bytes output [0x49;0x8b;0x03];
      M.bytes output [0x48;0x89;0x85]; M.u32 output (Int64.of_int (-(offset + 8)));
      M.bytes output [0x49;0x8b;0x43;0x08];
      M.bytes output [0x48;0x89;0x85]; M.u32 output (Int64.of_int (-offset))
    end else if is_float param.typ then begin
      let index = !float_index in incr float_index;
      let modrm = 0x85 lor (index lsl 3) in
      M.bytes output [(if param.typ=F32 then 0xf3 else 0xf2);0x0f;0x11;modrm];
      M.u32 output (Int64.of_int (-Hashtbl.find slots param.id))
    end else begin
      load_saved_gp !integer_index [0x48;0x8b;0x85];
      M.bytes output [0x48;0x89;0x85];incr integer_index;
      M.u32 output (Int64.of_int (-Hashtbl.find slots param.id))
    end) (List.map(fun id->func.locals.(id))func.params);

  List.iter(fun id->set_flags env(place_of_value(value_of_local func.locals.(id)))true)func.params;
  let label id=Printf.sprintf ".L_cfg_%d_%d"func.id id in
  M.branch output[0xe9](label func.entry);
  Array.iter(fun(b:block)->M.label output(label b.id);
    List.iter(emit_operation env)b.operations;
    if env.stack_depth<>0 then unsupported ~span:func.span "unbalanced CFG operation stack";
    (match b.terminator with
     |Jump target->M.branch output[0xe9](label target)
     |Branch(v,a,b)->emit_value env v;M.bytes output[0x48;0x85;0xc0];M.branch output[0x0f;0x85](label a);M.branch output[0xe9](label b)
     |Return v->(match v with Some v->emit_value env v|None->mov_rax_imm output 0L);M.branch output[0xe9]epilogue
     |Stop->M.bytes output[0x0f;0x0b]))func.blocks;
  M.label output epilogue;
  if not(Numeric_math.is_helper func.name)then begin
    M.bytes output[0x48;0xff;0x0d];M.rip_rel32 output M.Data "__xen_call_depth"
  end;
  M.bytes output[0xc9;0xc3]

let owned_leaves typ =
  let rec loop seen prefix = function
    | Named n when not(List.mem n seen) ->
        let l=Hashtbl.find layouts n in
        List.concat_map(fun (f:struct_field)->loop(n::seen)(prefix+f.offset)f.typ)l.fields
    | (String|Vec _|File|Box _) as typ -> [prefix,typ]
    | _ -> []
  in loop [] 0 typ

let emit_requested_vec_helper output typ = match typ with
  | Box element ->
      M.label output(vec_helper_label typ "drop");
      (* rdi addresses the owned pointer cell; rbx retains the allocation. *)
      M.bytes output[0x53;0x48;0x8b;0x1f;0x48;0xc7;0x07;0;0;0;0;0x48;0x85;0xdb];
      let done_=fresh "box_drop_done"in M.branch output[0x0f;0x84]done_;
      List.iter(fun(offset,leaf)->
        M.bytes output[0x48;0x8d;0xbb];M.u32 output(Int64.of_int offset);
        if leaf=File then begin
          M.bytes output[0x48;0x8b;0x3f;0x48;0x85;0xff];let skip=fresh "box_file_skip"in
          M.branch output[0x0f;0x88]skip;R.close output;M.label output skip
        end else M.branch output[0xe8](drop_runtime leaf)) (List.rev(owned_leaves element));
      M.bytes output[0x48;0x89;0xdf;0xbe];M.u32 output(Int64.of_int(element_stride element));
      R.unmap output;M.label output done_;M.bytes output[0x5b;0xc3]

  | Vec element ->
      let stride=element_stride element and leaves=owned_leaves element in
      let address ~base_indirect from_count offset =
        M.bytes output(if from_count then[0x4c;0x89;0xe8]else[0x48;0x89;0xd8]);
        M.bytes output[0x48;0x69;0xc0];M.u32 output(Int64.of_int stride);
        M.bytes output(if base_indirect then[0x49;0x03;0x04;0x24]else[0x4c;0x01;0xe0]);
        if offset<>0 then(M.bytes output[0x48;0x05];M.u32 output(Int64.of_int offset)) in
      M.label output(vec_helper_label typ "drop");
      M.bytes output[0x53;0x41;0x54;0x41;0x55;0x49;0x89;0xfc;0x4d;0x8b;0x6c;0x24;8];
      let drop_loop=fresh"vec_type_drop_loop" and drop_done=fresh"vec_type_drop_done" in
      M.label output drop_loop;M.bytes output[0x4d;0x85;0xed];M.branch output[0x0f;0x84]drop_done;M.bytes output[0x49;0xff;0xcd];
      List.iter(fun(offset,leaf)->
        address ~base_indirect:true true offset;
        if leaf=File then begin M.bytes output[0x48;0x8b;0x38;0x48;0x85;0xff];let skip=fresh"vec_type_file_skip" in M.branch output[0x0f;0x88]skip;R.close output;M.label output skip end
        else begin M.bytes output[0x48;0x89;0xc7];M.branch output[0xe8](drop_runtime leaf) end) (List.rev leaves);
      M.branch output[0xe9]drop_loop;M.label output drop_done;M.bytes output[0x4c;0x89;0xe7];M.branch output[0xe8]"__xen_vec_drop";M.bytes output[0x41;0x5d;0x41;0x5c;0x5b;0xc3];
      M.label output(vec_helper_label typ "clone");
      if List.exists(fun(_,t)->match t with Box _->true|_->false)leaves then M.bytes output[0x0f;0x0b];
      M.bytes output[0x53;0x41;0x54;0x41;0x55;0x41;0x56;0x49;0x89;0xfc;0x4d;0x8b;0x6c;0x24;8;0x48;0xc7;0xc6];M.u32 output(Int64.of_int stride);M.branch output[0xe8]"__xen_vec_clone";
      M.bytes output[0x49;0x89;0xc4;0x49;0x89;0xd5;0x49;0x89;0xce;0x31;0xdb];
      let clone_loop=fresh"vec_type_clone_loop" and clone_done=fresh"vec_type_clone_done" in
      M.label output clone_loop;M.bytes output[0x4c;0x39;0xeb];M.branch output[0x0f;0x83]clone_done;
      List.iter(fun(offset,leaf)->if leaf<>File && (match leaf with Box _->false|_->true)then begin
        address ~base_indirect:false false offset;M.bytes output[0x48;0x89;0xc7];prepare_vec_stride output leaf;M.branch output[0xe8](clone_runtime leaf);
        M.bytes output[0x51;0x52;0x50];address ~base_indirect:false false offset;
        M.bytes output[0x4c;0x8b;0x04;0x24;0x48;0x8b;0x54;0x24;8;0x48;0x8b;0x4c;0x24;16;0x4c;0x89;0x00;0x48;0x89;0x50;8;0x48;0x89;0x48;16;0x48;0x83;0xc4;24]
      end)leaves;
      M.bytes output[0x48;0xff;0xc3];M.branch output[0xe9]clone_loop;M.label output clone_done;
      M.bytes output[0x4c;0x89;0xe0;0x4c;0x89;0xea;0x4c;0x89;0xf1;0x41;0x5e;0x41;0x5d;0x41;0x5c;0x5b;0xc3]
  | _ -> assert false

let emit_requested_vec_helpers output =
  let emitted=Hashtbl.create 32 in
  let rec loop () =
    let pending=Hashtbl.fold(fun key typ out->if Hashtbl.mem emitted key then out else(key,typ)::out)requested_vec_helpers[] in
    match pending with
    | []->()
    | _->List.iter(fun(key,typ)->Hashtbl.add emitted key ();emit_requested_vec_helper output typ)pending;loop()
  in loop();
  Hashtbl.iter(fun _ typ->
    if ((match typ with Vec _->true|_->false) && not(Hashtbl.mem output.M.labels(vec_helper_label typ "clone")))||not(Hashtbl.mem output.M.labels(vec_helper_label typ "drop"))
    then unsupported("missing requested Vec helper for "^string_of_typ typ))requested_vec_helpers

let generate checked =
  let program=Semantic_ir.program checked in
  try
    Semantic_ir.verify program;
    Hashtbl.clear layouts;Hashtbl.clear requested_vec_helpers;List.iter(fun (l:struct_layout)->Hashtbl.add layouts l.name l)program.layouts;
    serial := 0;
    let dynamic=List.exists(fun(f:func)->Array.exists(fun(b:block)->List.exists(fun op->match op.node with Eval(_,Foreign_call _)->true|_->false)b.operations)f.blocks)program.functions in
    let output = M.create () in M.add_data_u64 output "__xen_call_depth" 0L;
    M.add_data_u64 output "__xen_argc" 0L; M.add_data_u64 output "__xen_argv" 0L;
    if dynamic then begin
      (match R.foreign_start output ~main:"__xen_c_main" with Ok ()->()|Error message->unsupported message);
      M.label output "__xen_c_main";
      (* System V C main thunk preserves all C callee-saved GP registers. *)
      M.bytes output[0x55;0x48;0x89;0xe5;0x53;0x41;0x54;0x41;0x55;0x41;0x56;0x41;0x57;0x48;0x83;0xec;0x08];
      M.branch output[0xe8]("fn_"^program.entry);
      M.bytes output[0x48;0x83;0xc4;0x08;0x41;0x5f;0x41;0x5e;0x41;0x5d;0x41;0x5c;0x5b;0x31;0xc0;0xc9;0xc3]
    end else begin
      R.start output;
      M.branch output [0xe8] ("fn_" ^ program.entry);
      R.exit output 0
    end;
    Output.emit output ~fresh; Heap.emit output ~fresh;
    Collection.emit output ~fresh ~layouts ~runtime_type_name ~drop_runtime ~clone_runtime ~prepare_vec_stride;
    File.emit output ~fresh;
    while M.position output mod 16 <> 0 do M.u8 output 0x90 done;
    File.emit_builtin output;Numeric_runtime.emit output;
    List.iter (emit_function output) program.functions;emit_requested_vec_helpers output;
    let entry = Hashtbl.find output.labels "_start" in
    Ok (R.executable ~entry output)
  with Unsupported error -> Error error | M.Missing_label label ->
    Error { span = None; message = "missing machine label '" ^ label ^ "'" }

end
let generate checked =
  let module C = Compilation() in C.generate checked

let write path executable =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_bytes channel executable);
  Unix.chmod path 0o755
end
