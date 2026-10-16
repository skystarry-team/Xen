(* SPDX-License-Identifier: Apache-2.0 *)
(* Generated runtime code carries the additional MIT OR Apache-2.0 permission
   specified in the root LICENSE. Linux AArch64 syscall ABI: x8 number, x0..x5
   arguments, x0 result. Keep these OS conventions out of the A64 encoder. *)
module M = Xen_arm64.Machine_ir
let target : Target.t = {architecture=Target.Aarch64;operating_system=Target.Linux}
let open_write_flags = 577
let raw_syscall m = M.syscall m
let call m name = M.branch m ~link:true name
let exit m status = M.int m 0 status;M.int m 8 93;M.syscall m
let write_constant m fd text =
  let label=M.constant m text in
  M.int m 0 fd;M.address m 1 label;M.int m 2 (String.length text);call m "runtime_write"
let fail m text = write_constant m 2 text;exit m 1
let alloc m =
  M.mov m 1 0;M.int m 0 0;M.int m 2 3;M.int m 3 34;
  M.imm m 4 (-1L);M.int m 5 0;M.int m 8 222;M.syscall m
let unmap m = M.int m 8 215;M.syscall m
let read m = M.int m 8 63;M.syscall m
let write m = M.int m 8 64;M.syscall m
(* Close is never retried: Linux may release the descriptor before a late
   error/EINTR; another close could release a reused descriptor. *)
let close m = M.int m 8 57;M.syscall m
let open_ m =
  M.mov m 3 2;M.mov m 2 1;M.mov m 1 0;M.int m 0 (-100);M.int m 8 56;M.syscall m
let start m =
  M.label m "_start";
  M.load m 0 31 0;M.offset m 0 0 (-1);M.address m 15 "argc";M.store m 0 15 0;
  M.offset m 0 31 16;M.address m 15 "argv";M.store m 0 15 0;
  M.offset m 31 31 (-16);M.offset m 8 31 0
let foreign_start m ~main =
  (* The loader passes rtld_fini in x0. Preserve it before Xen's argc setup. *)
  M.mov m 20 0;start m;
  let startup=M.import m "libc.so.6" "__libc_start_main"in
  M.mov m 5 20;M.address m 0 main;M.load m 1 31 16;M.offset m 2 31 24;
  M.int m 3 0;M.int m 4 0;M.offset m 6 31 16;
  M.address m 16 startup;M.load m 16 16 0;M.word m 0xd63f0200;M.word m 0xd4200000;
  Ok()
let executable m = if m.M.imports=[]then Elf_writer.static_linux ~entry:0 m else Elf_writer.dynamic_linux ~entry:0 m
let emit m =
  Xen_arm64.Output_runtime.emit m ~write ~exit;
  Xen_arm64.Float_runtime.emit m;
  Xen_arm64.Heap_runtime.emit m ~alloc ~unmap ~fail;
  Xen_arm64.Collection_runtime.emit m ~fail;
  Xen_arm64.File_runtime.emit m ~open_ ~read ~write ~close;
  Xen_arm64.Numeric_runtime.emit m
