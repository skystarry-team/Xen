(* SPDX-License-Identifier: Apache-2.0 *)
type fixup = { offset : int; target : string }
type section = Rodata | Data
type rip_fixup = { offset : int; target : string; section : section }
type unwind_operation = Push_nonvol of int | Alloc_stack of int | Set_frame of int * int
  | Save_nonvol of int * int | Save_xmm of int * int
type unwind_code = { code_offset : int; operation : unwind_operation }
type function_frame = {
  begin_offset : int; end_offset : int; prolog_size : int; codes : unwind_code list;
}
type t = {
  buffer : Buffer.t; labels : (string, int) Hashtbl.t; mutable fixups : fixup list;
  rodata : Buffer.t; data : Buffer.t;
  rodata_labels : (string, int) Hashtbl.t; data_labels : (string, int) Hashtbl.t;
  mutable rip_fixups : rip_fixup list;
  mutable imports : (string * string * string) list;
  mutable frames : function_frame list;
  mutable helper_prologue : (int -> (unit -> unit) * (unit -> unit)) option;
  mutable helper_return : (unit -> unit) option;
  mutable helper_end : (unit -> unit) option;
  mutable align_calls : bool;
}

exception Missing_label of string

let create () = {buffer = Buffer.create 4096; labels = Hashtbl.create 64; fixups = [];
  rodata = Buffer.create 1024; data = Buffer.create 64;
  rodata_labels = Hashtbl.create 32; data_labels = Hashtbl.create 8; rip_fixups = []; imports=[]; frames=[];
  helper_prologue=None;helper_return=None;helper_end=None;align_calls=false }
let position output = Buffer.length output.buffer
let u8 output value = Buffer.add_char output.buffer (Char.chr (value land 0xff))
let u32 output value =
  for shift = 0 to 3 do u8 output (Int64.to_int (Int64.shift_right_logical value (shift * 8))) done
let u64 output value =
  for shift = 0 to 7 do u8 output (Int64.to_int (Int64.shift_right_logical value (shift * 8))) done
let bytes output values = List.iter (u8 output) values
let label output name = Hashtbl.replace output.labels name (position output)
let end_helpers output =
  Option.iter(fun finish->finish())output.helper_end;
  output.helper_end<-None;output.helper_return<-None
(* Explicit function boundaries/returns, never inferred from instruction bytes.
   The default keeps the established CPU helper ABI and byte stream. *)
let function_label ?(frame=5) output name =
  end_helpers output;label output name;
  Option.iter(fun prologue->let return,finish=prologue frame in
    output.helper_return<-Some return;output.helper_end<-Some finish)output.helper_prologue
let ret output = match output.helper_return with Some return->return()|None->u8 output 0xc3
let rel32 output target =
  let offset = position output in u32 output 0L;
  output.fixups <- { offset; target } :: output.fixups
(* Internal callees take their arguments in GP/FP registers (aggregate inputs
   are pointers). This optional call policy aligns packed/dynamic temporaries,
   preserving RAX/results and the exact original RSP. R11 is not an input or
   result register of that ABI; preserve its caller value as well. *)
let prepare_call output =
  bytes output[0x41;0x53;0x49;0x89;0xe3;0x48;0x83;0xe4;0xf0;
    0x48;0x83;0xec;0x10;0x4c;0x89;0x1c;0x24]
let finish_call output = bytes output[0x48;0x8b;0x24;0x24;0x41;0x5b]
let branch output opcode target =
  let align=output.align_calls && opcode=[0xe8]in
  if align then prepare_call output;
  bytes output opcode;rel32 output target;
  if align then finish_call output
let call_indirect output register =
  if register<0 || register>15 || register=4 then invalid_arg "invalid indirect call register";
  if output.align_calls then begin
    prepare_call output;
    if register=11 then bytes output[0x4d;0x8b;0x1b]
  end;
  if register>=8 then u8 output 0x41;
  bytes output[0xff;0xd0 lor(register land 7)];
  if output.align_calls then finish_call output
let add_rodata output name value =
  Hashtbl.replace output.rodata_labels name (Buffer.length output.rodata);
  Buffer.add_string output.rodata value
let add_rodata_u64 output name value =
  Hashtbl.replace output.rodata_labels name (Buffer.length output.rodata);
  for shift = 0 to 7 do Buffer.add_char output.rodata
    (Char.chr (Int64.to_int (Int64.shift_right_logical value (shift * 8)) land 0xff)) done
let add_data_u64 output name value =
  Hashtbl.replace output.data_labels name (Buffer.length output.data);
  for shift = 0 to 7 do Buffer.add_char output.data
    (Char.chr (Int64.to_int (Int64.shift_right_logical value (shift * 8)) land 0xff)) done
let rip_rel32 output section target =
  let offset = position output in u32 output 0L;
  output.rip_fixups <- { offset; target; section } :: output.rip_fixups

let import output library symbol =
  match List.find_opt(fun(l,s,_)->l=library && s=symbol)output.imports with
  |Some(_,_,label)->label
  |None->let label="__xen_import_"^string_of_int(List.length output.imports)in
      add_data_u64 output label 0L;
      output.imports<-output.imports@[library,symbol,label];label

let encode ?(code_address=0L) ?(rodata_address=0L) ?(data_address=0L)
    ?import_address output =
  let encoded = Bytes.of_string (Buffer.contents output.buffer) in
  List.iter (fun (fixup : fixup) ->
    let target = match Hashtbl.find_opt output.labels fixup.target with
      | Some target -> target | None -> raise (Missing_label fixup.target)
    in
    let displacement = Int64.of_int (target - (fixup.offset + 4)) in
    for shift = 0 to 3 do
      Bytes.set encoded (fixup.offset + shift)
        (Char.chr (Int64.to_int (Int64.shift_right_logical displacement (shift * 8)) land 0xff))
    done) output.fixups;
  List.iter (fun (fixup : rip_fixup) ->
    let labels, base = match fixup.section with
      | Rodata -> output.rodata_labels, rodata_address
      | Data -> output.data_labels, data_address
    in
    let imported = match fixup.section, import_address with
      | Data, Some address -> List.find_map(fun(library,symbol,label)->
          if label=fixup.target then Some(address ~library ~symbol)else None)output.imports
      | _ -> None in
    let target = match imported with Some address->address|None->
      match Hashtbl.find_opt labels fixup.target with
      | Some target -> Int64.add base (Int64.of_int target)
      | None -> raise (Missing_label fixup.target)
    in
    let next = Int64.add code_address (Int64.of_int (fixup.offset + 4)) in
    let displacement = Int64.sub target next in
    for shift = 0 to 3 do Bytes.set encoded (fixup.offset + shift)
      (Char.chr (Int64.to_int (Int64.shift_right_logical displacement (shift * 8)) land 0xff)) done
  ) output.rip_fixups;
  encoded
