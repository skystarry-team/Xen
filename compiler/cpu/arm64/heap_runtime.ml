(* SPDX-License-Identifier: Apache-2.0 *)
(* Generated runtime code carries the additional MIT OR Apache-2.0 permission
   specified in the root LICENSE. Linux services and ownership, not A64 opcodes.
   All helpers use x0..x17 only, save LR across calls, and keep SP aligned. *)
module M = Machine_ir
let call m name = M.branch m ~link:true name
let box_header_bytes = 16
let box_bytes payload =
  let payload=max 1 payload in
  if payload>max_int-box_header_bytes then raise(M.Error "Box allocation size overflow");
  payload+box_header_bytes
let alloc m =
  (* mmap(NULL, bytes=x0, RW, PRIVATE|ANONYMOUS, -1, 0). Raw result in x0;
     each caller checks errno before using it. No executable heap pages. *)
  M.mov m 1 0;M.int m 0 0;M.int m 2 3;M.int m 3 34;
  M.imm m 4 (-1L);M.int m 5 0;M.int m 8 222;M.syscall m
let unmap m = M.int m 8 215;M.syscall m (* x0 base, x1 length *)
let emit m ~fail =
  M.label m "runtime_alloc";alloc m;M.ret m;
  M.label m "runtime_unmap";unmap m;M.ret m;
  (* Byte copy: x0 destination, x1 source, x2 count. No overlap is required
     for fresh allocations. Returns the original destination in x0. *)
  M.label m "runtime_copy";M.mov m 9 0;
  M.label m "heap_copy_loop";M.cmp_zero m 2;M.cond m 0 "heap_copy_done";
  M.load m ~bytes:1 10 1 0;M.store m ~bytes:1 10 9 0;
  M.offset m 1 1 1;M.offset m 9 9 1;M.offset m 2 2 (-1);M.branch m "heap_copy_loop";
  M.label m "heap_copy_done";M.ret m;
  (* Clone the descriptor at x0 in place, after a shallow copy of the source.
     word 2 remains the shared layout's ownership marker (0 borrowed, 1 owned).
     String mappings have length equal to the byte length; empty owns nothing. *)
  M.label m "runtime_string_clone";
  M.offset m 31 31 (-48);M.store m 30 31 40;M.store m 0 31 0;
  M.load m 1 0 0;M.load m 2 0 8;M.store m 1 31 8;M.store m 2 31 16;
  M.cmp_zero m 2;M.cond m 0 "string_clone_empty";
  M.mov m 0 2;call m "runtime_alloc";
  M.imm m 9 (-4095L);M.cmp m 0 9;M.cond m 2 "string_alloc_failed";
  M.store m 0 31 24;M.load m 1 31 8;M.load m 2 31 16;call m "runtime_copy";
  M.load m 9 31 0;M.load m 0 31 24;M.load m 1 31 16;M.int m 2 1;
  M.store m 0 9 0;M.store m 1 9 8;M.store m 2 9 16;M.branch m "string_clone_return";
  M.label m "string_clone_empty";M.load m 9 31 0;
  List.iter(fun off->M.store m 31 9 off)[0;8;16];
  M.label m "string_clone_return";M.load m 30 31 40;M.offset m 31 31 48;M.ret m;
  (* Drop x0 descriptor, clearing it before the syscall. The length is the
     unmap length; the ownership marker must never be treated as capacity. *)
  M.label m "runtime_string_drop";M.mov m 9 0;
  M.load m 2 9 16;M.load m 1 9 8;M.load m 0 9 0;
  List.iter(fun off->M.store m 31 9 off)[0;8;16];
  M.cmp_zero m 2;M.cond m 0 "string_drop_done";M.cmp_zero m 1;M.cond m 0 "string_drop_done";
  unmap m;M.label m "string_drop_done";M.ret m;
  (* concat(x0 result descriptor, x1 left descriptor, x2 right descriptor).
     Capture everything before mmap overwrites the syscall argument registers. *)
  M.label m "runtime_string_concat";M.offset m 31 31 (-64);M.store m 30 31 56;
  M.store m 0 31 0;M.load m 3 1 0;M.store m 3 31 8;
  M.load m 3 1 8;M.store m 3 31 16;
  M.load m 4 2 0;M.store m 4 31 24;M.load m 4 2 8;M.store m 4 31 32;
  M.add m 0 3 4;M.cmp m 0 3;M.cond m 3 "string_too_large";
  M.cmp_zero m 0;M.cond m 11 "string_too_large";M.store m 0 31 40;
  M.cond m 0 "string_concat_empty";call m "runtime_alloc";
  M.imm m 9 (-4095L);M.cmp m 0 9;M.cond m 2 "string_alloc_failed";M.store m 0 31 48;
  M.load m 1 31 8;M.load m 2 31 16;call m "runtime_copy";
  M.load m 2 31 16;M.add m 0 0 2;M.load m 1 31 24;M.load m 2 31 32;call m "runtime_copy";
  M.load m 9 31 0;M.load m 0 31 48;M.load m 1 31 40;M.int m 2 1;
  M.store m 0 9 0;M.store m 1 9 8;M.store m 2 9 16;M.branch m "string_concat_return";
  M.label m "string_concat_empty";M.load m 9 31 0;
  List.iter(fun off->M.store m 31 9 off)[0;8;16];
  M.label m "string_concat_return";M.load m 30 31 56;M.offset m 31 31 64;M.ret m;
  (* int_to_str(x0 I64 bits, x1 result descriptor). Format into a stack buffer,
     then clone into an exact-length mapping. Unsigned magnitude handles -2^63. *)
  M.label m "runtime_int_to_string";M.offset m 31 31 (-64);M.store m 30 31 56;
  M.store m 1 31 48;M.mov m 4 0;M.int m 5 0;
  M.cmp_zero m 4;M.cond m 10 "int_string_magnitude";M.int m 5 1;M.sub m 4 31 4;
  M.label m "int_string_magnitude";M.offset m 1 31 32;M.int m 2 0;M.int m 6 10;
  M.label m "int_string_digits";M.rr m 0x9ac00800 3 4 6;
  M.mul m 0 3 6;M.sub m 0 4 0;M.offset m 0 0 48;
  M.offset m 1 1 (-1);M.store m ~bytes:1 0 1 0;M.offset m 2 2 1;
  M.mov m 4 3;M.cmp_zero m 4;M.cond m 1 "int_string_digits";
  M.cmp_zero m 5;M.cond m 0 "int_string_clone";
  M.offset m 1 1 (-1);M.int m 0 45;M.store m ~bytes:1 0 1 0;M.offset m 2 2 1;
  M.label m "int_string_clone";M.load m 0 31 48;
  M.store m 1 0 0;M.store m 2 0 8;M.store m 31 0 16;call m "runtime_string_clone";
  M.load m 30 31 56;M.offset m 31 31 64;M.ret m;
  (* Enqueue(x0 pointer cell, x1 address of worklist head, x2 type helper).
     Pending records live in CHILD headers, never in a parent being freed. *)
  M.label m "runtime_box_enqueue";M.load m 9 0 0;M.store m 31 0 0;
  M.cmp_zero m 9;M.cond m 0 "box_enqueue_done";M.offset m 9 9 (-box_header_bytes);
  M.load m 10 1 0;M.store m 10 9 0;M.store m 2 9 8;M.store m 9 1 0;
  M.label m "box_enqueue_done";M.ret m;
  (* Drop(x0 pointer cell, x1 type helper). A local intrusive worklist bounds
     stack use independently of the owning graph's depth. No cleanup allocation. *)
  M.label m "runtime_box_drop";M.offset m 31 31 (-32);M.store m 30 31 24;
  M.store m 31 31 0;M.mov m 2 1;M.offset m 1 31 0;call m "runtime_box_enqueue";
  M.label m "box_drop_loop";M.load m 0 31 0;M.cmp_zero m 0;M.cond m 0 "box_drop_done";
  M.load m 9 0 0;M.store m 9 31 0;M.load m 17 0 8;M.offset m 1 31 0;
  M.word m (0xd63f0000 lor (17 lsl 5));M.branch m "box_drop_loop";
  M.label m "box_drop_done";M.load m 30 31 24;M.offset m 31 31 32;M.ret m;
  M.label m "string_alloc_failed";fail m "xen runtime error: string allocation failed\n";
  M.label m "string_too_large";fail m "xen runtime error: string is too large\n"

(* A type helper receives x0 header and x1 worklist address. Each Box leaf is
   enqueued directly; calling runtime_box_drop here would reintroduce recursion. *)
let emit_box_helper m name ~bytes leaves =
  M.label m name;M.offset m 31 31 (-32);
  M.store m 0 31 0;M.store m 1 31 8;M.store m 30 31 24;
  List.iter(fun(offset,helper)->M.load m 0 31 0;M.offset m 0 0 (box_header_bytes+offset);
    match helper with
    |None->call m "runtime_string_drop"
    |Some name->M.load m 1 31 8;M.address m 2 name;call m "runtime_box_enqueue")leaves;
  M.load m 0 31 0;M.int m 1 bytes;unmap m;
  M.load m 30 31 24;M.offset m 31 31 32;M.ret m
