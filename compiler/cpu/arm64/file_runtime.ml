(* SPDX-License-Identifier: Apache-2.0 *)
(* Generated runtime code carries the additional MIT OR Apache-2.0 permission
   specified in the root LICENSE. Linux AArch64 file services use only x0..x17,
   aligned stack frames and saved LR. They return errors before fatal diagnostics
   so temporary mappings and read_text's owned fd can be released first.
   Status: 0 success, 1 NUL path, 2 open, 3 read, 4 close, 7 size, 8 allocation. *)
module M = Machine_ir
let call m name = M.branch m ~link:true name
let close m = M.int m 8 57;M.syscall m
let allocation_failed m label =
  M.imm m 9 (-4095L);M.cmp m 0 9;M.cond m 2 label

let emit m =
  (* open(x0 String descriptor, x1 flags) -> x0 fd, x1 status. The temporary
     NUL-terminated name is never used as a String ownership descriptor. *)
  M.label m "runtime_file_open";M.offset m 31 31 (-64);M.store m 30 31 56;
  M.load m 9 0 0;M.store m 9 31 0;M.load m 10 0 8;M.store m 10 31 8;
  M.store m 1 31 16;M.imm m 9 (-1L);M.store m 9 31 40;
  M.cmp_zero m 10;M.cond m 11 "file_path_large";
  M.imm m 9 Int64.max_int;M.cmp m 10 9;M.cond m 0 "file_path_large";
  M.load m 9 31 0;M.int m 11 0;
  M.label m "file_path_scan";M.cmp m 11 10;M.cond m 2 "file_path_copy";
  M.load m ~bytes:1 12 9 0;M.cmp_zero m 12;M.cond m 0 "file_path_nul";
  M.offset m 9 9 1;M.offset m 11 11 1;M.branch m "file_path_scan";
  M.label m "file_path_copy";M.offset m 0 10 1;call m "runtime_alloc";
  allocation_failed m "file_path_alloc_failed";M.store m 0 31 24;
  M.load m 1 31 0;M.load m 2 31 8;call m "runtime_copy";
  M.load m 9 31 8;M.add m 9 0 9;M.store m ~bytes:1 31 9 0;
  M.label m "file_open_retry";M.int m 0 (-100);M.load m 1 31 24;
  M.load m 2 31 16;M.int m 3 420;M.int m 8 56;M.syscall m;
  M.int m 9 (-4);M.cmp m 0 9;M.cond m 0 "file_open_retry";
  M.store m 0 31 40;M.load m 0 31 24;M.load m 1 31 8;
  M.offset m 1 1 1;call m "runtime_unmap";
  M.load m 0 31 40;M.cmp_zero m 0;M.cond m 11 "file_open_failed";
  M.int m 1 0;M.branch m "file_open_return";
  M.label m "file_path_nul";M.int m 1 1;M.branch m "file_open_return";
  M.label m "file_open_failed";M.int m 1 2;M.branch m "file_open_return";
  M.label m "file_path_large";M.int m 1 7;M.branch m "file_open_return";
  M.label m "file_path_alloc_failed";M.int m 1 8;
  M.label m "file_open_return";M.load m 0 31 40;M.load m 30 31 56;
  M.offset m 31 31 64;M.ret m;

  (* close(x0 File cell) -> raw syscall result, or 0 if already inactive.
     Invalidate BEFORE close, including errors/EINTR. Linux releases the fd
     before reporting late errors; retry could close a reused descriptor. *)
  M.label m "runtime_file_close";M.load m 9 0 0;M.imm m 10 (-1L);
  M.store m 10 0 0;M.int m 0 0;M.cmp_zero m 9;M.cond m 11 "file_close_return";
  M.mov m 0 9;close m;M.label m "file_close_return";M.ret m;

  (* write(x0 fd, x1 bytes, x2 length) -> 0 or negative errno.
     Preserve partial progress; a zero write with remaining bytes is EIO. *)
  M.label m "runtime_file_write";M.mov m 7 0;
  M.label m "file_write_loop";M.cmp_zero m 2;M.cond m 0 "file_write_done";
  M.mov m 0 7;M.int m 8 64;M.syscall m;
  M.int m 9 (-4);M.cmp m 0 9;M.cond m 0 "file_write_loop";
  M.cmp_zero m 0;M.cond m 11 "file_write_return";M.cond m 0 "file_write_zero";
  M.add m 1 1 0;M.sub m 2 2 0;M.branch m "file_write_loop";
  M.label m "file_write_zero";M.int m 0 (-5);M.branch m "file_write_return";
  M.label m "file_write_done";M.int m 0 0;
  M.label m "file_write_return";M.ret m;

  (* read(x0 result descriptor, x1 borrowed fd) -> x0 status.
     Read to EOF without fstat/seek, using a geometric temporary mapping.
     The result is empty or owns exactly its byte length with marker 1. *)
  M.label m "runtime_file_read";M.offset m 31 31 (-80);M.store m 30 31 72;
  M.store m 0 31 0;M.store m 1 31 8;M.store m 31 31 16;
  M.int m 9 4096;M.store m 9 31 24;M.store m 31 31 32;M.store m 31 31 56;
  List.iter(fun off->M.store m 31 0 off)[0;8;16];
  M.int m 0 4096;call m "runtime_alloc";allocation_failed m "file_read_alloc_failed";
  M.store m 0 31 16;
  M.label m "file_read_loop";M.load m 9 31 32;M.load m 10 31 24;
  M.cmp m 9 10;M.cond m 0 "file_read_grow";
  M.load m 0 31 8;M.load m 1 31 16;M.add m 1 1 9;M.sub m 2 10 9;
  M.int m 8 63;M.syscall m;M.int m 9 (-4);M.cmp m 0 9;M.cond m 0 "file_read_loop";
  M.cmp_zero m 0;M.cond m 11 "file_read_failed";M.cond m 0 "file_read_finish";
  M.load m 9 31 32;M.add m 9 9 0;M.store m 9 31 32;M.branch m "file_read_loop";
  M.label m "file_read_grow";M.add m 0 10 10;M.cmp m 0 10;
  M.cond m 3 "file_read_large";M.cmp_zero m 0;M.cond m 11 "file_read_large";
  M.store m 0 31 40;call m "runtime_alloc";allocation_failed m "file_read_alloc_failed";
  M.store m 0 31 48;M.load m 1 31 16;M.load m 2 31 32;call m "runtime_copy";
  M.load m 0 31 16;M.load m 1 31 24;call m "runtime_unmap";
  M.load m 9 31 48;M.store m 9 31 16;M.load m 9 31 40;M.store m 9 31 24;
  M.branch m "file_read_loop";
  M.label m "file_read_finish";M.load m 0 31 32;M.cmp_zero m 0;
  M.cond m 0 "file_read_release";
  M.load m 9 31 24;M.cmp m 0 9;M.cond m 0 "file_read_keep_buffer";
  call m "runtime_alloc";allocation_failed m "file_read_alloc_failed";
  M.store m 0 31 48;M.load m 1 31 16;M.load m 2 31 32;call m "runtime_copy";
  M.load m 0 31 16;M.load m 1 31 24;call m "runtime_unmap";
  M.load m 0 31 48;M.branch m "file_read_result";
  M.label m "file_read_keep_buffer";M.load m 0 31 16;
  M.label m "file_read_result";M.load m 9 31 0;M.load m 1 31 32;M.int m 2 1;
  M.store m 0 9 0;M.store m 1 9 8;M.store m 2 9 16;M.branch m "file_read_return";
  M.label m "file_read_failed";M.int m 9 3;M.branch m "file_read_error";
  M.label m "file_read_large";M.int m 9 7;M.branch m "file_read_error";
  M.label m "file_read_alloc_failed";M.int m 9 8;
  M.label m "file_read_error";M.store m 9 31 56;
  M.label m "file_read_release";M.load m 0 31 16;M.cmp_zero m 0;
  M.cond m 0 "file_read_return";M.load m 1 31 24;call m "runtime_unmap";
  M.label m "file_read_return";M.load m 0 31 56;M.load m 30 31 72;
  M.offset m 31 31 80;M.ret m;

  (* read_text(x0 result descriptor, x1 path descriptor) -> x0 status.
     Always close a successfully opened fd. Read errors take priority over close
     errors; after a successful read, a failed close drops its String result. *)
  M.label m "runtime_read_text";M.offset m 31 31 (-48);M.store m 30 31 40;
  M.store m 0 31 0;M.mov m 0 1;M.int m 1 0;call m "runtime_file_open";
  M.cmp_zero m 1;M.cond m 1 "read_text_open_failed";
  M.store m 0 31 8;M.mov m 1 0;M.load m 0 31 0;call m "runtime_file_read";
  M.store m 0 31 16;M.offset m 0 31 8;call m "runtime_file_close";
  M.load m 9 31 16;M.cmp_zero m 9;M.cond m 1 "read_text_status";
  M.cmp_zero m 0;M.cond m 10 "read_text_status";
  M.load m 0 31 0;call m "runtime_string_drop";M.int m 9 4;
  M.label m "read_text_status";M.mov m 0 9;M.branch m "read_text_return";
  M.label m "read_text_open_failed";M.mov m 0 1;
  M.label m "read_text_return";M.load m 30 31 40;M.offset m 31 31 48;M.ret m
