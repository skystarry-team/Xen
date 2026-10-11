(* SPDX-License-Identifier: Apache-2.0 *)
type operand = Frame of int | Literal
type operand_patch = { at:int; width:int; operand:operand }
type fixup = { offset : int; target : string }
type section = Rodata | Data
type rip_fixup = { offset : int; target : string; section : section }
type t = {
  record_operands:bool; mutable operand_patches:operand_patch list;
  buffer : Buffer.t; labels : (string, int) Hashtbl.t; mutable fixups : fixup list;
  rodata : Buffer.t; data : Buffer.t;
  rodata_labels : (string, int) Hashtbl.t; data_labels : (string, int) Hashtbl.t;
  mutable rip_fixups : rip_fixup list;
}

exception Missing_label of string

let create ?(record_operands=false) () = { record_operands;operand_patches=[];buffer = Buffer.create 4096; labels = Hashtbl.create 64; fixups = [];
  rodata = Buffer.create 1024; data = Buffer.create 64;
  rodata_labels = Hashtbl.create 32; data_labels = Hashtbl.create 8; rip_fixups = [] }
let position output = Buffer.length output.buffer
let u8 output value = Buffer.add_char output.buffer (Char.chr (value land 0xff))
let u32 output value =
  for shift = 0 to 3 do u8 output (Int64.to_int (Int64.shift_right_logical value (shift * 8))) done
let u64 output value =
  for shift = 0 to 7 do u8 output (Int64.to_int (Int64.shift_right_logical value (shift * 8))) done
let operand output width operand emit =
  if output.record_operands then output.operand_patches <- {at=position output;width;operand}::output.operand_patches;
  emit ()
let frame32 output id value = operand output 4 (Frame id) (fun()->u32 output value)
let literal64 output value = operand output 8 Literal (fun()->u64 output value)
let bytes output values = List.iter (u8 output) values
let label output name = Hashtbl.replace output.labels name (position output)
let rel32 output target =
  let offset = position output in u32 output 0L;
  output.fixups <- { offset; target } :: output.fixups
let branch output opcode target = bytes output opcode; rel32 output target
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

let encode ?(code_address=0L) ?(rodata_address=0L) ?(data_address=0L) output =
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
    let target = match Hashtbl.find_opt labels fixup.target with
      | Some target -> Int64.add base (Int64.of_int target)
      | None -> raise (Missing_label fixup.target)
    in
    let next = Int64.add code_address (Int64.of_int (fixup.offset + 4)) in
    let displacement = Int64.sub target next in
    for shift = 0 to 3 do Bytes.set encoded (fixup.offset + shift)
      (Char.chr (Int64.to_int (Int64.shift_right_logical displacement (shift * 8)) land 0xff)) done
  ) output.rip_fixups;
  encoded
