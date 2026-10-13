(* SPDX-License-Identifier: Apache-2.0 *)
(* Generated runtime carries the additional MIT OR Apache-2.0 permission in LICENSE.
   Internal Darwin AArch64 prototype, not a registered CLI execution target.
   BSD syscall number in x16, arguments x0..x5, svc #0x80, positive errno with
   carry on failure. Normalize to a negative errno for shared runtime services.
   Preserve x1..x5: Darwin returns a second result in x1, while the shared reader
   and writer need their original buffer/count across EINTR and partial progress.
   Hooks emit inline instructions, never BL, preserving leaf helpers' LR. *)
module M = Xen_arm64.Machine_ir
let target : Target.t = {architecture=Target.Aarch64;operating_system=Target.MacOS}
let open_write_flags = 1537 (* O_WRONLY | O_CREAT | O_TRUNC *)
let call m name = M.branch m ~link:true name
let trap m set_number =
  M.offset m 31 31 (-48);
  List.iteri(fun i reg->M.store m reg 31 (i*8))[1;2;3;4;5];
  (* offset uses x16 scratch: set the syscall register after stack setup. *)
  set_number();M.syscall m ~immediate:0x80;
  let success=M.fresh m "darwin_syscall_ok_" in
  M.cond m 3 success;M.sub m 0 31 0;M.label m success;
  List.iteri(fun i reg->M.load m reg 31 (i*8))[1;2;3;4;5];
  M.offset m 31 31 48
let syscall m number = trap m (fun()->M.int m 16 number)
let raw_syscall m = trap m (fun()->M.mov m 16 8)
let exit m status =
  M.int m 0 status;M.int m 16 1;M.syscall m ~immediate:0x80;
  M.word m 0xd4200000 (* Never fall through if a malformed environment returns. *)
let write_constant m fd text =
  let label=M.constant m text in
  M.int m 0 fd;M.address m 1 label;M.int m 2(String.length text);call m "runtime_write"
let fail m text = write_constant m 2 text;exit m 1
let start m =
  (* LC_MAIN enters with C argc/argv. Preserve a valid platform frame record
     before calling a Xen function; Xen arg(0) excludes the executable name. *)
  M.label m "_start";
  M.offset m 0 0 (-1);M.address m 15 "argc";M.store m 0 15 0;
  M.offset m 1 1 8;M.address m 15 "argv";M.store m 1 15 0;
  M.offset m 31 31 (-16);M.store m 29 31 0;M.store m 30 31 8;
  M.offset m 29 31 0;
  M.offset m 31 31 (-16);M.offset m 8 31 0
let alloc m =
  M.mov m 1 0;M.int m 0 0;M.int m 2 3;M.int m 3 4098;
  M.imm m 4 (-1L);M.int m 5 0;syscall m 197
let unmap m = syscall m 73
let emit m =
  Xen_arm64.Output_runtime.emit m ~write:(fun m->syscall m 4) ~exit;
  Xen_arm64.Float_runtime.emit m;
  Xen_arm64.Heap_runtime.emit m ~alloc ~unmap ~fail;
  Xen_arm64.Collection_runtime.emit m ~fail;
  Xen_arm64.File_runtime.emit m ~open_:(fun m->syscall m 5) ~read:(fun m->syscall m 3)
    ~write:(fun m->syscall m 4) ~close:(fun m->syscall m 6);
  Xen_arm64.Numeric_runtime.emit m
let executable m =
  try Xen_darwin.Mach_o.executable ~architecture:Target.Aarch64 ~entry:0
    ~code_size:(Buffer.length m.M.code) ~rodata:(Buffer.contents m.M.rodata)
    ~data:(Buffer.contents m.M.data) ~encode:(M.encode ~position_independent:true m)
  with Xen_darwin.Mach_o.Error message->raise(M.Error message)
