(* SPDX-License-Identifier: MIT OR Apache-2.0 *)
(* Runtime boundary fixtures that cannot be expressed through safe Xen source.
   Emit directly: no assembler, linker, libc, or user raw-syscall capability. *)
module M = Xen_arm64.Machine_ir
module R = Xen_arm64.Linux_runtime
module H = Xen_arm64.Heap_runtime
module C = Xen_arm64.Collection_runtime
let () =
  if Array.length Sys.argv<>3 then failwith "usage: arm64_heap_fixture MODE OUTPUT";
  let m=M.create() in
  M.global m "fixture_root";M.label m "_start";
  let check_alloc ()=M.imm m 9 (-4095L);M.cmp m 0 9;M.cond m 2 "fixture_failed" in
  let descriptor address length =
    M.offset m 9 31 address;M.store m 31 9 0;M.imm m 10 length;
    M.store m 10 9 8;M.store m 31 9 16 in
  (match Sys.argv.(1) with
  |("vec_multiply_overflow"|"vec_header_overflow"|"vec_growth_overflow" as mode)->
      M.offset m 31 31 (-32);M.offset m 0 31 0;
      if mode="vec_growth_overflow" then begin
        M.store m 31 0 0;M.imm m 9 0x4000000000000000L;
        M.store m 9 0 8;M.store m 9 0 16;
        M.offset m 1 31 24;M.int m 2 1;M.int m 3 1;R.call m "runtime_vec_push"
      end else begin
        M.imm m 1 (if mode="vec_header_overflow" then Int64.max_int else 0x4000000000000000L);
        M.int m 2 (if mode="vec_header_overflow" then 1 else 8);R.call m "runtime_vec_new"
      end;M.branch m "fixture_failed"
  |"large_box"->
      (* The header makes this span a second 64KiB page too, and the String
         leaf needs a computed address beyond the memory immediate range. *)
      M.int m 0 (H.box_bytes 65536);R.call m "runtime_alloc";check_alloc();
      M.offset m 0 0 H.box_header_bytes;M.address m 15 "fixture_root";M.store m 0 15 0;
      M.int m 0 (H.box_bytes 1);R.call m "runtime_alloc";check_alloc();
      M.offset m 0 0 H.box_header_bytes;M.address m 15 "fixture_root";M.load m 9 15 0;
      M.store m 0 9 0;M.offset m 0 9 65512;
      M.address m 10 (M.constant m "largeval");M.store m 10 0 0;
      M.int m 10 8;M.store m 10 0 8;M.store m 31 0 16;
      R.call m "runtime_string_clone";
      M.address m 0 "fixture_root";M.address m 1 "fixture_parent_helper";
      R.call m "runtime_box_drop";
      M.address m 15 "fixture_root";M.load m 0 15 0;M.cmp_zero m 0;M.cond m 1 "fixture_failed";
      R.write_constant m 1 "large\n";R.exit m 0
  |("signed_overflow"|"unsigned_wrap"|"empty" as mode)->
      M.offset m 31 31 (-96);
      let left,right=match mode with
        |"signed_overflow"->Int64.max_int,1L|"unsigned_wrap"->Int64.minus_one,2L|_->0L,0L in
      descriptor 0 left;descriptor 32 right;
      M.offset m 0 31 64;M.offset m 1 31 0;M.offset m 2 31 32;
      R.call m "runtime_string_concat";
      if mode="empty" then begin
        M.offset m 0 31 64;R.call m "runtime_string_clone";
        M.offset m 0 31 64;R.call m "runtime_string_drop";
        R.write_constant m 1 "empty\n";R.exit m 0
      end else M.branch m "fixture_failed"
  |_->failwith "unknown ARM64 heap fixture");
  M.label m "fixture_failed";R.fail m "fixture failed\n";
  R.emit m;
  H.emit_box_helper m "fixture_parent_helper" ~bytes:(H.box_bytes 65536)
    [65512,None;0,Some "fixture_child_helper"];
  H.emit_box_helper m "fixture_child_helper" ~bytes:(H.box_bytes 1) [];
  Xen_arm64.Native_backend.write Sys.argv.(2)(Xen_arm64.Elf_writer.static_linux ~entry:0 m)
