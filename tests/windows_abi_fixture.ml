(* SPDX-License-Identifier: MIT OR Apache-2.0 *)
(* Executable Win64 ABI probes, using the same bridge and PE adapter that the
   future language backend will compose. No hand-patched import displacements. *)
module M = Xen_x86_64.Machine_ir
module W = Xen_x86_64.Win64
module P = Xen_windows.Pe_writer
module Image = Xen_windows_x86_64.Pe_image

let gp_values=[0,0x1000L;1,0x1001L;2,0x5566L;3,0x1003L;6,0x3344L;7,0x1122L;
  8,0x1008L;9,0x1009L;10,0x1010L;12,0x1012L;13,0x1013L;14,0x1014L;15,0x1015L]
let fp_low r=match r with
  |0->Int64.bits_of_float 2.5|2->Int64.of_int32(Int32.bits_of_float(-1.25))
  |4->Int64.bits_of_float 4.5|_->Int64.of_int(0x2000+r)
let fp_high r=Int64.of_int(0x3000+r)
let image unaligned =
  let output=M.create()and frames=ref[]in
  let add frame=frames:=frame::!frames in
  let mov r value=M.bytes output[(if r>=8 then 0x49 else 0x48);0xb8 lor(r land 7)];M.u64 output value in
  let compare_rax value=mov 11 value;M.bytes output[0x4c;0x39;0xd8];M.branch output[0x0f;0x85]"fail"in
  let immediate scalar value : W.argument={scalar;source=Immediate value}in
  let mixed : W.argument list=[{scalar=I64;source=Gp 7};{scalar=F64;source=Fp 0};
    {scalar=I64;source=Gp 6};{scalar=F32;source=Fp 2};{scalar=I64;source=Gp 2};
    {scalar=F64;source=Fp 4};{scalar=I64;source=Stack 0};
    immediate F32(Int64.of_int32(Int32.bits_of_float 6.25))]in
  let mixed_fp=List.mapi(fun i scalar->immediate scalar(match scalar with
    |W.I64->Int64.of_int(i+1)|W.F32->Int64.of_int32(Int32.bits_of_float(float(i+1)))
    |W.F64->Int64.bits_of_float(float(i+1))))[W.I64;F64;F32;I64;F64;F32;I64;I64]in
  let mixed_f32=List.mapi(fun i scalar->immediate scalar(match scalar with
    |W.I64->Int64.of_int(i+1)|W.F32->Int64.of_int32(Int32.bits_of_float(float(i+1)))
    |W.F64->Int64.bits_of_float(float(i+1))))[W.F32;F64;I64;F32;I64;F64;I64;F32]in
  let kernel="KERNEL32.dll"and first="xen-abi-first.dll"and second="xen-abi-second.dll"in
  List.init 16(fun r->
    M.add_rodata_u64 output("fp"^string_of_int r)(fp_low r);
    M.add_rodata_u64 output("fp_high"^string_of_int r)(fp_high r))|>ignore;
  M.add_data_u64 output "bridge_pointer" 0L;
  M.add_data_u64 output "expected_sp" 0L;
  M.add_data_u64 output "expected_bp" 0L;
  M.label output "entry";M.bytes output[0x55;0x48;0x89;0xe5];
  W.stack_allocate output 512;
  if unaligned then M.bytes output[0x48;0x83;0xec;8];
  M.bytes output[0x48;0x8d;0x05];M.rel32 output "large_frame";
  M.branch output[0xe8]"thread_bridge";compare_rax 0x9876L;
  M.bytes output[0x48;0x89;0x25];M.rip_rel32 output M.Data "expected_sp";
  M.bytes output[0x48;0x89;0x2d];M.rip_rel32 output M.Data "expected_bp";
  List.iter(fun(r,v)->mov r v)gp_values;
  for r=0 to 15 do
    M.u8 output 0xf3;if r>=8 then M.u8 output 0x44;
    M.bytes output[0x0f;0x6f;0x05 lor((r land 7)lsl 3)];
    M.rip_rel32 output M.Rodata("fp"^string_of_int r)
  done;
  M.bytes output[0x48;0xc7;0x04;0x24];M.u32 output 0x7788L;
  M.bytes output[0xff;0x15];M.rip_rel32 output M.Data "bridge_pointer";
  compare_rax 0x123456789abcdefL;
  M.bytes output[0x48;0x3b;0x25];M.rip_rel32 output M.Data "expected_sp";
  M.branch output[0x0f;0x85]"fail";
  M.bytes output[0x48;0x3b;0x2d];M.rip_rel32 output M.Data "expected_bp";
  M.branch output[0x0f;0x85]"fail";
  List.iter(fun(r,v)->mov 11 v;
    M.bytes output[(if r>=8 then 0x4d else 0x4c);0x39;0xd8 lor(r land 7)];
    M.branch output[0x0f;0x85]"fail")(List.filter(fun(r,_)->r<>0)gp_values);
  (* Compare full 128-bit FP values without destructively using an FP scratch. *)
  let check_fp first_reg=for r=first_reg to 15 do
    M.u8 output 0xf3;if r>=8 then M.u8 output 0x44;
    M.bytes output[0x0f;0x7f;0x84 lor((r land 7)lsl 3);0x24];M.u32 output 16L;
    List.iteri(fun i value->
      M.bytes output[0x81;0x7c;0x24;16+4*i];M.u32 output value;
      M.branch output[0x0f;0x85]"fail")
      [fp_low r;Int64.shift_right_logical(fp_low r)32;fp_high r;0L]
  done in check_fp 0;
  M.branch output[0xe8]"void_bridge";compare_rax 0L;check_fp 0;
  mov 0 40L;M.branch output[0xe8]"first_export";compare_rax 41L;
  mov 0 40L;M.branch output[0xe8]"second_export";compare_rax 42L;
  M.branch output[0xe8]"double_bridge";
  M.bytes output[0x66;0x48;0x0f;0x7e;0xc0];compare_rax(Int64.bits_of_float 36.0);check_fp 1;
  M.branch output[0xe8]"float_bridge";
  M.bytes output[0x66;0x0f;0x7e;0xc0];compare_rax(Int64.of_int32(Int32.bits_of_float 36.0));check_fp 1;
  M.branch output[0xe8]"exit_ok";M.bytes output[0x0f;0x0b];
  M.label output "fail";M.branch output[0xe8]"exit_fail";M.bytes output[0x0f;0x0b];
  (* This non-returning test entry intentionally sets nonvolatile sentinels.
     Only the reusable bridges and probed helper have unwind descriptions. *)
  let large_begin=M.position output in M.label output "large_frame";
  M.bytes output[0x55;0x48;0x89;0xe5];W.stack_allocate output (128*1024+32);
  M.bytes output[0x48;0xc7;0x04;0x24];M.u32 output 0x9876L;
  M.bytes output[0x48;0x8b;0x04;0x24;0x48;0x8d;0x65;0;0x5d;0xc3];
  add{W.begin_offset=large_begin;end_offset=M.position output;prolog_size=4;
      codes=[{code_offset=1;operation=Push_nonvol 5};{code_offset=4;operation=Set_frame(5,0)}]};
  let bridge label library symbol arguments result=
    add(W.emit_bridge output ~label ~library ~symbol ~arguments ~result)in
  bridge "mixed_bridge" first "probe" mixed(Some I64);
  bridge "void_bridge" first "probe" mixed None;
  bridge "first_export" first "same_export" [{scalar=I64;source=Gp 0}](Some I64);
  bridge "second_export" second "same_export" [{scalar=I64;source=Gp 0}](Some I64);
  bridge "double_bridge" first "double_result" mixed_fp(Some F64);
  bridge "float_bridge" first "float_result" mixed_f32(Some F32);
  bridge "thread_bridge" first "run_on_small_stack" [{scalar=I64;source=Gp 0}](Some I64);
  bridge "exit_ok" kernel "ExitProcess" [immediate I64 0L]None;
  bridge "exit_fail" kernel "ExitProcess" [immediate I64 91L]None;
  Image.executable ~entry:"entry" ~functions:!frames ~pointers:[
    {P.at={section=Data;offset=0};target={section=Code;offset=Hashtbl.find output.M.labels "mixed_bridge"}}]output

let () =
  if Array.length Sys.argv<>3 then failwith "usage: windows_abi_fixture aligned|unaligned OUTPUT";
  let unaligned=match Sys.argv.(1)with "aligned"->false|"unaligned"->true|_->failwith "unknown alignment"in
  let bytes=image unaligned in
  let channel=open_out_bin Sys.argv.(2)in
  Fun.protect ~finally:(fun()->close_out channel)(fun()->output_bytes channel bytes)
