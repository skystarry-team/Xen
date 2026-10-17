(* SPDX-License-Identifier: MIT OR Apache-2.0 *)
(* Controlled Win64 code, independent of the Xen lowering/runtime. *)
module M = Xen_x86_64.Machine_ir
module P = Xen_windows.Pe_writer

let layout_image () =
  P.executable ~entry:0 ~code_size:16 ~rodata:(String.make 0x1008 '\000')
    ~data:(String.make 8 '\000') ~bss_size:0x1000 ~imports:[] ~functions:[]
    ~pointers:[
      {at={section=Data;offset=0};target={section=Code;offset=1}};
      {at={section=Rodata;offset=0x1000};target={section=Rodata;offset=0}};
      {at={section=Code;offset=8};target={section=Code;offset=0}};
      {at={section=Rodata;offset=0xff8};target={section=Data;offset=8}}]
    ~encode:(fun ~code_address:_ ~rodata_address:_ ~data_address:_ ~import_address:_->
      Bytes.of_string("\195"^String.make 15 '\000')) ()

let image mode =
  let output=M.create () and imported=ref [] in
  let kernel="KERNEL32.dll" in
  let call library symbol =
    M.bytes output [0xff;0x15];let offset=M.position output in M.u32 output 0L;
    imported:=(offset,library,symbol)::!imported in
  let call_kernel=call kernel in
  let write_symbol=if mode="missing-symbol"then "XenMissingExportForTest"else "WriteFile"in
  let extra_library=if mode="missing-dll"then "xen-missing-dependency-for-test.dll"else "SHELL32.dll"in
  let message="xen-pe-fixture\n" in
  M.add_rodata output "message" message;
  M.add_data_u64 output "pointer" 0L;
  (* The initialized pointer occupies eight bytes; the rest is zero-filled. *)
  Hashtbl.add output.M.data_labels "zero_tail" 0x1000;
  M.label output "entry";
  M.bytes output [0x48;0x83;0xec;0x38]; (* shadow, fifth arg, locals; RSP aligned *)
  M.branch output [0xe8] "helper";
  M.bytes output [0x85;0xc0];M.branch output [0x0f;0x85] "fail";
  (* The host runner supplies a real NUL handle; ReadFile must observe EOF. *)
  M.u8 output 0xb9;M.u32 output (-10L);call_kernel "GetStdHandle";
  M.bytes output [0x48;0x89;0xc1;0x48;0x8d;0x54;0x24;0x28;0x41;0xb8;1;0;0;0;
    0x4c;0x8d;0x4c;0x24;0x30;0x48;0xc7;0x44;0x24;0x20;0;0;0;0];
  call_kernel "ReadFile";
  M.bytes output [0x85;0xc0];M.branch output [0x0f;0x84] "fail";
  M.bytes output [0x83;0x7c;0x24;0x30;0];M.branch output [0x0f;0x85] "fail";
  M.bytes output [0x31;0xc9];call_kernel "GetModuleHandleW";
  M.bytes output [0x48;0x89;0x44;0x24;0x28]; (* keep actual image base *)
  M.bytes output [0x48;0x8b;0x15];M.rip_rel32 output M.Data "pointer";
  M.bytes output [0x48;0x8d;0x0d];M.rip_rel32 output M.Rodata "message";
  M.bytes output [0x48;0x39;0xca];M.branch output [0x0f;0x85] "fail";
  M.bytes output [0x48;0x83;0x3d];M.rip_rel32 output M.Data "zero_tail";
  (* RIP displacement includes the immediate byte following the disp32. *)
  let zero_fixup=List.hd output.M.rip_fixups in
  M.u8 output 0;M.branch output [0x0f;0x85] "fail";
  M.u8 output 0xb9;M.u32 output (-11L);call_kernel "GetStdHandle";
  M.bytes output [0x48;0x89;0xc1;0x48;0x8b;0x15];M.rip_rel32 output M.Data "pointer";
  M.bytes output [0x41;0xb8];M.u32 output (Int64.of_int(String.length message));
  M.bytes output [0x4c;0x8d;0x4c;0x24;0x30;0x48;0xc7;0x44;0x24;0x20;0;0;0;0];
  call_kernel write_symbol;
  M.bytes output [0x85;0xc0];M.branch output [0x0f;0x84] "fail";
  M.bytes output [0x83;0x7c;0x24;0x30;String.length message];M.branch output [0x0f;0x85] "fail";
  (* Emit the actual load base as eight binary bytes, after the message. *)
  M.u8 output 0xb9;M.u32 output (-11L);call_kernel "GetStdHandle";
  M.bytes output [0x48;0x89;0xc1;0x48;0x8d;0x54;0x24;0x28;0x41;0xb8;8;0;0;0;
    0x4c;0x8d;0x4c;0x24;0x30;0x48;0xc7;0x44;0x24;0x20;0;0;0;0];call_kernel write_symbol;
  M.bytes output [0x85;0xc0];M.branch output [0x0f;0x84] "fail";
  M.bytes output [0x83;0x7c;0x24;0x30;8];M.branch output [0x0f;0x85] "fail";
  M.bytes output [0x31;0xc9];call_kernel "ExitProcess";M.bytes output [0x0f;0x0b];
  M.label output "fail";M.bytes output [0xb9;91;0;0;0];call_kernel "ExitProcess";
  M.bytes output [0x0f;0x0b];
  let entry_end=M.position output in
  M.label output "helper";
  let helper=M.position output in
  M.bytes output [0x55;0x53;0x48;0x83;0xec;0x28;0x48;0x8d;0x6c;0x24;0x20];
  (* Temporary body allocation keeps RSP aligned and uses the stable RBP frame
     for unwinding. The native tests stop before and after each adjustment. *)
  M.bytes output [0x48;0x83;0xec;0x10;0x48;0x89;0x04;0x24;0xbb;42;0;0;0;
    0x48;0x8b;0x04;0x24;0x48;0x83;0xc4;0x10;0x31;0xc0;
    0x48;0x8d;0x65;8;0x5b;0x5d;0xc3];
  let helper_end=M.position output in
  let functions : P.runtime_function list = [
    {begin_offset=0;end_offset=entry_end;prolog_size=4;
      codes=[{code_offset=4;operation=Alloc_stack 56}]};
    {begin_offset=helper;end_offset=helper_end;prolog_size=11;
      codes=[{code_offset=1;operation=Push_nonvol 5};{code_offset=2;operation=Push_nonvol 3};
        {code_offset=6;operation=Alloc_stack 40};{code_offset=11;operation=Set_frame(5,32)}]}]in
  let imports=(extra_library,"CommandLineToArgvW")::List.map(fun(_,lib,sym)->lib,sym)(List.rev !imported)in
  P.executable ~entry:0 ~code_size:(M.position output)
    ~rodata:(Buffer.contents output.M.rodata) ~data:(Buffer.contents output.M.data) ~bss_size:0x2000
    ~imports ~pointers:[{at={section=Data;offset=0};target={section=Rodata;offset=0}}] ~functions
    ~encode:(fun ~code_address ~rodata_address ~data_address ~import_address->
      let code=M.encode ~code_address ~rodata_address ~data_address output in
      let patch offset value=for i=0 to 3 do Bytes.set code (offset+i)
        (Char.chr Int64.(to_int(logand(shift_right_logical value(8*i))255L)))done in
      List.iter(fun(offset,library,symbol)->patch offset
        Int64.(sub(import_address ~library ~symbol)(add code_address(of_int(offset+4)))))!imported;
      (* M's basic RIP fixup ends at disp32; this CMP has an immediate too. *)
      patch zero_fixup.offset Int64.(sub(add data_address 0x1000L)
        (add code_address(of_int(zero_fixup.offset+5))));code) ()

let () =
  if Array.length Sys.argv<>3 then failwith "usage: windows_fixture MODE OUTPUT";
  let mode=Sys.argv.(1)in
  if not(List.mem mode ["smoke";"missing-dll";"missing-symbol";"layout"])then failwith "unknown fixture mode";
  let channel=open_out_bin Sys.argv.(2)in
  Fun.protect ~finally:(fun()->close_out channel)(fun()->
    output_bytes channel(if mode="layout"then layout_image()else image mode))
