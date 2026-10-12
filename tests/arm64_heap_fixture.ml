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
  |"file_final_allocation_failure"->
      (* Only run with bounded QEMU guest VA. Fill guest pages using an
         intrusive list, then free exactly one. open's name and read's buffer
         can reuse that page, but the nonempty final String cannot coexist.
         This avoids relying on QEMU's placement/reuse of geometric buffers. *)
      M.offset m 31 31 (-64);M.int m 9 8192;M.store m 9 31 48;
      (* Cap the filler at 32MiB: accidental unbounded/native execution fails
         instead of consuming the host's available memory. *)
      M.label m "fixture_fill_pages";M.load m 9 31 48;M.cmp_zero m 9;
      M.cond m 0 "fixture_failed";M.offset m 9 9 (-1);M.store m 9 31 48;
      M.int m 0 4096;R.call m "runtime_alloc";
      M.imm m 9 (-4095L);M.cmp m 0 9;M.cond m 2 "fixture_pages_full";
      M.address m 15 "fixture_root";M.load m 9 15 0;M.store m 9 0 0;
      M.store m 0 15 0;M.branch m "fixture_fill_pages";
      M.label m "fixture_pages_full";M.address m 15 "fixture_root";M.load m 0 15 0;
      M.cmp_zero m 0;M.cond m 0 "fixture_failed";
      M.load m 9 0 0;M.store m 9 15 0;M.int m 1 4096;R.call m "runtime_unmap";
      let path="/proc/sys/kernel/ostype" in
      M.offset m 1 31 24;M.address m 9 (M.constant m path);M.store m 9 1 0;
      M.int m 9 (String.length path);M.store m 9 1 8;M.store m 31 1 16;
      M.offset m 0 31 0;R.call m "runtime_read_text";
      M.int m 9 8;M.cmp m 0 9;M.cond m 1 "fixture_failed";
      List.iter(fun off->M.load m 0 31 off;M.cmp_zero m 0;M.cond m 1 "fixture_failed")[0;8;16];
      M.label m "fixture_free_pages";M.address m 15 "fixture_root";M.load m 0 15 0;
      M.cmp_zero m 0;M.cond m 0 "fixture_pages_released";
      M.load m 9 0 0;M.store m 9 15 0;M.int m 1 4096;R.call m "runtime_unmap";
      M.branch m "fixture_free_pages";
      M.label m "fixture_pages_released";R.write_constant m 1 "file-final-allocation\n";R.exit m 0
  |("file_path_large"|"file_path_negative" as mode)->
      M.offset m 31 31 (-32);descriptor 0 (if mode="file_path_large" then Int64.max_int else -1L);
      M.offset m 0 31 0;M.int m 1 0;R.call m "runtime_file_open";
      M.int m 9 7;M.cmp m 1 9;M.cond m 1 "fixture_failed";
      M.imm m 9 (-1L);M.cmp m 0 9;M.cond m 1 "fixture_failed";
      R.write_constant m 1 "file-size\n";R.exit m 0
  |"file_close_failure"->
      M.offset m 31 31 (-32);M.int m 9 2147483647;M.store m 9 31 0;
      M.offset m 0 31 0;R.call m "runtime_file_close";
      M.int m 9 (-9);M.cmp m 0 9;M.cond m 1 "fixture_failed";
      M.load m 0 31 0;M.imm m 9 (-1L);M.cmp m 0 9;M.cond m 1 "fixture_failed";
      M.offset m 0 31 0;R.call m "runtime_file_close";
      M.cmp_zero m 0;M.cond m 1 "fixture_failed";
      R.write_constant m 1 "file-close\n";R.exit m 0
  |"file_read_failure"->
      M.offset m 31 31 (-32);M.offset m 0 31 0;M.int m 1 (-1);
      R.call m "runtime_file_read";M.int m 9 3;M.cmp m 0 9;M.cond m 1 "fixture_failed";
      List.iter(fun off->M.load m 0 31 off;M.cmp_zero m 0;M.cond m 1 "fixture_failed")[0;8;16];
      R.write_constant m 1 "file-read\n";R.exit m 0
  |"file_write_failure"->
      M.int m 0 (-1);M.address m 1 (M.constant m "x");M.int m 2 1;
      R.call m "runtime_file_write";M.int m 9 (-9);M.cmp m 0 9;M.cond m 1 "fixture_failed";
      M.int m 0 (-1);M.int m 1 0;M.int m 2 0;R.call m "runtime_file_write";
      M.cmp_zero m 0;M.cond m 1 "fixture_failed";
      R.write_constant m 1 "file-write\n";R.exit m 0
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
