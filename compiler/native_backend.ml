(* SPDX-License-Identifier: Apache-2.0 *)
(* Xen-owned runtime code in generated user executables has the additional
   MIT OR Apache-2.0 permission specified in the root LICENSE. Compiler source
   and the compiler executable remain Apache-2.0 only. *)
open Ast
open Semantic_ir
module M = Machine_ir
module T = Type_desc

type error = { span : span option; message : string }
exception Unsupported of error
let unsupported ?span message = raise (Unsupported { span; message })

(* Active source function frames, including the entry function. *)
let max_call_depth = 4096

type jit_state = { mutable regions:int; mutable recipes:Jit_runtime.recipe list;
  recipe_ids:(operation_node,int)Hashtbl.t; report:bool }
type env = { jit:jit_state option;
  slots : (int, int) Hashtbl.t; output : M.t; locals : local array;
  flags : ((int * int), int) Hashtbl.t; return_type : typ;
  epilogue : string; mutable stack_depth : int; mutable scratch : int;
}

let layouts : (string, struct_layout) Hashtbl.t = Hashtbl.create 16
let is_managed = function String | Vec _ -> true | Named n -> (Hashtbl.find layouts n).managed | _ -> false
let is_ptr = function Ptr _ -> true | _ -> false
let is_pair = function Ptr _ | Slice _ -> true | _ -> false
let rec descriptor typ = T.describe ~named:(fun n->let l=Hashtbl.find layouts n in
  let fields=List.map(fun (f:struct_field)->descriptor f.typ)l.fields in
  { T.size=l.size;alignment=l.alignment;
    trivial_copy=List.for_all(fun d->d.T.trivial_copy)fields;
    move_only=List.exists(fun d->d.T.move_only)fields ||
      List.exists(fun (f:struct_field)->match f.typ with Ptr _->true|_->false)l.fields;
    drop=(if List.exists(fun d->d.T.drop<>T.No_drop)fields then T.Drop_struct else T.No_drop);
    equality=List.for_all(fun d->d.T.equality)fields;abi=T.Indirect }) typ
let is_owned typ = match typ with
  | String | Vec _ | File | Box _ -> true
  | Named _ -> let d=descriptor typ in d.T.move_only || d.T.drop<>T.No_drop
  | _ -> false
let slot_size typ = (descriptor typ).size
let element_stride typ = max 1 (T.align_up (descriptor typ).size (descriptor typ).alignment)
let is_float typ = T.is_float typ
let vec_lane_supported typ = T.is_numeric typ || typ=Bool
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
let float_runtime_hex = "f30f1efa415566480f7ec248b9ffffffffffff0f0041544889d04821d15548c1e8345325ff0700004881ecf80a0000488db424980100004885d27910c68424980100002d488db424990100003dff070000753a4883f901488d56034519c04183e0fb4183c06e4883f90119ff44880683e70d83c7614883f90119c040887e0183e0f883c06e884602e97503000085c075114885c9750cc60630488d5601e96003000041bacefbffff85c0740c480fbae934448d90cdfbffff31ff41b800ca9a3b4885c974144889c831d249f7f08954bc984889c148ffc7ebe74531c941bb00ca9a3b4585d278414539ca74374531c031c04439c77e1a428b5484984801d24801d031d249f7f3428954849849ffc0ebe14885c074094863d7ffc78944949841ffc1ebc44531d2eb4741f7da4531c941bb00ca9a3b4531c031c04439c77e1b428b548498488d14924801d031d249f7f3428954849849ffc0ebe04885c074094863d7ffc78944949841ffc14539d175c58d47ff41b901000000bb0a0000004898448b5c84984489d831d24d89c8f7f383c2304288540c8d4489da49ffc14189c383fa0977e04d63c0488d9424480600004c89c04989d1448a5c048d48ffc848ffc289c344885aff85c075eb83ef0241bc0a0000004863ff85ff7835448b5cbc98bd00e1f5054d8d68094489d831d2f7f583c0304189d331d24388040189e849ffc041f7f489c54d39e875de48ffcfebc7ba110000004489c04589c34429d04139d0410f4ed07e6d80bc2459060000357531bf120000004139fb7e144531c041803c3930410f95c048ffc74409c3ebe7408abc245806000085db750983e7017504eb327e30bf1000000041803c3939751a41c60439304883ef0173eec684244806000031bf01000000eb0e4863fffe843c48060000ffc8eb0e41c604393048ffc74883ff1175f24863d283fa017e1141807c11ff30488d7aff75054889faebea448d50044189d04863fa4183fa140f86a00000008a8c2448060000ffca4c8d5601880e7e21c646012eba01000000418a0c11884c160148ffc239d77ff1418d50ff4c8d54160241c60265498d4a02b22b85c07904f7d8b22d41885201be01000000bf0a00000099f7ff83c230885434894889f248ffc685c075ec4863c2ffca74068a54248beb07b230b8020000008854248b4889c64889ca408a7c048948ffc848ffc240887aff85c075ed488d1431e99000000085c0784bba3000000039cf7e05410fbe140988140e48ffc139c87de88d48014898488d54060139cf7e66c6022e4c8d14064863c139c77e0d418a14018854060148ffc0ebef4129c84b8d540202eb4166c706302e4889f248ffc24189f04129d04139c07e06c6420130ebecba0100000029c24801f239cf7e0c418a040988040a48ffc1ebf031c085ff480f49c74801c24585ff7506c6020a48ffc2b801000000bf01000000488db424980100004829f20f054881c4f80a00005b5d415c415dc3"
let read_builtin_runtime_hex = "f30f1efa41574989d731d231c041564989ce415541544989fc55534889f34883ec3848891148895108488951104839d87d1041803c04000f844c03000048ffc0ebeb488d6b014889efe8530300004989c031c04d85c00f84250300004839d87d0d418a14044188140048ffc0ebee41c6041800b80101000031d24c89c648c7c79cffffff0f05488904244c89c7b80b0000004889ee0f0548833c240041bd020000000f88e7020000bf001000004531e4bd0010000049bdffffffffffffff3fe8dd0200004889c34885c07525488b3c24b8030000000f05e9a5020000b80b0000004889df4889ee0f05488b6c24084889d34889ea488b3c244a8d342331c04c29e20f054885c0784b74514901c44c39e575df4c39ed7f2c488d442d004889c74889442408e8780200004889c24885c0741a31c04c39e07da48a0c03880c0248ffc0ebf041bd07000000eb1341bd08000000eb0b41bd03000000eb034531ed488b3c24b8030000000f054585ed0f85330100004885c0780a4585ed7410e92401000041bd04000000e9190100004d85ff75484d85e40f840b0100004c89e7e8ff0100004889c24885c00f842d0100004d39fc7e0d428a043b4288043a49ffc7ebeeb80b0000004889df4889ee0f054989164d896608e99e01000031c031d2488904244939d40f8eb40000000fb63c13e8d701000085c0740d48ffc24939d475ebe99a0000004889542408488b4424084939c47e140fb63c03e8ae01000085c0750748ff442408ebe2488b742408488d3c134829d64983ff01750c488d542420e8a3010000eb0a488d542428e83c02000089c285c0740fb80b0000004889df4889ee0f05eb3248b9ffffffffffffff0f48390c247514b80b0000004889df4889ee0f05ba07000000eb0e48ff0424488b542408e94bffffff4189d5e9f100000048833c24007512b80b0000004889df4889ee0f05e9d8000000488b0424488d3cc500000000e8d900000048894424104885c07409488944241831d2eb5db80b0000004889df4889ee0f05e99400000048ffc24939d474650fb63c13e8cc00000085c075eb4889542408488b4424084939c47f2e488b742408488d3c134829d6488b5424184983ff01752be8b9000000488344241808488b5424084939d47fb8eb1b0fb63c03e88200000085c075c548ff442408ebb4e833010000ebd3b80b0000004889df4889ee0f05488b442410498906488b04244989460849c7461001000000eb0e41bd08000000eb0641bd010000004883c4384489e85b5d415c415d415e415fc34889fe41ba220000004983c8ff4531c931ffb809000000ba030000000f05483d01f0ffff480f43c7c331c04080ff207713b81300800048c1e009480fa3f80f92c00fb6c0c34989fa4989f04989d34885f67e1a8a078d50d580e2fd75204531c93c2dbe01000000410f94c1eb054531c931f6b8050000004c39c67506c34531c931f648b8ffffffffffffff7f5531c9bd0a000000534963d94801c34c39c67d2c410fb63c3283ef3083ff09772e4863ff4889d831d24829f848f7f54839c87222486bc90a48ffc64801f9ebcf4585c9740348f7d949890b31c0eb0cb805000000eb05b8060000005b5dc3554889f14989d1534885f67e1a8a078d50d580e2fd75104531c03c2db801000000410f94c0eb054531c031c0d9ee31f64839c80f8dbd0100000fb61407448d52d04180fa09771b83ea30d80df501000048ffc0be01000000895424f0da4424f0ebce80fa2e0f85a801000048ffc04531d24839c8742c0fb61407448d5ad04180fb09771e83ea30d80db801000048ffc041ffc2895424f0be01000000da4424f0ebcfba0500000085f60f84780100004839c80f8d4a010000408a3407ba0500000083e6df4080fe450f855d0100004c8d580131db4c39d97e198a5407018d72d54080e6fd750c31db80fa2d4c8d58020f94c34c89de31c04839ce7c11ba050000004939f37533ddd8e9300100000fb614378d6ad04080fd0977133d0f2700007f076bc00a8d4410d048ffc6ebcaddd8ba05000000e904010000ba050000004839ce0f85e800000085db7402f7d84429d0ba060000008db01027000081fe204e00000f87cc00000089c285d27e0ad80dd2000000ffcaebf231f685c00f49f029f089c285d2740ad835b9000000ffc2ebf24585c07402d9e0dd5c24f0f20f104424f0b8ff07000048c1e03466480f7ec64989f049f7d04985c074354531c031c041bb010000004839c87d148a1c07448d53cf4180fa08450f46c348ffc0ebe74585c074054801f67407f2410f1101eb4eba06000000eb47ba050000004531d285f67435ba050000004839c1752f31c0e93affffffba050000004531d285f60f8595feffffddd8eb16ddd8eb12ddd8eb0eddd8eb0addd8eb06ddd8eb02ddd889d05b5dc30f1f0000002041"
let emit_hex output hex =
  let digit = function
    | '0' .. '9' as c -> Char.code c - Char.code '0'
    | 'a' .. 'f' as c -> Char.code c - Char.code 'a' + 10
    | _ -> assert false
  in
  for index = 0 to String.length hex / 2 - 1 do
    M.u8 output ((digit hex.[index * 2] lsl 4) lor digit hex.[index * 2 + 1])
  done
let mov_rax_imm output value = M.bytes output [0x48;0xb8]; M.u64 output value
let load_int env name span = match Hashtbl.find_opt env.slots name with
  | Some offset -> M.bytes env.output [0x48;0x8b;0x85]; M.u32 env.output (Int64.of_int (-offset))
  | None -> unsupported ~span ("cannot resolve local '" ^ string_of_int name ^ "'")
let store_int env name span = match Hashtbl.find_opt env.slots name with
  | Some offset -> M.bytes env.output [0x48;0x89;0x85]; M.u32 env.output (Int64.of_int (-offset))
  | None -> unsupported ~span ("cannot resolve local '" ^ string_of_int name ^ "'")
let load_float env name span = match Hashtbl.find_opt env.slots name with
  | Some offset -> M.bytes env.output [0xf2;0x0f;0x10;0x85]; M.u32 env.output (Int64.of_int (-offset))
  | None -> unsupported ~span ("cannot resolve local '" ^ string_of_int name ^ "'")
let store_float env name span = match Hashtbl.find_opt env.slots name with
  | Some offset -> M.bytes env.output [0xf2;0x0f;0x11;0x85]; M.u32 env.output (Int64.of_int (-offset))
  | None -> unsupported ~span ("cannot resolve local '" ^ string_of_int name ^ "'")
let load_scalar env typ name span = match Hashtbl.find_opt env.slots name with
  | None->unsupported ~span ("cannot resolve local '"^string_of_int name^"'")
  | Some offset->let out=env.output in
      (match T.canonical typ with
       | I8->M.bytes out[0x48;0x0f;0xbe;0x85]|U8|Bool->M.bytes out[0x0f;0xb6;0x85]
       | I16->M.bytes out[0x48;0x0f;0xbf;0x85]|U16->M.bytes out[0x0f;0xb7;0x85]
       | I32->M.bytes out[0x48;0x63;0x85]|U32->M.bytes out[0x8b;0x85]
       | _->M.bytes out[0x48;0x8b;0x85]);M.frame32 out name(Int64.of_int(-offset))
let store_scalar env typ name span = match Hashtbl.find_opt env.slots name with
  | None->unsupported ~span ("cannot resolve local '"^string_of_int name^"'")
  | Some offset->let out=env.output in
      (match (descriptor typ).size*8 with 8->M.bytes out[0x88;0x85]|16->M.bytes out[0x66;0x89;0x85]
       |32->M.bytes out[0x89;0x85]|_->M.bytes out[0x48;0x89;0x85]);M.u32 out(Int64.of_int(-offset))
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
let store_string env name span = match Hashtbl.find_opt env.slots name with
  | Some offset ->
      M.bytes env.output [0x48;0x89;0x85]; M.u32 env.output (Int64.of_int (-(offset + 16)));
      M.bytes env.output [0x48;0x89;0x95]; M.u32 env.output (Int64.of_int (-(offset + 8)));
      M.bytes env.output [0x48;0x89;0x8d]; M.u32 env.output (Int64.of_int (-offset))
  | None -> unsupported ~span ("cannot resolve local '" ^ string_of_int name ^ "'")

let load_managed = load_string
let store_managed = store_string
let load_ptr env name span = match Hashtbl.find_opt env.slots name with
  | Some offset ->
      M.bytes env.output [0x48;0x8b;0x85]; M.u32 env.output (Int64.of_int (-(offset + 8)));
      M.bytes env.output [0x48;0x8b;0x95]; M.u32 env.output (Int64.of_int (-offset))
  | None -> unsupported ~span ("cannot resolve local '" ^ string_of_int name ^ "'")
let store_ptr env name span = match Hashtbl.find_opt env.slots name with
  | Some offset ->
      M.bytes env.output [0x48;0x89;0x85]; M.u32 env.output (Int64.of_int (-(offset + 8)));
      M.bytes env.output [0x48;0x89;0x95]; M.u32 env.output (Int64.of_int (-offset))
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
  M.bytes output [0xb8;1;0;0;0;0xbf;2;0;0;0;0x48;0x8d;0x35];
  M.rip_rel32 output M.Rodata constant;
  M.bytes output [0xba]; M.u32 output (Int64.of_int length);
  M.bytes output [0x0f;0x05;0xbf;1;0;0;0;0xb8;0x3c;0;0;0;0x0f;0x05];
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
let pop_xmm env index =
  let modrm = 0x04 lor (index lsl 3) in
  M.bytes env.output [0xf2;0x0f;0x10;modrm;0x24;0x48;0x83;0xc4;0x08];
  env.stack_depth <- env.stack_depth - 8
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
  | Int_lit value -> M.bytes output [0x48;0xb8];M.literal64 output value
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
  | Bool_lit value -> M.bytes output [0x48;0xb8];M.literal64 output (if value then 1L else 0L)
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
      M.branch output [0x0f;0x88] done_; M.bytes output [0x48;0xc7;0x02;0xff;0xff;0xff;0xff;0xb8;3;0;0;0;0x0f;0x05;0x48;0x3d;1;0xf0;0xff;0xff];
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
      if value.typ=File then begin M.bytes output[0x48;0x8b;0x38;0x48;0x85;0xff];let skip=fresh"vec_set_closed_file" in M.branch output[0x0f;0x88]skip;M.bytes output[0xb8;3;0;0;0;0x0f;0x05];M.label output skip end
      else if (match value.typ with Named _->true|_->false) then begin
        let rec leaves prefix=function Named n->let l=Hashtbl.find layouts n in List.concat_map(fun f->leaves(prefix+f.offset)f.typ)l.fields|(String|Vec _|File|Box _)as t->[prefix,t]|_->[] in
        List.iter(fun(off,t)->M.bytes output[0x48;0x8b;0x3c;0x24];if off<>0 then(M.bytes output[0x48;0x81;0xc7];M.u32 output(Int64.of_int off));
          if t=File then begin M.bytes output[0x48;0x8b;0x3f;0x48;0x85;0xff];let skip=fresh"vec_set_named_file" in M.branch output[0x0f;0x88]skip;M.bytes output[0xb8;3;0;0;0;0x0f;0x05];M.label output skip end
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

        M.bytes output [0x48;0x89;0xc6;0x48;0x89;0xd2;0xbf;0x01;0;0;0;0xb8;1;0;0;0;0x0f;0x05]
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
          M.bytes output [0xba;2;0;0;0;0xb8;1;0;0;0;0x0f;0x05];
          M.label output not_integral
        end else
          aligned_call env (if argument.typ = Bool then "__xen_print_bool" else if T.is_unsigned_int argument.typ then "__xen_print_uint" else "__xen_print_int")
      end;
      if name = "println" then begin
        M.bytes output [0xbf;1;0;0;0;0x48;0x8d;0x35]; M.rip_rel32 output M.Rodata "__xen_newline";
        M.bytes output [0xba;1;0;0;0;0xb8;1;0;0;0;0x0f;0x05]
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
      M.u32 output (if name="open_read" then 0L else 577L); aligned_call env "__xen_file_open";
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
      M.bytes output[0xb8;9;0;0;0;0x31;0xff;0xbe];M.u32 output(Int64.of_int bytes);
      M.bytes output[0xba;3;0;0;0;0x41;0xba;0x22;0;0;0;0x49;0xc7;0xc0;0xff;0xff;0xff;0xff;0x45;0x31;0xc9;0x0f;0x05];
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
      M.bytes output[0xb8;11;0;0;0;0x0f;0x05];emit_value env expression
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
      push_rax env; M.bytes output [0x48;0x89;0xc6;0x48;0x69;0xf6];M.u32 output(Int64.of_int stride);M.bytes output [0x48;0x31;0xff;0xba;3;0;0;0;0x41;0xba;0x22;0;0;0;0x41;0xb8;0xff;0xff;0xff;0xff;0x45;0x31;0xc9;0xb8;9;0;0;0;0x0f;0x05];
      M.bytes output [0x48;0x3d;0x00;0xf0;0xff;0xff]; M.branch output [0x0f;0x83] failed;
      M.u8 output 0x5a; env.stack_depth<-env.stack_depth-8; M.label output ok
  | Raw_load (typ,pointer,offset) ->
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
  | Raw_store (typ,pointer,offset,value) ->
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
      M.bytes output [0x48;0x89;0xc7;0x48;0x89;0xd6;0x48;0x69;0xf6];M.u32 output(Int64.of_int(element_stride typ));M.bytes output[0xb8;11;0;0;0;0x0f;0x05;0x48;0x85;0xc0]; M.branch output [0x0f;0x88] failed;
      M.label output done_; mov_rax_imm output 0L
  | Ptr_addr (_,pointer)->emit_value env pointer
  | Ptr_len pointer->emit_value env pointer;M.bytes output[0x48;0x89;0xd0]
  | Syscall arguments ->
      List.iter(fun (a:value)->emit_value env a;push_rax env)arguments;
      let n=List.length arguments in
      let load displacement bytes=M.bytes output bytes;M.u32 output(Int64.of_int displacement)in
      load((n-1)*8)[0x48;0x8b;0x84;0x24];
      let regs=[[0x48;0x8b;0xbc;0x24];[0x48;0x8b;0xb4;0x24];[0x48;0x8b;0x94;0x24];[0x4c;0x8b;0x94;0x24];[0x4c;0x8b;0x84;0x24];[0x4c;0x8b;0x8c;0x24]]in
      List.iteri(fun i bytes->if i<n-1 then load((n-2-i)*8)bytes)regs;
      M.bytes output[0x48;0x81;0xc4];M.u32 output(Int64.of_int(n*8));env.stack_depth<-env.stack_depth-n*8;M.bytes output[0x0f;0x05]
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
      let error = emit_error_stub output call_span "maximum call depth exceeded" in
      M.bytes output [0x4c;0x8b;0x1d]; M.rip_rel32 output M.Data "__xen_call_depth";
      M.bytes output [0x49;0x81;0xfb]; M.u32 output (Int64.of_int max_call_depth);
      M.branch output [0x0f;0x8d] error;
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
  M.bytes output[0x48;0x8d;0x85];M.frame32 output p.root(Int64.of_int(-base_offset env p.root));
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
  M.bytes env.output[0x48;0x8d;0xbd];M.frame32 env.output v.id(Int64.of_int(-base_offset env v.id));store_at_address env v.typ
let emit_drop env p =
  List.iter(fun(off,typ)->
    let output=env.output and skip=fresh "drop_inactive"in
    let flag=flag_offset env p off in
    Option.iter(fun flag->M.bytes output[0x48;0x83;0xbd];M.u32 output(Int64.of_int(-flag));M.u8 output 0;M.branch output[0x0f;0x84]skip;
      M.bytes output[0x48;0xc7;0x85];M.u32 output(Int64.of_int(-flag));M.u32 output 0L)flag;
    emit_place_address env p;if off<>0 then(M.bytes output[0x48;0x05];M.u32 output(Int64.of_int off));
    if typ=File then begin
      M.bytes output[0x48;0x89;0xc2;0x48;0x8b;0x38;0x48;0xc7;0x02;0xff;0xff;0xff;0xff;0x48;0x85;0xff];
      M.branch output[0x0f;0x88]skip;M.bytes output[0xb8;3;0;0;0;0x0f;0x05]
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

let jit_operation = function Eval _|Acquire _|Initialize _->true|_->false
let emit_jit_region env state (operations:operation list) =
  let span=(List.hd operations).span in
  let template_span={file="<jit recipe>";line=1;column=1}in
  let value id typ : value={id;typ;span=template_span}in
  let canonical (op:operation)=match op.node with
    |Eval(v,Int_lit n)->Eval(value 0 v.typ,Int_lit 0L),[v.id],n
    |Eval(v,Bool_lit b)->Eval(value 0 v.typ,Bool_lit false),[v.id],(if b then 1L else 0L)
    |Eval(v,Unary(n,a))->Eval(value 0 v.typ,Unary(n,value 1 a.typ)),[v.id;a.id],0L
    |Eval(v,Binary(n,a,b))->Eval(value 0 v.typ,Binary(n,value 1 a.typ,value 2 b.typ)),[v.id;a.id;b.id],0L
    |Acquire(v,_,p)->Acquire(value 0 v.typ,Copy,place_of_value(value 1 p.typ)),[v.id;p.root],0L
    |Initialize(p,v)->Initialize(place_of_value(value 0 p.typ),value 1 v.typ),[p.root;v.id],0L
    |_->assert false in
  let recipe node ids = match Hashtbl.find_opt state.recipe_ids node with Some id->id,List.nth state.recipes id|None->
    let output=M.create ~record_operands:true()in
    let slots=Hashtbl.create 3 in List.iteri(fun id offset->Hashtbl.add slots id offset)[8;16;24];
    let types=Array.make 3 I64 in
    (match node with Eval(v,r)->types.(0)<-v.typ;List.iter(fun(v:value)->types.(v.id)<-v.typ)(rvalue_uses r)
      |Acquire(v,_,p)->types.(0)<-v.typ;types.(1)<-p.typ
      |Initialize(p,v)->types.(0)<-p.typ;types.(1)<-v.typ|_->assert false);
    let locals=Array.mapi(fun id typ->{id;typ;name="$recipe";span=template_span;scope=0;owned=false;temporary=true;parameter=None})types in
    let recipe_env={jit=None;slots;flags=Hashtbl.create 0;locals;return_type=Unit;output;epilogue="";stack_depth=0;scratch=8}in
    emit_operation recipe_env {node;scope=0;span=template_span};
    if recipe_env.stack_depth<>0 || output.fixups<>[] || output.rip_fixups<>[] ||
       Buffer.length output.rodata<>0 || Buffer.length output.data<>0 then unsupported ~span "non-local JIT recipe";
    let patches=List.rev output.operand_patches in
    let expected=List.init(List.length ids)(fun id->M.Frame id) @
      (match node with Eval(_,(Int_lit _|Bool_lit _))->[M.Literal]|_->[])in
    if List.sort compare(List.map(fun(p:M.operand_patch)->p.operand)patches)<>List.sort compare expected
      then unsupported ~span "incomplete JIT operand relocations";
    let result:Jit_runtime.recipe={code=Bytes.of_string(Buffer.contents output.buffer);patches}in
    Jit_runtime.validate result;
    let id=List.length state.recipes in state.recipes<-state.recipes@[result];Hashtbl.add state.recipe_ids node id;id,result in
  let records=M.create()and bytes=ref 6 in
  List.iter(fun op->let node,ids,immediate=canonical op in let id,template=recipe node ids in
    bytes:= !bytes+Bytes.length template.code;M.u32 records(Int64.of_int id);
    for field=0 to 2 do let offset=match List.nth_opt ids field with Some id-> -base_offset env id|None->0 in
      if offset< -2147483648 || offset>2147483647 then unsupported ~span "JIT frame operand exceeds signed displacement range";
      M.u32 records(Int64.of_int offset)done;M.u64 records immediate)operations;
  if !bytes>Jit_runtime.page_size then(List.iter(emit_operation env)operations)else begin
    let id=state.regions in state.regions<-id+1;
    let cache=Printf.sprintf "__xen_jit_cache_%d"id and descriptor=Printf.sprintf "__xen_jit_ir_%d"id in
    let data=M.create()in M.u64 data(Int64.of_int(List.length operations));M.u64 data(Int64.of_int !bytes);
    Buffer.add_buffer data.buffer records.buffer;M.add_rodata env.output descriptor(Buffer.contents data.buffer);
    M.add_data_u64 env.output cache 0L;
    let error=emit_error_stub env.output span "JIT compilation failed"and ready=fresh "jit_cached"and invoke=fresh "jit_invoke"in
    Jit_runtime.rip env.output M.Data cache [0x48;0x8b;0x05];M.bytes env.output[0x48;0x85;0xc0];M.branch env.output[0x0f;0x85]ready;
    Jit_runtime.rip env.output M.Rodata descriptor [0x48;0x8d;0x3d];aligned_call env "__xen_jit_compile";
    M.bytes env.output[0x48;0x85;0xc0];M.branch env.output[0x0f;0x84]error;
    Jit_runtime.rip env.output M.Data cache [0x48;0x89;0x05];M.branch env.output[0xe9]invoke;
    M.label env.output ready;
    if state.report then Jit_runtime.counter env.output "__xen_jit_hits"[0x48;0xff;0x05];
    M.label env.output invoke;M.bytes env.output[0x48;0x89;0xef];
    let padded=env.stack_depth mod 16<>0 in if padded then M.bytes env.output[0x48;0x83;0xec;8];
    M.bytes env.output[0xff;0xd0];if padded then M.bytes env.output[0x48;0x83;0xc4;8]
  end
let emit_block_operations env (func:func) chunks =
  List.iter(fun(chunk:Semantic_opt.chunk)->match env.jit with
    |Some state when chunk.calculation && List.mem Jit func.scopes.(chunk.scope).mode_set->
      let pending=ref [] in
      let flush()=match List.rev !pending with []->()|operations->
        if state.regions<Jit_runtime.max_regions then emit_jit_region env state operations
        else List.iter(emit_operation env)operations;
        pending:=[]in
      List.iter(fun op->if jit_operation op.node then begin
        pending:=op::!pending;if List.length !pending=Jit_runtime.max_operations then flush()
      end else emit_operation env op)chunk.operations;flush()
    |_->List.iter(emit_operation env)chunk.operations)chunks

let emit_function output jit (func:func) =
  let jit=if Array.exists(fun(s:scope)->List.mem Jit s.mode_set)func.scopes then jit else None in
  let epilogue=fresh "epilogue"in
  M.label output("fn_"^func.name);M.bytes output[0x55;0x48;0x89;0xe5];
  M.bytes output[0x48;0xff;0x05];M.rip_rel32 output M.Data "__xen_call_depth";
  let slots=Hashtbl.create 32 and flags=Hashtbl.create 32 and next=ref 8 in
  Array.iter(fun(l:local)->let at=T.align_up !next (descriptor l.typ).alignment in Hashtbl.add slots l.id at;next:=at+max 8(slot_size l.typ))func.locals;
  Array.iter(fun(l:local)->if l.owned then List.iter(fun(off,_)->Hashtbl.add flags(l.id,off)!next;next:= !next+8)(owned_leaves_at 0 l.typ))func.locals;
  let argument_register_base= !next in next:= !next+48;
  let frame=T.align_up (!next-8)16 in M.bytes output[0x48;0x81;0xec];M.u32 output(Int64.of_int frame);
  Hashtbl.iter(fun _ flag->M.bytes output[0x48;0xc7;0x85];M.u32 output(Int64.of_int(-flag));M.u32 output 0L)flags;
  let env={jit;slots;flags;locals=func.locals;return_type=func.return_type;output;epilogue;stack_depth=0;scratch=8}in
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
  let chunks=match jit with Some _->Some(Semantic_opt.calculation_chunks func)|None->None in
  Array.iter(fun(b:block)->M.label output(label b.id);(match chunks with Some chunks->emit_block_operations env func chunks.(b.id)|None->List.iter(emit_operation env)b.operations);
    if env.stack_depth<>0 then unsupported ~span:func.span "unbalanced CFG operation stack";
    (match b.terminator with
     |Jump target->M.branch output[0xe9](label target)
     |Branch(v,a,b)->emit_value env v;M.bytes output[0x48;0x85;0xc0];M.branch output[0x0f;0x85](label a);M.branch output[0xe9](label b)
     |Return v->(match v with Some v->emit_value env v|None->mov_rax_imm output 0L);M.branch output[0xe9]epilogue
     |Stop->M.bytes output[0x0f;0x0b]))func.blocks;
  M.label output epilogue;M.bytes output[0x48;0xff;0x0d];M.rip_rel32 output M.Data "__xen_call_depth";
  M.bytes output[0xc9;0xc3]

let emit_print_runtime output =
  M.add_rodata output "__xen_true" "true"; M.add_rodata output "__xen_false" "false";
  M.add_rodata output "__xen_decimal_suffix" ".0";
  M.label output "__xen_print_bool";
  M.bytes output [0x48;0x85;0xff]; let false_ = fresh "false" and write = fresh "bool_write" in
  M.branch output [0x0f;0x84] false_; M.bytes output [0x48;0x8d;0x35]; M.rip_rel32 output M.Rodata "__xen_true";
  M.bytes output [0xba;4;0;0;0]; M.branch output [0xe9] write;
  M.label output false_; M.bytes output [0x48;0x8d;0x35]; M.rip_rel32 output M.Rodata "__xen_false";
  M.bytes output [0xba;5;0;0;0]; M.label output write;
  M.bytes output [0xb8;1;0;0;0;0xbf;1;0;0;0;0x0f;0x05;0xc3];
  M.label output "__xen_print_int";
  M.bytes output [0x55;0x48;0x89;0xe5;0x48;0x83;0xec;0x20;0x48;0x8d;0x75;0xff;0xc6;0x06;0x0a;
    0x48;0xc7;0xc1;0x01;0;0;0;0x45;0x85;0xff];
  let int_newline = fresh "int_newline" in M.branch output [0x0f;0x84] int_newline;
  M.bytes output [0x48;0x89;0xee;0x48;0x31;0xc9];M.label output int_newline;
  M.bytes output [0x48;0x89;0xf8;0x45;0x31;0xc9;0x48;0x85;0xc0];
  let positive = fresh "positive" and digits = fresh "digits" and sign_done = fresh "sign" in
  M.branch output [0x0f;0x89] positive; M.bytes output [0x48;0xf7;0xd8;0x41;0xb9;1;0;0;0];
  M.label output positive; M.label output digits;
  M.bytes output [0x48;0x31;0xd2;0x41;0xb8;0x0a;0;0;0;0x49;0xf7;0xf0;0x80;0xc2;0x30;
    0x48;0xff;0xce;0x88;0x16;0x48;0xff;0xc1;0x48;0x85;0xc0];
  M.branch output [0x0f;0x85] digits; M.bytes output [0x45;0x85;0xc9]; M.branch output [0x0f;0x84] sign_done;
  M.bytes output [0x48;0xff;0xce;0xc6;0x06;0x2d;0x48;0xff;0xc1]; M.label output sign_done;
  M.bytes output [0xb8;1;0;0;0;0xbf;1;0;0;0;0x48;0x89;0xca;0x0f;0x05;0xc9;0xc3]
  ;
  M.label output "__xen_print_uint";
  M.bytes output[0x55;0x48;0x89;0xe5;0x48;0x83;0xec;0x20;0x48;0x8d;0x75;0xff;0x48;0x89;0xf8;0x31;0xc9];
  let uint_digits=fresh "uint_digits" in M.label output uint_digits;
  M.bytes output[0x48;0x31;0xd2;0x49;0xc7;0xc0;0x0a;0;0;0;0x49;0xf7;0xf0;0x80;0xc2;0x30;0x48;0xff;0xce;0x88;0x16;0x48;0xff;0xc1;0x48;0x85;0xc0];
  M.branch output[0x0f;0x85]uint_digits;
  M.bytes output[0xb8;1;0;0;0;0xbf;1;0;0;0;0x48;0x89;0xca;0x0f;0x05;0xc9;0xc3];
  M.label output "__xen_print_float";
  emit_hex output float_runtime_hex

let emit_string_runtime output =
  M.add_rodata output "__xen_assert_text" "assertion failed\n";
  M.add_rodata output "__xen_assert_prefix" "assertion failed: ";
  M.add_rodata output "__xen_newline" "\n";
  M.add_rodata output "__xen_missing_arg" "xen runtime error: missing program argument\n";
  M.add_rodata output "__xen_alloc_error" "xen runtime error: string allocation failed\n";
  M.add_rodata output "__xen_string_large_error" "xen runtime error: string is too large\n";
  M.label output "__xen_write"; M.bytes output [0xb8;1;0;0;0;0x0f;0x05;0xc3];
  M.label output "__xen_string_equal";
  M.bytes output [0x48;0x8b;0x47;0x08;0x48;0x3b;0x46;0x08];
  let unequal = fresh "string_unequal" and equal = fresh "string_equal" in
  M.branch output [0x0f;0x85] unequal;
  M.bytes output [0x48;0x89;0xc1;0x48;0x8b;0x3f;0x48;0x8b;0x36;0x48;0x85;0xc9];
  M.branch output [0x0f;0x84] equal;
  M.bytes output [0xf3;0xa6]; M.branch output [0x0f;0x85] unequal;
  M.label output equal; M.bytes output [0xb8;1;0;0;0;0xc3];
  M.label output unequal; M.bytes output [0x31;0xc0;0xc3];
  M.label output "__xen_string_concat";
  M.bytes output [0x53;0x41;0x54;0x41;0x55;0x41;0x56;0x41;0x57;
    0x4c;0x8b;0x67;0x08;0x4c;0x03;0x66;0x08];
  let concat_large = fresh "concat_large" and concat_alloc = fresh "concat_alloc"
  and concat_nonempty = fresh "concat_nonempty" in
  M.branch output [0x0f;0x82] concat_large;
  M.bytes output [0x4d;0x85;0xe4]; M.branch output [0x0f;0x85] concat_nonempty;
  M.bytes output [0x31;0xc0;0x31;0xd2;0x31;0xc9;0x41;0x5f;0x41;0x5e;0x41;0x5d;0x41;0x5c;0x5b;0xc3];
  M.label output concat_nonempty;
  M.bytes output [0x4c;0x8b;0x2f;0x4c;0x8b;0x36;0x4c;0x8b;0x7f;0x08;
    0xb8;9;0;0;0;0x31;0xff;0x4c;0x89;0xe6;0xba;3;0;0;0;0x41;0xba;0x22;0;0;0;
    0x49;0xc7;0xc0;0xff;0xff;0xff;0xff;0x45;0x31;0xc9;0x0f;0x05;0x48;0x3d;1;0xf0;0xff;0xff];
  M.branch output [0x0f;0x83] concat_alloc;
  M.bytes output [0x48;0x89;0xc3;0x48;0x89;0xc7;0x4c;0x89;0xee;0x4c;0x89;0xf9;0xf3;0xa4;
    0x4c;0x89;0xf6;0x4c;0x89;0xe1;0x4c;0x29;0xf9;0xf3;0xa4;0x48;0x89;0xd8;0x4c;0x89;0xe2;
    0xb9;1;0;0;0;0x41;0x5f;0x41;0x5e;0x41;0x5d;0x41;0x5c;0x5b;0xc3];
  M.label output concat_large;
  M.bytes output [0xb8;1;0;0;0;0xbf;2;0;0;0;0x48;0x8d;0x35]; M.rip_rel32 output M.Rodata "__xen_string_large_error";
  M.bytes output [0xba;39;0;0;0;0x0f;0x05;0xbf;1;0;0;0;0xb8;60;0;0;0;0x0f;0x05];
  M.label output concat_alloc;
  M.bytes output [0xb8;1;0;0;0;0xbf;2;0;0;0;0x48;0x8d;0x35]; M.rip_rel32 output M.Rodata "__xen_alloc_error";
  M.bytes output [0xba;44;0;0;0;0x0f;0x05;0xbf;1;0;0;0;0xb8;60;0;0;0;0x0f;0x05];
  M.label output "__xen_string_clone";
  M.bytes output [0x48;0x8b;0x57;0x08;0x48;0x85;0xd2];
  let clone_nonempty = fresh "clone_nonempty" and alloc_error = fresh "alloc_error" in
  M.branch output [0x0f;0x85] clone_nonempty;
  M.bytes output [0x31;0xc0;0x31;0xd2;0x31;0xc9;0xc3];
  M.label output clone_nonempty;
  M.bytes output [0x53;0x41;0x54;0x41;0x55;0x49;0x89;0xd4;0x4c;0x8b;0x2f;
    0xb8;9;0;0;0;0x31;0xff;0x4c;0x89;0xe6;0xba;3;0;0;0;0x41;0xba;0x22;0;0;0;
    0x49;0xc7;0xc0;0xff;0xff;0xff;0xff;0x45;0x31;0xc9;0x0f;0x05;
    0x48;0x3d;0x01;0xf0;0xff;0xff];
  M.branch output [0x0f;0x83] alloc_error;
  M.bytes output [0x48;0x89;0xc3;0x48;0x89;0xc7;0x4c;0x89;0xee;0x4c;0x89;0xe1;0xf3;0xa4;
    0x48;0x89;0xd8;0x4c;0x89;0xe2;0xb9;1;0;0;0;0x41;0x5d;0x41;0x5c;0x5b;0xc3];
  M.label output alloc_error;
  M.bytes output [0xb8;1;0;0;0;0xbf;2;0;0;0;0x48;0x8d;0x35]; M.rip_rel32 output M.Rodata "__xen_alloc_error";
  M.bytes output [0xba;44;0;0;0;0x0f;0x05;0xbf;1;0;0;0;0xb8;60;0;0;0;0x0f;0x05];
  M.label output "__xen_int_to_str";
  M.bytes output [0x53;0x41;0x54;0x41;0x55;0x49;0x89;0xfc;0x45;0x31;0xed;0x4d;0x85;0xe4];
  let its_positive=fresh "int_str_positive" and its_digits=fresh "int_str_digits" in
  M.branch output [0x0f;0x89] its_positive; M.bytes output [0x49;0xf7;0xdc;0x41;0xbd;1;0;0;0]; M.label output its_positive;
  M.bytes output [0xb8;9;0;0;0;0x31;0xff;0xbe;20;0;0;0;0xba;3;0;0;0;0x41;0xba;0x22;0;0;0;
    0x49;0xc7;0xc0;0xff;0xff;0xff;0xff;0x45;0x31;0xc9;0x0f;0x05;0x48;0x3d;1;0xf0;0xff;0xff];
  M.branch output [0x0f;0x83] alloc_error;
  M.bytes output [0x48;0x89;0xc3;0x48;0x8d;0x78;0x14;0x4c;0x89;0xe0]; M.label output its_digits;
  M.bytes output [0x48;0x31;0xd2;0xbe;10;0;0;0;0x48;0xf7;0xf6;0x80;0xc2;0x30;0x48;0xff;0xcf;0x88;0x17;0x48;0x85;0xc0];
  M.branch output [0x0f;0x85] its_digits;
  let its_sign_done=fresh "int_str_sign_done" in
  M.bytes output [0x45;0x85;0xed]; M.branch output [0x0f;0x84] its_sign_done;
  M.bytes output [0x48;0xff;0xcf;0xc6;0x07;0x2d]; M.label output its_sign_done;
  M.bytes output [0x48;0x8d;0x53;0x14;0x48;0x29;0xfa;0x48;0x89;0xfe;0x48;0x89;0xdf;0x48;0x89;0xd1;0xf3;0xa4;
    0x48;0x89;0xd8;0x48;0x89;0xd2;0xb9;1;0;0;0;0x41;0x5d;0x41;0x5c;0x5b;0xc3];
  M.label output "__xen_string_drop";
  M.bytes output [0x48;0x83;0x7f;0x10;0x00]; let drop_done = fresh "drop_done" in
  M.branch output [0x0f;0x84] drop_done;
  M.bytes output [0x48;0x8b;0x07;0x48;0x8b;0x77;0x08;0x48;0xc7;0x47;0x10;0;0;0;0;
    0x48;0x89;0xc7;0xb8;11;0;0;0;0x0f;0x05];
  M.label output drop_done; M.bytes output [0xc3];
  M.label output "__xen_arg";
  M.bytes output [0x48;0x85;0xff]; let missing = fresh "missing_arg" in M.branch output [0x0f;0x88] missing;
  M.bytes output [0x48;0x3b;0x3d]; M.rip_rel32 output M.Data "__xen_argc"; M.branch output [0x0f;0x83] missing;
  M.bytes output [0x48;0x8b;0x05]; M.rip_rel32 output M.Data "__xen_argv";
  M.bytes output [0x48;0x8b;0x04;0xf8;0x48;0x31;0xd2]; let strlen = fresh "strlen" and strlen_done = fresh "strlen_done" in
  M.label output strlen; M.bytes output [0x80;0x3c;0x10;0x00]; M.branch output [0x0f;0x84] strlen_done;
  M.bytes output [0x48;0xff;0xc2]; M.branch output [0xe9] strlen; M.label output strlen_done; M.bytes output [0x31;0xc9;0xc3];
  M.label output missing; M.bytes output [0xb8;1;0;0;0;0xbf;2;0;0;0;0x48;0x8d;0x35]; M.rip_rel32 output M.Rodata "__xen_missing_arg";
  M.bytes output [0xba;44;0;0;0;0x0f;0x05;0xbf;1;0;0;0;0xb8;60;0;0;0;0x0f;0x05];
  M.label output "__xen_assert_fail"; M.bytes output [0xbf;2;0;0;0;0x48;0x8d;0x35]; M.rip_rel32 output M.Rodata "__xen_assert_text";
  M.bytes output [0xba;17;0;0;0]; M.branch output [0xe9] "__xen_fail_write";
  M.label output "__xen_assert_msg_fail"; M.bytes output [0x52;0x56;0xbf;2;0;0;0;0x48;0x8d;0x35]; M.rip_rel32 output M.Rodata "__xen_assert_prefix";
  M.bytes output [0xba;18;0;0;0]; M.branch output [0xe8] "__xen_write"; M.bytes output [0x5e;0x5a];
  M.label output "__xen_panic"; M.bytes output [0xbf;2;0;0;0]; M.branch output [0xe8] "__xen_write";
  M.bytes output [0xbf;2;0;0;0;0x48;0x8d;0x35]; M.rip_rel32 output M.Rodata "__xen_newline"; M.bytes output [0xba;1;0;0;0];
  M.label output "__xen_fail_write"; M.branch output [0xe8] "__xen_write";
  M.bytes output [0xbf;1;0;0;0;0xb8;60;0;0;0;0x0f;0x05]

let emit_vec_runtime output =
  M.add_rodata output "__xen_vec_alloc_error" "xen runtime error: vector allocation failed\n";
  M.add_rodata output "__xen_vec_large_error" "xen runtime error: vector is too large\n";
  let fatal label text length =
    M.label output label; M.bytes output [0xb8;1;0;0;0;0xbf;2;0;0;0;0x48;0x8d;0x35];
    M.rip_rel32 output M.Rodata text; M.bytes output [0xba];M.u32 output(Int64.of_int length);
    M.bytes output [0x0f;0x05;0xbf;1;0;0;0;0xb8;60;0;0;0;0x0f;0x05] in
  fatal "__xen_vec_alloc_fail" "__xen_vec_alloc_error" 44;
  fatal "__xen_vec_too_large" "__xen_vec_large_error" 39;
  (* Vec<U8> and String have different allocation contracts: a String owns a
     mapping of exactly its logical length, while Vec owns capacity bytes. *)
  M.label output "__xen_vec_into_string";
  M.bytes output[0x53;0x41;0x54;0x41;0x55;0x41;0x56;0x4c;0x8b;0x27;0x4c;0x8b;0x6f;8;0x48;0x8b;0x5f;16];
  let into_empty=fresh"vec_into_string_empty" and into_no_old=fresh"vec_into_string_no_old" and into_done=fresh"vec_into_string_done" in
  M.bytes output[0x4d;0x85;0xed];M.branch output[0x0f;0x84]into_empty;
  M.bytes output[0xb8;9;0;0;0;0x31;0xff;0x4c;0x89;0xee;0xba;3;0;0;0;0x41;0xba;0x22;0;0;0;0x49;0xc7;0xc0;0xff;0xff;0xff;0xff;0x45;0x31;0xc9;0x0f;0x05;0x48;0x3d;1;0xf0;0xff;0xff];
  M.branch output[0x0f;0x83]"__xen_vec_alloc_fail";
  M.bytes output[0x49;0x89;0xc6;0x48;0x89;0xc7;0x4c;0x89;0xe6;0x4c;0x89;0xe9;0xf3;0xa4;0x48;0x85;0xdb];M.branch output[0x0f;0x84]into_no_old;
  M.bytes output[0x4c;0x89;0xe7;0x48;0x89;0xde;0xb8;11;0;0;0;0x0f;0x05];M.label output into_no_old;
  M.bytes output[0x4c;0x89;0xf0;0x4c;0x89;0xea;0xb9;1;0;0;0];M.branch output[0xe9]into_done;
  M.label output into_empty;M.bytes output[0x48;0x85;0xdb];let empty_no_old=fresh"vec_into_string_empty_no_old" in M.branch output[0x0f;0x84]empty_no_old;
  M.bytes output[0x4c;0x89;0xe7;0x48;0x89;0xde;0xb8;11;0;0;0;0x0f;0x05];M.label output empty_no_old;
  M.bytes output[0x31;0xc0;0x31;0xd2;0x31;0xc9];M.label output into_done;M.bytes output[0x41;0x5e;0x41;0x5d;0x41;0x5c;0x5b;0xc3];
  M.label output "__xen_vec_new";
  M.bytes output [0x48;0x85;0xff];let nonempty=fresh"vec_new_nonempty" in M.branch output [0x0f;0x85] nonempty;
  M.bytes output [0x31;0xc0;0x31;0xd2;0x31;0xc9;0xc3];M.label output nonempty;
  M.bytes output [0x41;0x54;0x41;0x55;0x41;0x56;0x49;0x89;0xfc;0x49;0x89;0xf6;0x49;0xc7;0xc5;4;0;0;0];
  let grow=fresh"vec_cap_grow" and cap_done=fresh"vec_cap_done" in M.label output grow;
  M.bytes output [0x4d;0x39;0xe5];M.branch output [0x0f;0x83] cap_done;
  M.bytes output [0x4d;0x01;0xed];M.branch output [0x0f;0x82] "__xen_vec_too_large";M.branch output [0xe9] grow;M.label output cap_done;
  M.bytes output [0x4c;0x89;0xe8;0x49;0xf7;0xe6;0x48;0x85;0xd2];M.branch output[0x0f;0x85]"__xen_vec_too_large";
  M.bytes output [0x48;0x89;0xc6;0xb8;9;0;0;0;0x31;0xff;0xba;3;0;0;0;0x41;0xba;0x22;0;0;0;0x49;0xc7;0xc0;0xff;0xff;0xff;0xff;0x45;0x31;0xc9;0x0f;0x05;0x48;0x3d;1;0xf0;0xff;0xff];
  M.branch output [0x0f;0x83] "__xen_vec_alloc_fail";
  M.bytes output [0x4c;0x89;0xe2;0x4c;0x89;0xe9;0x49;0x0f;0xaf;0xce;0x41;0x5e;0x41;0x5d;0x41;0x5c;0xc3];
  M.label output "__xen_vec_clone";
  M.bytes output [0x41;0x54;0x41;0x55;0x41;0x56;0x4c;0x8b;0x27;0x4c;0x8b;0x6f;8;0x49;0x89;0xf6;0x4c;0x89;0xef;0x4c;0x89;0xf6];M.branch output [0xe8] "__xen_vec_new";
  M.bytes output [0x49;0x89;0xc0;0x48;0x89;0xc7;0x4c;0x89;0xe6;0x4c;0x89;0xe9;0x49;0x0f;0xaf;0xce;0xf3;0xa4;0x4c;0x89;0xc0;0x4c;0x89;0xea;0x4c;0x89;0xe9;0x49;0x0f;0xaf;0xce;0x41;0x5e;0x41;0x5d;0x41;0x5c;0xc3];
  M.label output "__xen_vec_drop";M.bytes output [0x48;0x8b;0x77;16;0x48;0x85;0xf6];let vec_drop_done=fresh"vec_drop_done" in M.branch output [0x0f;0x84] vec_drop_done;
  M.bytes output [0x48;0x8b;0x3f;0xb8;11;0;0;0;0x0f;0x05];M.label output vec_drop_done;M.bytes output [0xc3];
  M.label output "__xen_vec_string_drop";
  M.bytes output[0x41;0x54;0x41;0x55;0x49;0x89;0xfc;0x4d;0x8b;0x6c;0x24;8];
  let string_drop_loop=fresh"vec_string_drop_loop" and string_drop_done=fresh"vec_string_drop_done" in
  M.label output string_drop_loop;M.bytes output[0x4d;0x85;0xed];M.branch output[0x0f;0x84]string_drop_done;
  M.bytes output[0x49;0xff;0xcd;0x4c;0x89;0xe8;0x48;0x6b;0xc0;24;0x49;0x03;0x04;0x24;0x48;0x89;0xc7];M.branch output[0xe8]"__xen_string_drop";M.branch output[0xe9]string_drop_loop;
  M.label output string_drop_done;M.bytes output[0x4c;0x89;0xe7];M.branch output[0xe8]"__xen_vec_drop";M.bytes output[0x41;0x5d;0x41;0x5c;0xc3];
  M.label output "__xen_vec_file_drop";M.bytes output[0x41;0x54;0x41;0x55;0x49;0x89;0xfc;0x4d;0x8b;0x6c;0x24;8];
  let file_drop_loop=fresh"vec_file_drop_loop" and file_drop_next=fresh"vec_file_drop_next" and file_drop_done=fresh"vec_file_drop_done" in
  M.label output file_drop_loop;M.bytes output[0x4d;0x85;0xed];M.branch output[0x0f;0x84]file_drop_done;M.bytes output[0x49;0xff;0xcd;0x49;0x8b;0x3c;0x24;0x4a;0x8b;0x3c;0xef;0x48;0x85;0xff];M.branch output[0x0f;0x88]file_drop_next;M.bytes output[0xb8;3;0;0;0;0x0f;0x05];M.label output file_drop_next;M.branch output[0xe9]file_drop_loop;
  M.label output file_drop_done;M.bytes output[0x4c;0x89;0xe7];M.branch output[0xe8]"__xen_vec_drop";M.bytes output[0x41;0x5d;0x41;0x5c;0xc3];
  M.label output "__xen_vec_string_clone";
  M.bytes output[0x53;0x41;0x54;0x41;0x55;0x41;0x56;0x41;0x57;0x49;0x89;0xfc;0x4d;0x8b;0x6c;0x24;8;0x4c;0x89;0xef;0xbe;24;0;0;0];M.branch output[0xe8]"__xen_vec_new";
  M.bytes output[0x49;0x89;0xc6;0x49;0x89;0xcf;0x31;0xdb];
  let string_clone_loop=fresh"vec_string_clone_loop" and string_clone_done=fresh"vec_string_clone_done" in
  M.label output string_clone_loop;M.bytes output[0x4c;0x39;0xeb];M.branch output[0x0f;0x83]string_clone_done;
  M.bytes output[0x48;0x89;0xd8;0x48;0x6b;0xc0;24;0x49;0x03;0x04;0x24;0x48;0x89;0xc7];M.branch output[0xe8]"__xen_string_clone";
  M.bytes output[0x48;0x89;0xde;0x48;0x6b;0xf6;24;0x4c;0x01;0xf6;0x48;0x89;0x06;0x48;0x89;0x56;8;0x48;0x89;0x4e;16;0x48;0xff;0xc3];M.branch output[0xe9]string_clone_loop;
  M.label output string_clone_done;M.bytes output[0x4c;0x89;0xf0;0x4c;0x89;0xea;0x4c;0x89;0xf9;0x41;0x5f;0x41;0x5e;0x41;0x5d;0x41;0x5c;0x5b;0xc3];
  let emit_nested suffix inner_clone inner_drop =
    M.label output ("__xen_vec_nested"^suffix^"_drop");M.bytes output[0x41;0x54;0x41;0x55;0x49;0x89;0xfc;0x4d;0x8b;0x6c;0x24;8];
    let loop=fresh"vec_nested_drop_loop" and done_=fresh"vec_nested_drop_done" in M.label output loop;M.bytes output[0x4d;0x85;0xed];M.branch output[0x0f;0x84]done_;
    M.bytes output[0x49;0xff;0xcd;0x4c;0x89;0xe8;0x48;0x6b;0xc0;24;0x49;0x03;0x04;0x24;0x48;0x89;0xc7];M.branch output[0xe8]inner_drop;M.branch output[0xe9]loop;
    M.label output done_;M.bytes output[0x4c;0x89;0xe7];M.branch output[0xe8]"__xen_vec_drop";M.bytes output[0x41;0x5d;0x41;0x5c;0xc3];
    M.label output ("__xen_vec_nested"^suffix^"_clone");M.bytes output[0x53;0x41;0x54;0x41;0x55;0x41;0x56;0x41;0x57;0x49;0x89;0xfc;0x4d;0x8b;0x6c;0x24;8;0x49;0x89;0xf6;0x4c;0x89;0xef;0xbe;24;0;0;0];M.branch output[0xe8]"__xen_vec_new";
    M.bytes output[0x49;0x89;0xc7;0x31;0xdb];let cloop=fresh"vec_nested_clone_loop" and cdone=fresh"vec_nested_clone_done" in M.label output cloop;M.bytes output[0x4c;0x39;0xeb];M.branch output[0x0f;0x83]cdone;
    M.bytes output[0x48;0x89;0xd8;0x48;0x6b;0xc0;24;0x49;0x03;0x04;0x24;0x48;0x89;0xc7;0x4c;0x89;0xf6];M.branch output[0xe8]inner_clone;
    M.bytes output[0x48;0x89;0xde;0x48;0x6b;0xf6;24;0x4c;0x01;0xfe;0x48;0x89;0x06;0x48;0x89;0x56;8;0x48;0x89;0x4e;16;0x48;0xff;0xc3];M.branch output[0xe9]cloop;
    M.label output cdone;M.bytes output[0x4c;0x89;0xf8;0x4c;0x89;0xea;0x4c;0x89;0xe9;0x48;0x6b;0xc9;24;0x41;0x5f;0x41;0x5e;0x41;0x5d;0x41;0x5c;0x5b;0xc3] in
  emit_nested "" "__xen_vec_clone" "__xen_vec_drop";
  emit_nested "_string" "__xen_vec_string_clone" "__xen_vec_string_drop";
  emit_nested "_file" "__xen_vec_clone" "__xen_vec_file_drop";
  Hashtbl.iter(fun name layout->
    let label="__xen_vec_named_"^runtime_type_name name and stride=max 1(T.align_up layout.size layout.alignment) in
    emit_nested ("_named_"^runtime_type_name name) (label^"_clone") (label^"_drop");
    let rec leaves prefix=function Named n->let l=Hashtbl.find layouts n in List.concat_map(fun f->leaves(prefix+f.offset)f.typ)l.fields|(String|Vec _|File|Box _)as t->[prefix,t]|_->[] in
    let owned=leaves 0(Named name) in
    M.label output(label^"_drop");M.bytes output[0x53;0x41;0x54;0x41;0x55;0x49;0x89;0xfc;0x4d;0x8b;0x6c;0x24;8];
    let loop=fresh"vec_named_drop_loop" and done_=fresh"vec_named_drop_done" in M.label output loop;M.bytes output[0x4d;0x85;0xed];M.branch output[0x0f;0x84]done_;M.bytes output[0x49;0xff;0xcd];
    List.iter(fun(off,t)->M.bytes output[0x4c;0x89;0xe8;0x48;0x69;0xc0];M.u32 output(Int64.of_int stride);M.bytes output[0x49;0x03;0x04;0x24];if off<>0 then(M.bytes output[0x48;0x05];M.u32 output(Int64.of_int off));
      if t=File then begin M.bytes output[0x48;0x8b;0x38;0x48;0x85;0xff];let skip=fresh"vec_named_file_skip" in M.branch output[0x0f;0x88]skip;M.bytes output[0xb8;3;0;0;0;0x0f;0x05];M.label output skip end
      else begin M.bytes output[0x48;0x89;0xc7];M.branch output[0xe8](drop_runtime t)end)(List.rev owned);
    M.branch output[0xe9]loop;M.label output done_;M.bytes output[0x4c;0x89;0xe7];M.branch output[0xe8]"__xen_vec_drop";M.bytes output[0x41;0x5d;0x41;0x5c;0x5b;0xc3];
    M.label output(label^"_clone");M.bytes output[0x53;0x41;0x54;0x41;0x55;0x41;0x56;0x48;0xc7;0xc6];M.u32 output(Int64.of_int stride);M.branch output[0xe8]"__xen_vec_clone";
    M.bytes output[0x49;0x89;0xc4;0x49;0x89;0xd5;0x49;0x89;0xce;0x31;0xdb];let cloop=fresh"vec_named_clone_loop" and cdone=fresh"vec_named_clone_done" in M.label output cloop;M.bytes output[0x4c;0x39;0xeb];M.branch output[0x0f;0x83]cdone;
    List.iter(fun(off,t)->if t<>File && (match t with Box _->false|_->true)then begin M.bytes output[0x48;0x89;0xd8;0x48;0x69;0xc0];M.u32 output(Int64.of_int stride);M.bytes output[0x4c;0x01;0xe0];if off<>0 then(M.bytes output[0x48;0x05];M.u32 output(Int64.of_int off));M.bytes output[0x48;0x89;0xc7];prepare_vec_stride output t;M.branch output[0xe8](clone_runtime t);
      M.bytes output[0x48;0x89;0xdf;0x48;0x69;0xff];M.u32 output(Int64.of_int stride);M.bytes output[0x4c;0x01;0xe7];if off<>0 then(M.bytes output[0x48;0x81;0xc7];M.u32 output(Int64.of_int off));M.bytes output[0x48;0x89;0x07;0x48;0x89;0x57;8;0x48;0x89;0x4f;16]end)owned;
    M.bytes output[0x48;0xff;0xc3];M.branch output[0xe9]cloop;M.label output cdone;M.bytes output[0x4c;0x89;0xe0;0x4c;0x89;0xea;0x4c;0x89;0xf1;0x41;0x5e;0x41;0x5d;0x41;0x5c;0x5b;0xc3]
  )layouts;
  M.label output "__xen_vec_set";
  M.bytes output [0x48;0x8b;7;0x48;0x89;0x0c;0xf0;0xc3];
  M.label output "__xen_vec_push";
  M.bytes output [0x53;0x41;0x54;0x41;0x55;0x41;0x56;0x41;0x57;0x49;0x89;0xfc;0x49;0x89;0xf6;0x49;0x89;0xd7;0x4d;0x8b;0x6c;0x24;8;0x4c;0x89;0xe8;0x49;0x0f;0xaf;0xc7;0x49;0x3b;0x44;0x24;16];
  let room=fresh"vec_push_room" in M.branch output [0x0f;0x82] room;
  M.bytes output [0x49;0x8b;0x44;0x24;16;0x48;0x85;0xc0];let have=fresh"vec_have_cap" in M.branch output [0x0f;0x85] have;
  M.bytes output [0x4c;0x89;0xf8;0x48;0xc1;0xe0;2];let newcap=fresh"vec_new_cap" in M.branch output [0xe9] newcap;M.label output have;
  M.bytes output [0x48;0x01;0xc0];M.branch output [0x0f;0x82] "__xen_vec_too_large";M.label output newcap;
  M.bytes output [0x48;0x89;0xc3;0x48;0xb8];M.u64 output 0x0fffffffffffffffL;M.bytes output [0x48;0x39;0xc3];M.branch output [0x0f;0x87] "__xen_vec_too_large";
  M.bytes output [0x48;0x89;0xde;0xb8;9;0;0;0;0x31;0xff;0xba;3;0;0;0;0x41;0xba;0x22;0;0;0;0x49;0xc7;0xc0;0xff;0xff;0xff;0xff;0x45;0x31;0xc9;0x0f;0x05;0x48;0x3d;1;0xf0;0xff;0xff];M.branch output [0x0f;0x83] "__xen_vec_alloc_fail";
  M.bytes output [0x49;0x8b;0x14;0x24;0x49;0x89;0x04;0x24;0x48;0x89;0xc7;0x48;0x89;0xd6;0x4c;0x89;0xe9;0x49;0x0f;0xaf;0xcf;0xf3;0xa4;0x48;0x89;0xd7;0x49;0x8b;0x74;0x24;16;0x48;0x85;0xf6];let skip_unmap=fresh"vec_skip_unmap" in M.branch output [0x0f;0x84] skip_unmap;
  M.bytes output [0xb8;11;0;0;0;0x0f;0x05];M.label output skip_unmap;M.bytes output [0x49;0x89;0x5c;0x24;16];M.label output room;
  M.bytes output [0x49;0x8b;0x3c;0x24;0x4c;0x89;0xe9;0x49;0x0f;0xaf;0xcf;0x48;0x01;0xcf;0x4c;0x89;0xf6;0x4c;0x89;0xf9;0xf3;0xa4;0x49;0xff;0x44;0x24;8;0x41;0x5f;0x41;0x5e;0x41;0x5d;0x41;0x5c;0x5b;0xc3];
  M.label output "__xen_vec_pop";M.bytes output [0x48;0x8b;0x4f;8;0x48;0xff;0xc9;0x48;0x89;0x4f;8;0x48;0x0f;0xaf;0xce;0x48;0x8b;7;0x4c;0x8d;0x04;0x08;0x49;0x8b;0x00;0x49;0x8b;0x50;8;0x49;0x8b;0x48;16;0xc3];
  let equal name float =
    M.label output name;M.bytes output [0x48;0x8b;0x4f;8;0x48;0x3b;0x4e;8];let no=fresh"vec_unequal" and loop=fresh"vec_equal_loop" and yes=fresh"vec_equal_yes" in M.branch output [0x0f;0x85] no;
    M.bytes output [0x48;0x8b;0x3f;0x48;0x8b;0x36;0x48;0x31;0xd2];M.label output loop;M.bytes output [0x48;0x39;0xca];M.branch output [0x0f;0x83] yes;
    if float then begin M.bytes output [0xf2;0x0f;0x10;0x04;0xd7;0x66;0x0f;0x2e;0x04;0xd6];M.branch output [0x0f;0x8a] no;M.branch output [0x0f;0x85] no end
    else begin M.bytes output [0x48;0x8b;0x04;0xd7;0x48;0x3b;0x04;0xd6];M.branch output [0x0f;0x85] no end;
    M.bytes output [0x48;0xff;0xc2];M.branch output [0xe9] loop;M.label output yes;M.bytes output [0xb8;1;0;0;0;0xc3];M.label output no;M.bytes output [0x31;0xc0;0xc3] in
  equal "__xen_vec_int_equal" false;equal "__xen_vec_float_equal" true;
  M.label output "__xen_vec_bytes_equal";M.bytes output[0x48;0x8b;0x4f;8;0x48;0x3b;0x4e;8];let bytes_no=fresh"vec_bytes_no" and bytes_loop=fresh"vec_bytes_loop" and bytes_yes=fresh"vec_bytes_yes" in M.branch output[0x0f;0x85]bytes_no;
  M.bytes output[0x48;0x0f;0xaf;0xca;0x48;0x8b;0x3f;0x48;0x8b;0x36;0x48;0x31;0xd2];M.label output bytes_loop;M.bytes output[0x48;0x39;0xca];M.branch output[0x0f;0x83]bytes_yes;M.bytes output[0x8a;0x04;0x17;0x3a;0x04;0x16];M.branch output[0x0f;0x85]bytes_no;M.bytes output[0x48;0xff;0xc2];M.branch output[0xe9]bytes_loop;M.label output bytes_yes;M.bytes output[0xb8;1;0;0;0;0xc3];M.label output bytes_no;M.bytes output[0x31;0xc0;0xc3];
  M.label output "__xen_vec_f32_equal";M.bytes output[0x48;0x8b;0x4f;8;0x48;0x3b;0x4e;8];let f32_no=fresh"vec_f32_no" and f32_loop=fresh"vec_f32_loop" and f32_yes=fresh"vec_f32_yes" in M.branch output[0x0f;0x85]f32_no;M.bytes output[0x48;0x8b;0x3f;0x48;0x8b;0x36;0x48;0x31;0xd2];M.label output f32_loop;M.bytes output[0x48;0x39;0xca];M.branch output[0x0f;0x83]f32_yes;M.bytes output[0xf3;0x0f;0x10;0x04;0x97;0x0f;0x2e;0x04;0x96];M.branch output[0x0f;0x8a]f32_no;M.branch output[0x0f;0x85]f32_no;M.bytes output[0x48;0xff;0xc2];M.branch output[0xe9]f32_loop;M.label output f32_yes;M.bytes output[0xb8;1;0;0;0;0xc3];M.label output f32_no;M.bytes output[0x31;0xc0;0xc3];
  M.label output "__xen_vec_string_equal";M.bytes output[0x53;0x41;0x54;0x41;0x55;0x41;0x56;0x48;0x8b;0x4f;8;0x48;0x3b;0x4e;8];let str_no=fresh"vec_str_no" and str_loop=fresh"vec_str_loop" and str_yes=fresh"vec_str_yes" in M.branch output[0x0f;0x85]str_no;M.bytes output[0x4c;0x8b;0x27;0x4c;0x8b;0x2e;0x49;0x89;0xce;0x31;0xdb];M.label output str_loop;M.bytes output[0x4c;0x39;0xf3];M.branch output[0x0f;0x83]str_yes;M.bytes output[0x48;0x89;0xd8;0x48;0x6b;0xc0;24;0x49;0x8d;0x3c;0x04;0x49;0x8d;0x74;0x05;0x00];M.branch output[0xe8]"__xen_string_equal";M.bytes output[0x48;0x85;0xc0];M.branch output[0x0f;0x84]str_no;M.bytes output[0x48;0xff;0xc3];M.branch output[0xe9]str_loop;M.label output str_yes;M.bytes output[0xb8;1;0;0;0];let str_ret=fresh"vec_str_ret" in M.branch output[0xe9]str_ret;M.label output str_no;M.bytes output[0x31;0xc0];M.label output str_ret;M.bytes output[0x41;0x5e;0x41;0x5d;0x41;0x5c;0x5b;0xc3];
  let emit_nested_equal suffix inner =
    M.label output("__xen_vec_nested"^suffix^"_equal");M.bytes output[0x53;0x41;0x54;0x41;0x55;0x41;0x56;0x41;0x57;0x48;0x8b;0x4f;8;0x48;0x3b;0x4e;8];let no=fresh"vec_nested_equal_no" and loop=fresh"vec_nested_equal_loop" and yes=fresh"vec_nested_equal_yes" and ret=fresh"vec_nested_equal_ret" in M.branch output[0x0f;0x85]no;M.bytes output[0x4c;0x8b;0x27;0x4c;0x8b;0x2e;0x49;0x89;0xce;0x49;0x89;0xd7;0x31;0xdb];M.label output loop;M.bytes output[0x4c;0x39;0xf3];M.branch output[0x0f;0x83]yes;M.bytes output[0x48;0x89;0xd8;0x48;0x6b;0xc0;24;0x49;0x8d;0x3c;0x04;0x49;0x8d;0x74;0x05;0x00;0x4c;0x89;0xfa];M.branch output[0xe8]inner;M.bytes output[0x48;0x85;0xc0];M.branch output[0x0f;0x84]no;M.bytes output[0x48;0xff;0xc3];M.branch output[0xe9]loop;M.label output yes;M.bytes output[0xb8;1;0;0;0];M.branch output[0xe9]ret;M.label output no;M.bytes output[0x31;0xc0];M.label output ret;M.bytes output[0x41;0x5f;0x41;0x5e;0x41;0x5d;0x41;0x5c;0x5b;0xc3] in
  emit_nested_equal "" "__xen_vec_bytes_equal";emit_nested_equal "_string" "__xen_vec_string_equal";
  emit_nested_equal "_f32" "__xen_vec_f32_equal";emit_nested_equal "_f64" "__xen_vec_float_equal";
  (* Minimal bracket printer; scalar formatting is delegated to the existing routines. *)
  M.add_rodata output "__xen_lbracket" "[";M.add_rodata output "__xen_rbracket" "]";M.add_rodata output "__xen_comma" ", ";
  let printer name scalar float = M.label output name;M.bytes output [0x53;0x41;0x54;0x41;0x57;0x49;0x89;0xfc;0xbf;1;0;0;0;0x48;0x8d;0x35];M.rip_rel32 output M.Rodata "__xen_lbracket";M.bytes output [0xba;1;0;0;0;0xb8;1;0;0;0;0x0f;0x05;0x31;0xdb;0x41;0xbf;1;0;0;0];
    let loop=fresh"vec_print_loop" and done_=fresh"vec_print_done" in M.label output loop;M.bytes output [0x49;0x3b;0x5c;0x24;8];M.branch output [0x0f;0x83] done_;
    M.bytes output [0x48;0x85;0xdb];let first=fresh"vec_print_first" in M.branch output [0x0f;0x84] first;M.bytes output [0xbf;1;0;0;0;0x48;0x8d;0x35];M.rip_rel32 output M.Rodata "__xen_comma";M.bytes output [0xba;2;0;0;0;0xb8;1;0;0;0;0x0f;0x05];M.label output first;
    M.bytes output [0x49;0x8b;4;0x24];if float then M.bytes output [0xf2;0x0f;0x10;0x04;0xd8] else M.bytes output [0x48;0x8b;0x3c;0xd8];M.branch output [0xe8] scalar;M.bytes output [0x48;0xff;0xc3];M.branch output [0xe9] loop;M.label output done_;
    M.bytes output [0xbf;1;0;0;0;0x48;0x8d;0x35];M.rip_rel32 output M.Rodata "__xen_rbracket";M.bytes output [0xba;1;0;0;0;0xb8;1;0;0;0;0x0f;0x05;0x41;0x5f;0x41;0x5c;0x5b;0xc3] in
  printer "__xen_print_vec_int" "__xen_print_int" false;printer "__xen_print_vec_float" "__xen_print_float" true

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
          M.branch output[0x0f;0x88]skip;M.bytes output[0xb8;3;0;0;0;0x0f;0x05];M.label output skip
        end else M.branch output[0xe8](drop_runtime leaf)) (List.rev(owned_leaves element));
      M.bytes output[0x48;0x89;0xdf;0xbe];M.u32 output(Int64.of_int(element_stride element));
      M.bytes output[0xb8;11;0;0;0;0x0f;0x05];M.label output done_;M.bytes output[0x5b;0xc3]

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
        if leaf=File then begin M.bytes output[0x48;0x8b;0x38;0x48;0x85;0xff];let skip=fresh"vec_type_file_skip" in M.branch output[0x0f;0x88]skip;M.bytes output[0xb8;3;0;0;0;0x0f;0x05];M.label output skip end
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

let emit_file_runtime output =
  (* openat with a temporary NUL-terminated mmap copy of the Xen String. *)
  M.label output "__xen_file_open";
  M.bytes output [0x53;0x41;0x54;0x41;0x55;0x41;0x56;0x49;0x89;0xfc;0x49;0x89;0xf5;0x49;0x89;0xd6;0x48;0x31;0xc9];
  let scan=fresh "file_path_scan" and scan_done=fresh "file_path_scan_done" and nul=fresh "file_path_nul" and open_ret=fresh "file_open_ret" in
  M.label output scan;M.bytes output [0x4c;0x39;0xe9];M.branch output [0x0f;0x83] scan_done;
  M.bytes output [0x41;0x80;0x3c;0x0c;0x00];M.branch output [0x0f;0x84] nul;M.bytes output [0x48;0xff;0xc1];M.branch output [0xe9] scan;
  M.label output nul;M.bytes output [0x48;0xc7;0xc0;0x00;0xf0;0xff;0xff];M.branch output [0xe9] open_ret;
  M.label output scan_done;M.bytes output [0x4c;0x89;0xee;0x48;0xff;0xc6;0xb8;9;0;0;0;0x31;0xff;0xba;3;0;0;0;0x41;0xba;0x22;0;0;0;0x49;0xc7;0xc0;0xff;0xff;0xff;0xff;0x45;0x31;0xc9;0x0f;0x05;0x48;0x3d;1;0xf0;0xff;0xff];
  M.branch output [0x0f;0x83] open_ret;M.bytes output [0x48;0x89;0xc3;0x48;0x89;0xc7;0x4c;0x89;0xe6;0x4c;0x89;0xe9;0xf3;0xa4;0x42;0xc6;0x04;0x2b;0x00];
  M.bytes output [0xb8;1;1;0;0;0x48;0xc7;0xc7;0x9c;0xff;0xff;0xff;0x48;0x89;0xde;0x4c;0x89;0xf2;0x41;0xba;0xa4;1;0;0;0x0f;0x05;0x49;0x89;0xc4;0x48;0x89;0xdf;0x4c;0x89;0xee;0x48;0xff;0xc6;0xb8;11;0;0;0;0x0f;0x05;0x4c;0x89;0xe0];
  M.label output open_ret;M.bytes output [0x41;0x5e;0x41;0x5d;0x41;0x5c;0x5b;0xc3];
  (* Grow an anonymous mapping geometrically while reading to EOF. *)
  M.label output "__xen_file_read";M.bytes output [0x53;0x41;0x54;0x41;0x55;0x41;0x56;0x41;0x57;0x49;0x89;0xfc;0x45;0x31;0xed;0x41;0xbf;0;0x10;0;0;0xb8;9;0;0;0;0x31;0xff;0x4c;0x89;0xfe;0xba;3;0;0;0;0x41;0xba;0x22;0;0;0;0x49;0xc7;0xc0;0xff;0xff;0xff;0xff;0x45;0x31;0xc9;0x0f;0x05;0x48;0x3d;1;0xf0;0xff;0xff];
  let read_fail=fresh "file_read_fail" and read_loop=fresh "file_read_loop" and read_grow=fresh "file_read_grow" and grow_fail=fresh "file_read_grow_fail" and read_retry=fresh "file_read_retry" and read_done=fresh "file_read_done" and read_ret=fresh "file_read_ret" in
  M.branch output [0x0f;0x83] read_fail;M.bytes output [0x49;0x89;0xc5;0x45;0x31;0xf6];M.label output read_loop;
  M.bytes output [0x4d;0x39;0xfe];M.branch output [0x0f;0x83] read_grow;M.label output read_retry;
  M.bytes output [0x4c;0x89;0xe7;0x4b;0x8d;0x74;0x35;0x00;0x4c;0x89;0xfa;0x4c;0x29;0xf2;0x31;0xc0;0x0f;0x05;0x48;0x83;0xf8;0xfc];M.branch output [0x0f;0x84] read_retry;
  M.bytes output [0x48;0x85;0xc0];M.branch output [0x0f;0x88] read_fail;M.branch output [0x0f;0x84] read_done;M.bytes output [0x49;0x01;0xc6];M.branch output [0xe9] read_loop;
  M.label output read_grow;M.bytes output [0x41;0x57;0x4d;0x01;0xff];M.branch output [0x0f;0x82] grow_fail;
  M.bytes output [0xb8;9;0;0;0;0x31;0xff;0x4c;0x89;0xfe;0xba;3;0;0;0;0x41;0xba;0x22;0;0;0;0x49;0xc7;0xc0;0xff;0xff;0xff;0xff;0x45;0x31;0xc9;0x0f;0x05;0x48;0x3d;1;0xf0;0xff;0xff];M.branch output [0x0f;0x83] grow_fail;
  M.bytes output [0x48;0x89;0xc3;0x48;0x89;0xc7;0x4c;0x89;0xee;0x4c;0x89;0xf1;0xf3;0xa4;0x4c;0x89;0xef;0x48;0x8b;0x34;0x24;0xb8;11;0;0;0;0x0f;0x05;0x48;0x83;0xc4;8;0x49;0x89;0xdd];M.branch output [0xe9] read_loop;
  M.label output grow_fail;M.bytes output [0x48;0x83;0xc4;8];M.branch output [0xe9] read_fail;
  M.label output read_done;M.bytes output [0x4d;0x85;0xf6];let read_nonempty=fresh "file_read_nonempty" in M.branch output [0x0f;0x85] read_nonempty;
  M.bytes output [0x4c;0x89;0xef;0x4c;0x89;0xfe;0xb8;11;0;0;0;0x0f;0x05;0x31;0xc0;0x31;0xd2;0x31;0xc9];M.branch output [0xe9] read_ret;
  M.label output read_nonempty;M.bytes output [0x4c;0x89;0xe8;0x4c;0x89;0xf2;0x4c;0x89;0xf9];M.branch output [0xe9] read_ret;
  M.label output read_fail;M.bytes output [0x4d;0x85;0xed];let no_unmap=fresh "file_read_no_unmap" in M.branch output [0x0f;0x84] no_unmap;M.bytes output [0x4c;0x89;0xef;0x4c;0x89;0xfe;0xb8;11;0;0;0;0x0f;0x05];M.label output no_unmap;M.bytes output [0x31;0xc0;0x31;0xd2;0x48;0xc7;0xc1;0xff;0xff;0xff;0xff];M.label output read_ret;M.bytes output [0x41;0x5f;0x41;0x5e;0x41;0x5d;0x41;0x5c;0x5b;0xc3];
  M.label output "__xen_file_write";M.bytes output [0x41;0x54;0x41;0x55;0x49;0x89;0xfc;0x49;0x89;0xf5];
  let write_loop=fresh "file_write_loop" and write_retry=fresh "file_write_retry" and write_ok=fresh "file_write_ok" and write_ret=fresh "file_write_ret" in
  M.label output write_loop;M.bytes output [0x48;0x85;0xd2];M.branch output [0x0f;0x84] write_ok;M.label output write_retry;M.bytes output [0x4c;0x89;0xe7;0x4c;0x89;0xee;0xb8;1;0;0;0;0x0f;0x05;0x48;0x83;0xf8;0xfc];M.branch output [0x0f;0x84] write_retry;M.bytes output [0x48;0x85;0xc0];M.branch output [0x0f;0x88] write_ret;M.bytes output [0x49;0x01;0xc5;0x48;0x29;0xc2];M.branch output [0xe9] write_loop;M.label output write_ok;M.bytes output [0x31;0xc0];M.label output write_ret;M.bytes output [0x41;0x5d;0x41;0x5c;0xc3]

let generate ?(jit=true) ?(jit_report=false) checked =
  let program=Semantic_ir.program checked in
  try
    Semantic_ir.verify program;
    Hashtbl.clear layouts;Hashtbl.clear requested_vec_helpers;List.iter(fun (l:struct_layout)->Hashtbl.add layouts l.name l)program.layouts;
    serial := 0; let jit=if jit then Some{regions=0;recipes=[];recipe_ids=Hashtbl.create 16;report=jit_report}else None in
    let output = M.create () in M.add_data_u64 output "__xen_call_depth" 0L;
    M.add_data_u64 output "__xen_argc" 0L; M.add_data_u64 output "__xen_argv" 0L;
    M.label output "_start";
    M.bytes output [0x48;0x8b;0x04;0x24;0x48;0xff;0xc8;0x48;0x89;0x05]; M.rip_rel32 output M.Data "__xen_argc";
    M.bytes output [0x48;0x8d;0x44;0x24;0x10;0x48;0x89;0x05]; M.rip_rel32 output M.Data "__xen_argv";
    M.branch output [0xe8] ("fn_" ^ program.entry);
    if jit_report then M.branch output [0xe8] "__xen_jit_report";
    M.bytes output [0x48;0x31;0xff;0xb8;0x3c;0;0;0;0x0f;0x05];
    emit_print_runtime output; emit_string_runtime output; emit_vec_runtime output; emit_file_runtime output;
    while M.position output mod 16 <> 0 do M.u8 output 0x90 done;
    M.label output "__xen_read_builtin"; emit_hex output read_builtin_runtime_hex;
    List.iter (emit_function output jit) program.functions;emit_requested_vec_helpers output;
    (match jit with Some state when state.regions>0->
      Jit_runtime.add_templates output state.recipes;Jit_runtime.emit_compiler output ~report:jit_report|_->());
    if jit_report then Jit_runtime.emit_report output;
    let entry = Hashtbl.find output.labels "_start" in Ok (Elf_writer.static_x86_64 ~entry output)
  with Unsupported error -> Error error | M.Missing_label label ->
    Error { span = None; message = "missing machine label '" ^ label ^ "'" }

let write path executable =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_bytes channel executable);
  Unix.chmod path 0o755
