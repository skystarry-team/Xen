(* SPDX-License-Identifier: Apache-2.0 *)
(* Generated runtime code has the additional MIT OR Apache-2.0 permission in LICENSE.
   Linux syscall numbers, flags, register assignment, process entry and glibc
   startup belong here. See Xen_x86_64.Runtime_intf for the inline service ABI. *)
module M = Xen_x86_64.Machine_ir
let open_read_flags = 0
let open_write_flags = 577
let stack_allocate output size =
  if size>0 then (M.bytes output[0x48;0x81;0xec];M.u32 output(Int64.of_int size))
let function_prologue output =
  M.bytes output[0x55;0x48;0x89;0xe5];fun()->M.bytes output[0xc9;0xc3]
let trap output = M.bytes output [0x0f;0x05]
let syscall output number = M.u8 output 0xb8;M.u32 output (Int64.of_int number);trap output
let read output = M.bytes output [0x31;0xc0];trap output
let write output = syscall output 1
let close output = syscall output 3
let unmap output = syscall output 11
let exit output status =
  M.u8 output 0xbf;M.u32 output (Int64.of_int status);syscall output 60
let alloc output =
  M.bytes output [0xb8;9;0;0;0;0x31;0xff;0xba;3;0;0;0;0x41;0xba;0x22;0;0;0;
    0x49;0xc7;0xc0;0xff;0xff;0xff;0xff;0x45;0x31;0xc9];trap output
let open_ output =
  M.bytes output [0x48;0x89;0xf2;0x48;0x89;0xfe;0x48;0xc7;0xc7;0x9c;0xff;0xff;0xff;
    0x41;0xba;0xa4;1;0;0];syscall output 257
let platform_call _ service = Error("platform service '"^Platform_service.name service^
  "' is unavailable through this target's intrinsic; use std.platform")
let raw_syscall output ~arity =
  let load displacement bytes=M.bytes output bytes;M.u32 output(Int64.of_int displacement)in
  load((arity-1)*8)[0x48;0x8b;0x84;0x24];
  let regs=[[0x48;0x8b;0xbc;0x24];[0x48;0x8b;0xb4;0x24];[0x48;0x8b;0x94;0x24];
    [0x4c;0x8b;0x94;0x24];[0x4c;0x8b;0x84;0x24];[0x4c;0x8b;0x8c;0x24]]in
  List.iteri(fun i bytes->if i<arity-1 then load((arity-2-i)*8)bytes)regs;
  M.bytes output[0x48;0x81;0xc4];M.u32 output(Int64.of_int(arity*8));trap output
let start output =
  M.label output "_start";
  M.bytes output [0x48;0x8b;0x04;0x24;0x48;0xff;0xc8;0x48;0x89;0x05];
  M.rip_rel32 output M.Data "__xen_argc";
  M.bytes output [0x48;0x8d;0x44;0x24;0x10;0x48;0x89;0x05];
  M.rip_rel32 output M.Data "__xen_argv"
let foreign_start output ~main =
  start output;
  let startup=M.import output "libc.so.6" "__libc_start_main" in
  M.bytes output[0x49;0x89;0xd1;0x48;0x8b;0x34;0x24;0x48;0x8d;0x54;0x24;0x08];
  M.bytes output[0x48;0x8d;0x3d];M.rel32 output main;
  M.bytes output[0x31;0xc9;0x45;0x31;0xc0;0x31;0xed;0x48;0x83;0xe4;0xf0;0x50;0x54;0xff;0x15];
  M.rip_rel32 output M.Data startup;M.bytes output[0x0f;0x0b];Ok ()
let executable ~entry output =
  if output.M.imports=[] then Elf_writer.static_x86_64 ~entry output
  else Elf_writer.dynamic_x86_64 ~entry output
