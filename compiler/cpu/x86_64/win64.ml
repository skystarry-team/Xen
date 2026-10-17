(* SPDX-License-Identifier: Apache-2.0 *)
(* Generated runtime has the additional MIT OR Apache-2.0 permission in LICENSE. *)
module M = Machine_ir
type scalar = I64 | F32 | F64
type source = Gp of int | Fp of int | Stack of int | Immediate of int64
type argument = { scalar : scalar; source : source }
type unwind_operation = Push_nonvol of int | Alloc_stack of int | Set_frame of int * int
type unwind_code = { code_offset : int; operation : unwind_operation }
type function_frame = {
  begin_offset : int; end_offset : int; prolog_size : int; codes : unwind_code list;
}

let stack_allocate output size =
  if size<0 || size>0x7fffffff || size mod 8<>0 then
    invalid_arg "Win64 stack allocation must be a nonnegative signed-32-bit multiple of eight";
  let pages=size/4096 and tail=size mod 4096 in
  if pages>0 then begin
    M.bytes output[0x41;0xbb];M.u32 output(Int64.of_int pages);
    let loop="__xen_win64_probe_"^string_of_int(M.position output)in
    M.label output loop;
    M.bytes output[0x48;0x81;0xec];M.u32 output 4096L;
    M.bytes output[0xf6;0x04;0x24;0;0x49;0xff;0xcb];
    M.branch output[0x0f;0x85]loop
  end;
  if tail>0 then begin
    M.bytes output[0x48;0x81;0xec];M.u32 output(Int64.of_int tail);
    M.bytes output[0xf6;0x04;0x24;0]
  end

let emit_bridge output ~label ~library ~symbol ~arguments ~result =
  if List.length arguments>32 then invalid_arg "Win64 bridge supports at most 32 scalar arguments";
  if label="" || Hashtbl.mem output.M.labels label then invalid_arg "invalid/duplicate Win64 bridge label";
  if library="" || symbol="" || String.contains library '\000' || String.contains symbol '\000' then
    invalid_arg "invalid Win64 import name";
  List.iter(fun a->match a.scalar,a.source with
    |I64,Gp r when r>=0 && r<=15 && r<>4 && r<>5->()
    |(F32|F64),Fp r when r>=0 && r<=15->()
    |_,Stack offset when offset>=0 && offset<=0x7fffffef && offset mod 8=0->()
    |_,Immediate _->()
    |_->invalid_arg "invalid Win64 bridge scalar source")arguments;
  let imported=M.import output library symbol in
  let begin_offset=M.position output in
  M.label output label;
  (* Establish RBP before dynamic alignment. Windows unwinds body allocations
     through this stable frame; do not describe an invented fixed RSP offset. *)
  M.bytes output[0x55;0x48;0x89;0xe5];
  let gp_slot r= -8*(r+1) and fp_slot r= -144-16*r in
  let displacement n=M.u32 output(Int64.of_int n)in
  (* Spill region ends at RBP-384. Shadow/stack arguments are BELOW it, even
     when AND rounds RSP down by eight. No allocation here spans a page. *)
  let allocation=(384+32+8*max 0(List.length arguments-4)+15)/16*16 in
  M.bytes output[0x48;0x81;0xec];displacement allocation;
  M.bytes output[0x48;0x83;0xe4;0xf0];
  List.iter(fun r->
    M.bytes output[(if r>=8 then 0x4c else 0x48);0x89;0x85 lor((r land 7)lsl 3)];
    displacement(gp_slot r))[0;1;2;3;6;7;8;9;10;11;12;13;14;15];
  for r=0 to 15 do
    M.u8 output 0xf3;if r>=8 then M.u8 output 0x44;
    M.bytes output[0x0f;0x7f;0x85 lor((r land 7)lsl 3)];displacement(fp_slot r)
  done;
  List.iteri(fun index a->
    (match a.source with
    |Gp r->M.bytes output[0x48;0x8b;0x85];displacement(gp_slot r)
    |Fp r->M.bytes output[0x48;0x8b;0x85];displacement(fp_slot r)
    |Stack offset->M.bytes output[0x48;0x8b;0x85];displacement(16+offset)
    |Immediate value->M.bytes output[0x48;0xb8];M.u64 output value);
    if index>=4 then begin
      M.bytes output[0x48;0x89;0x84;0x24];displacement(32+8*(index-4))
    end else match a.scalar with
    |I64->let reg=List.nth[1;2;8;9]index in
        M.bytes output[(if reg>=8 then 0x49 else 0x48);0x89;0xc0 lor(reg land 7)]
    |F32|F64->M.u8 output 0x66;if a.scalar=F64 then M.u8 output 0x48;
        M.bytes output[0x0f;0x6e;0xc0 lor(index lsl 3)])arguments;
  M.bytes output[0xff;0x15];M.rip_rel32 output M.Data imported;
  for r=0 to 15 do
    if r<>0 || result=None || result=Some I64 then begin
      M.u8 output 0xf3;if r>=8 then M.u8 output 0x44;
      M.bytes output[0x0f;0x6f;0x85 lor((r land 7)lsl 3)];displacement(fp_slot r)
    end
  done;
  List.iter(fun r->M.bytes output[(if r>=8 then 0x4c else 0x48);0x8b;
    0x85 lor((r land 7)lsl 3)];displacement(gp_slot r))[1;2;8;9;10];
  if result=None then M.bytes output[0x31;0xc0];
  M.bytes output[0x48;0x8d;0x65;0;0x5d;0xc3];
  {begin_offset;end_offset=M.position output;prolog_size=4;
   codes=[{code_offset=1;operation=Push_nonvol 5};{code_offset=4;operation=Set_frame(5,0)}]}
