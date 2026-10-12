(* SPDX-License-Identifier: Apache-2.0 *)
(* Generated runtime carries the additional MIT OR Apache-2.0 permission in LICENSE.
   Vec pointer addresses elements; its hidden header stores pending ownership work.
   All frames are aligned, LR is saved, and only x0..x17 are scratch. *)
module M = Machine_ir
module H = Heap_runtime
let call m name = M.branch m ~link:true name
let header = 32
let emit m ~fail =
  (* new(x0 descriptor, x1 count, x2 stride). Exact initial capacity. mmap zeros
     element storage; multiplication and header addition are checked first. *)
  M.label m "runtime_vec_new";M.offset m 31 31 (-48);M.store m 30 31 40;
  M.store m 0 31 0;M.store m 1 31 8;M.cmp_zero m 1;M.cond m 11 "vec_too_large";
  M.cond m 0 "vec_new_empty";M.mul m 0 1 2;
  M.multiply_high m 9 1 2;
  M.cmp_zero m 9;M.cond m 1 "vec_too_large";
  M.imm m 9 (Int64.sub Int64.max_int (Int64.of_int header));
  M.cmp m 0 9;M.cond m 8 "vec_too_large";M.offset m 0 0 header;
  call m "runtime_alloc";M.imm m 9 (-4095L);M.cmp m 0 9;M.cond m 2 "vec_alloc_failed";
  M.offset m 0 0 header;M.load m 9 31 0;M.load m 1 31 8;
  M.store m 0 9 0;M.store m 1 9 8;M.store m 1 9 16;M.branch m "vec_new_return";
  M.label m "vec_new_empty";M.load m 9 31 0;List.iter(fun off->M.store m 31 9 off)[0;8;16];
  M.label m "vec_new_return";M.load m 30 31 40;M.offset m 31 31 48;M.ret m;
  (* push(x0 mutable descriptor, x1 staged value pointer, x2 stride,
     x3 value size). Growth copies initialized bytes without cloning/dropping. *)
  M.label m "runtime_vec_push";M.offset m 31 31 (-80);M.store m 30 31 72;
  List.iteri(fun i r->M.store m r 31 (i*8))[0;1;2;3];
  M.load m 4 0 0;M.store m 4 31 32;M.load m 4 0 8;M.store m 4 31 40;
  M.load m 5 0 16;M.store m 5 31 48;M.cmp m 4 5;M.cond m 3 "vec_push_store";
  M.cmp_zero m 5;M.cond m 1 "vec_push_double";M.int m 5 2;
  M.label m "vec_push_double";M.add m 1 5 5;M.cmp m 1 5;M.cond m 3 "vec_too_large";
  M.store m 1 31 56;M.load m 0 31 0;call m "runtime_vec_new";
  M.load m 9 31 0;M.load m 0 9 0;M.load m 1 31 32;
  M.load m 2 31 40;M.load m 3 31 16;M.mul m 2 2 3;call m "runtime_copy";
  M.load m 1 31 48;M.cmp_zero m 1;M.cond m 0 "vec_push_no_old";
  M.load m 0 31 32;M.offset m 0 0 (-header);M.load m 2 31 16;
  M.mul m 1 1 2;M.offset m 1 1 header;call m "runtime_unmap";
  M.label m "vec_push_no_old";M.load m 9 31 0;M.load m 4 31 40;M.store m 4 9 8;
  M.label m "vec_push_store";M.load m 9 31 0;M.load m 0 9 0;
  M.load m 4 31 40;M.load m 2 31 16;M.mul m 4 4 2;M.add m 0 0 4;
  M.load m 1 31 8;M.load m 2 31 24;call m "runtime_copy";
  M.load m 9 31 0;M.load m 4 31 40;M.offset m 4 4 1;M.store m 4 9 8;
  M.load m 30 31 72;M.offset m 31 31 80;M.ret m;
  (* enqueue_drop(x0 descriptor,x1 worklist,x2 helper,x3 stride). Save live
     length and exact mapping extent before clearing the descriptor. *)
  M.label m "runtime_vec_enqueue";M.load m 9 0 0;M.load m 10 0 8;M.load m 11 0 16;
  List.iter(fun off->M.store m 31 0 off)[0;8;16];
  M.cmp_zero m 11;M.cond m 0 "vec_enqueue_done";
  M.offset m 9 9 (-header);M.mul m 11 11 3;M.offset m 11 11 header;
  M.store m 10 9 16;M.store m 11 9 24;M.load m 10 1 0;
  M.store m 10 9 0;M.store m 2 9 8;M.store m 9 1 0;
  M.label m "vec_enqueue_done";M.ret m;
  (* enqueue_clone(x0 shallow descriptor,x1 worklist,x2 helper,x3 stride).
     Fresh child headers hold tasks; never write the borrowed source's header. *)
  M.label m "runtime_vec_clone_enqueue";M.offset m 31 31 (-80);M.store m 30 31 72;
  List.iteri(fun i r->M.store m r 31 (i*8))[0;1;2;3];
  M.load m 4 0 0;M.store m 4 31 32;M.load m 1 0 8;M.store m 1 31 40;
  M.mov m 2 3;call m "runtime_vec_new";
  M.load m 9 31 0;M.load m 0 9 0;M.load m 1 31 32;
  M.load m 2 31 40;M.load m 3 31 24;M.mul m 2 2 3;call m "runtime_copy";
  M.load m 10 31 40;M.cmp_zero m 10;M.cond m 0 "vec_clone_enqueue_done";
  M.offset m 9 0 (-header);M.store m 10 9 16;M.load m 1 31 8;M.load m 2 31 16;
  M.load m 10 1 0;M.store m 10 9 0;M.store m 2 9 8;M.store m 9 1 0;
  M.label m "vec_clone_enqueue_done";M.load m 30 31 72;M.offset m 31 31 80;M.ret m;
  (* Each dispatcher shares the Box worklist protocol. Per-type helpers enqueue
     all descendants instead of recursively calling these dispatchers. *)
  List.iter(fun(name,enqueue)->
    M.label m name;M.offset m 31 31 (-32);M.store m 30 31 24;M.store m 31 31 0;
    M.mov m 3 2;M.mov m 2 1;M.offset m 1 31 0;call m enqueue;
    let loop=M.fresh m "vec_work_" and done_=M.fresh m "vec_done_" in
    M.label m loop;M.load m 0 31 0;M.cmp_zero m 0;M.cond m 0 done_;
    M.load m 9 0 0;M.store m 9 31 0;M.load m 17 0 8;M.offset m 1 31 0;
    M.word m (0xd63f0000 lor (17 lsl 5));M.branch m loop;
    M.label m done_;M.load m 30 31 24;M.offset m 31 31 32;M.ret m)
    ["runtime_vec_drop","runtime_vec_enqueue";"runtime_vec_clone","runtime_vec_clone_enqueue"];
  (* Conversion preserves String's exact-length mapping contract. Old Vec
     capacity (including a retained empty allocation) is released separately. *)
  M.label m "runtime_vec_into_string";M.offset m 31 31 (-48);M.store m 30 31 40;
  M.store m 1 31 0;M.load m 2 1 0;M.store m 2 31 8;
  M.load m 3 1 8;M.load m 4 1 16;M.store m 4 31 16;
  M.store m 2 0 0;M.store m 3 0 8;M.store m 31 0 16;
  call m "runtime_string_clone";
  M.load m 1 31 16;M.cmp_zero m 1;M.cond m 0 "vec_into_string_done";
  M.load m 0 31 8;M.offset m 0 0 (-header);M.offset m 1 1 header;call m "runtime_unmap";
  M.label m "vec_into_string_done";M.load m 9 31 0;List.iter(fun off->M.store m 31 9 off)[0;8;16];
  M.load m 30 31 40;M.offset m 31 31 48;M.ret m;
  M.label m "vec_alloc_failed";fail m "xen runtime error: vector allocation failed\n";
  M.label m "vec_too_large";fail m "xen runtime error: vector is too large\n"
