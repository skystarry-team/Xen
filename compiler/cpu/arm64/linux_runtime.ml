(* SPDX-License-Identifier: Apache-2.0 *)
(* Generated runtime code carries the additional MIT OR Apache-2.0 permission
   specified in the root LICENSE. Linux AArch64 syscall ABI: x8 number, x0..x5
   arguments, x0 result. Keep these OS conventions out of the A64 encoder. *)
module M = Machine_ir
let call m name = M.branch m ~link:true name
let exit m status = M.int m 0 status;M.int m 8 93;M.syscall m
let write_constant m fd text =
  let label=M.constant m text in
  M.int m 0 fd;M.address m 1 label;M.int m 2 (String.length text);call m "runtime_write"
let fail m text = write_constant m 2 text;exit m 1
let emit m =
  (* write(fd=x0, bytes=x1, length=x2). Retry EINTR and partial writes. *)
  M.label m "runtime_write";M.mov m 7 0;
  M.label m "write_loop";M.cmp_zero m 2;M.cond m 0 "write_done";
  M.mov m 0 7;M.int m 8 64;M.syscall m;
  M.int m 3 (-4);M.cmp m 0 3;M.cond m 0 "write_loop";
  M.cmp_zero m 0;M.cond m 13 "write_failed";
  M.add m 1 1 0;M.sub m 2 2 0;M.branch m "write_loop";
  M.label m "write_done";M.ret m;
  M.label m "write_failed";exit m 1;
  (* Decimal print: x0 bits, x1=1 for signed. All working registers are volatile.
     Unsigned magnitude also handles -2^63 without signed overflow. *)
  M.label m "runtime_integer";
  M.offset m 31 31 (-48);M.store m 30 31 32;
  M.mov m 4 0;M.int m 5 0;M.cmp_zero m 1;M.cond m 0 "integer_magnitude";
  M.cmp_zero m 4;M.cond m 10 "integer_magnitude";
  M.int m 5 1;M.sub m 4 31 4;
  M.label m "integer_magnitude";
  M.offset m 1 31 32;M.int m 2 0;M.int m 6 10;
  M.label m "integer_digits";
  M.rr m 0x9ac00800 3 4 6; (* udiv x3,x4,x6 *)
  M.mul m 0 3 6;M.sub m 0 4 0;M.offset m 0 0 48;
  M.offset m 1 1 (-1);M.store m ~bytes:1 0 1 0;
  M.offset m 2 2 1;M.mov m 4 3;M.cmp_zero m 4;M.cond m 1 "integer_digits";
  M.cmp_zero m 5;M.cond m 0 "integer_output";
  M.offset m 1 1 (-1);M.int m 0 45;M.store m ~bytes:1 0 1 0;M.offset m 2 2 1;
  M.label m "integer_output";M.int m 0 1;call m "runtime_write";
  M.load m 30 31 32;M.offset m 31 31 48;M.ret m;
  Float_runtime.emit m;
  Heap_runtime.emit m ~fail;
  Collection_runtime.emit m ~fail
