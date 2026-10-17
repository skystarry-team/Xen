(* SPDX-License-Identifier: Apache-2.0 *)
(* Generated runtime carries the additional MIT OR Apache-2.0 permission in LICENSE.
   UTF-8 Xen services over synchronous Win32 APIs. No CRT or host linker. *)
module M = Xen_x86_64.Machine_ir
module W = Xen_x86_64.Win64
module P = Xen_windows.Pe_writer
let open_read_flags = 0
let open_write_flags = 1
let stack_allocate m size =
  (* Packed Vec temporaries can be byte-sized; the reusable Win64 primitive
     handles aligned regions, with at most seven remaining bytes touched here. *)
  if size<0 || size>0x7fffffff then invalid_arg "Windows stack allocation exceeds 2 GiB";
  W.stack_allocate m (size/8*8);
  let tail=size mod 8 in
  if tail<>0 then M.bytes m[0x48;0x83;0xec;tail;0xf6;0x04;0x24;0]
let call m name = M.branch m [0xe8] name
let service name m = call m ("__xen_win_"^name)
let alloc = service "alloc"
let unmap = service "unmap"
let read = service "read"
let write = service "write"
let close = service "close"
let open_ = service "open"
let platform_call m operation =
  let count=Platform_service.arity operation in
  (* The finite service ABI uses rdi/rsi/rdx; operands are evaluated exactly
     once before these loads and the service preserves all other live state. *)
  List.iteri(fun index r->
    M.bytes m[0x48;0x8b;0x84 lor(r lsl 3);0x24];
    M.u32 m(Int64.of_int(8*(count-index-1))))(List.filteri(fun i _->i<count)[7;6;2]);
  if count>0 then(M.bytes m[0x48;0x81;0xc4];M.u32 m(Int64.of_int(8*count)));
  service(Platform_service.name operation)m;Ok ()
let imm m r n =
  M.u8 m (if r>=8 then 0x49 else 0x48);M.u8 m (0xb8 lor(r land 7));M.u64 m n
let int m r n = imm m r (Int64.of_int n)
let mov m dst src =
  M.bytes m [0x48 lor(if src>=8 then 4 else 0)lor(if dst>=8 then 1 else 0);
    0x89;0xc0 lor((src land 7)lsl 3)lor(dst land 7)]
let mem m opcode r base displacement =
  M.bytes m [0x48 lor(if r>=8 then 4 else 0)lor(if base>=8 then 1 else 0);
    opcode;0x80 lor((r land 7)lsl 3)lor(base land 7)];
  if base land 7=4 then M.u8 m 0x24;
  M.u32 m(Int64.of_int displacement)
let load m r base offset = mem m 0x8b r base offset
let load32 m r base offset =
  if r>=8 || base>=8 then M.u8 m(0x40 lor(if r>=8 then 4 else 0)lor(if base>=8 then 1 else 0));
  M.bytes m[0x8b;0x80 lor((r land 7)lsl 3)lor(base land 7)];
  if base land 7=4 then M.u8 m 0x24;
  M.u32 m(Int64.of_int offset)
let store m base offset r = mem m 0x89 r base offset
let lea m r base offset = mem m 0x8d r base offset
let test m r =
  M.bytes m [if r>=8 then 0x4d else 0x48;0x85;0xc0 lor((r land 7)lsl 3)lor(r land 7)]
let cmp m r n =
  M.bytes m [if r>=8 then 0x49 else 0x48;0x81;0xf8 lor(r land 7)];M.u32 m(Int64.of_int n)
let jump m cc label = M.branch m [0x0f;cc] label
let goto m label = M.branch m [0xe9] label
let data m opcode r label =
  M.bytes m [if r>=8 then 0x4c else 0x48;opcode;0x05 lor((r land 7)lsl 3)];
  M.rip_rel32 m M.Data label
let xmm m opcode r base displacement =
  M.u8 m 0xf3;
  M.u8 m (0x40 lor(if r>=8 then 4 else 0)lor(if base>=8 then 1 else 0));
  M.bytes m[0x0f;opcode;0x80 lor((r land 7)lsl 3)lor(base land 7)];
  if base land 7=4 then M.u8 m 0x24;
  M.u32 m(Int64.of_int displacement)
let native_frame m frame_register =
  let begin_offset=M.position m and codes=ref []in
  let record operation=codes:= !codes@[{W.code_offset=M.position m-begin_offset;operation}]in
  (* A fixed Win64 save area sits ABOVE Xen's RBP-relative local/temporary
     region. The internal argument registers and value layout stay unchanged. *)
  List.iter(fun r->if r>=8 then M.u8 m 0x41;M.u8 m(0x50 lor(r land 7));
    record(W.Push_nonvol r))[5;3;7;6;12;13;14;15];
  M.bytes m[0x48;0x81;0xec];M.u32 m 168L;record(W.Alloc_stack 168);
  mov m frame_register 4;record(W.Set_frame(frame_register,0));
  for r=6 to 15 do xmm m 0x7f r 4 (16*(r-6));record(W.Save_xmm(r,16*(r-6)))done;
  let prolog_size=M.position m-begin_offset in
  let return () =
    for r=6 to 15 do xmm m 0x6f r frame_register (16*(r-6))done;
    lea m 4 frame_register 168;
    List.iter(fun r->if r>=8 then M.u8 m 0x41;M.u8 m(0x58 lor(r land 7)))
      [15;14;13;12;6;7;3;5];M.u8 m 0xc3 in
  let finish () =
    m.M.frames<-m.M.frames@[{W.begin_offset;end_offset=M.position m;prolog_size;codes= !codes}]
  in return,finish
let function_prologue m =
  let return,finish=native_frame m 5 in fun()->return();finish()
let exit m status = int m 7 status;service "exit" m;M.bytes m[0x0f;0x0b]
let raw_syscall _ ~arity:_ = invalid_arg "Windows raw syscall lowering is unavailable"
let foreign_start _ ~main:_ = Error "extern_call is not implemented for x86_64-windows"
let start m =
  M.label m "_start";
  m.M.helper_prologue<-Some(native_frame m);
  m.M.align_calls<-true;
  (* The OS entry is nonreturning. Its caller's shadow space is not ours. *)
  let _,finish=native_frame m 5 in
  m.M.helper_end<-Some finish;
  service "startup" m

let emit ?(import=(fun library symbol->library,symbol)) m =
  let frames=ref [] and bridges=ref [] in
  let api ?(library="KERNEL32.dll") symbol sources =
    let result32=List.mem symbol["GetLastError";"VirtualFree";"ReadFile";"WriteFile";
      "CloseHandle";"MultiByteToWideChar";"WideCharToMultiByte";
      "GetCurrentDirectoryW";"GetCurrentProcessId";"Process32FirstW";"Process32NextW";
      "GetFileInformationByHandle";"GetFileInformationByHandleEx";"GetFileType"]in
    let library,symbol=import library symbol in
    let label="__xen_win_api_"^string_of_int(List.length !bridges)in
    bridges:= !bridges@[label,library,symbol,sources];call m label;
    (* Win64 only defines the low DWORD of BOOL/DWORD/int results. *)
    if result32 then M.bytes m[0x89;0xc0]in
  let g r = W.Gp r and n v = W.Immediate(Int64.of_int v)in
  (* Service frames save the full service ABI, independently of the weaker
     Win64 volatile set. RBP gives every wrapper a stable unwind base. *)
  let begin_ name =
    let begin_offset=M.position m in M.label m("__xen_win_"^name);
    let codes=ref[{W.code_offset=1;operation=W.Push_nonvol 5}]in
    let record operation=codes:= !codes@[{W.code_offset=M.position m-begin_offset;operation}]in
    M.bytes m[0x55;0x48;0x81;0xec];M.u32 m 256L;record(W.Alloc_stack 256);
    lea m 5 4 240;record(W.Set_frame(5,240));
    List.iter(fun r->store m 5 (-8*(r+1))r;
      if List.mem r [3;6;7;12;13;14;15]then record(W.Save_nonvol(r,240-8*(r+1))))
      [2;3;6;7;8;9;10;12;13;14;15];
    let prolog_size=M.position m-begin_offset in
    int m 0 0;for offset=18 to 26 do store m 5 (-8*offset)0 done;
    let finish () =
      List.iter(fun r->load m r 5 (-8*(r+1)))[2;3;6;7;8;9;10;12;13;14;15];
      M.bytes m[0x48;0x8d;0x65;16;0x5d;0xc3];
      frames:= !frames@[{W.begin_offset;end_offset=M.position m;prolog_size;codes= !codes}]in finish in
  let error () = service "error" m in
  let finish=begin_ "error" in
  api "GetLastError" [];
  (* Unknown native errors become EIO, never an out-of-range negated DWORD. *)
  let done_="__xen_win_error_done" in
  List.iter(fun(native,errno)->let next="__xen_win_error_"^string_of_int native in
    cmp m 0 native;jump m 0x85 next;int m 0 (-errno);goto m done_;M.label m next)
    [2,2;3,2;5,13;6,9;8,12;14,12;32,13;80,17;87,22;112,28;123,22;
     145,39;183,17;206,36;267,20;995,4;1113,84];
  int m 0 (-5);M.label m done_;finish();
  let finish=begin_ "alloc" in
  (* VirtualAlloc rejects size zero; Xen permits an empty raw allocation. *)
  mov m 2 6;test m 2;let nonzero="__xen_win_alloc_nonzero"in
  jump m 0x85 nonzero;int m 2 1;M.label m nonzero;
  api "VirtualAlloc" [n 0;g 2;n 0x3000;n 4];
  let ok="__xen_win_alloc_ok"in test m 0;jump m 0x85 ok;
  int m 0 (-12);M.label m ok;finish();
  let finish=begin_ "unmap" in
  api "VirtualFree" [g 7;n 0;n 0x8000];
  let ok="__xen_win_unmap_ok"in test m 0;jump m 0x85 ok;error();
  goto m "__xen_win_unmap_return";M.label m ok;int m 0 0;
  M.label m "__xen_win_unmap_return";finish();
  (* Xen fd 0/1/2 name the process standard handles. Opened files are native
     positive HANDLE values; ownership stays with the existing File runtime. *)
  let handle () =
    let ready="__xen_win_handle_"^string_of_int(M.position m)in
    cmp m 7 2;jump m 0x87 ready;
    int m 0 (-10);M.bytes m[0x48;0x29;0xf8];
    api "GetStdHandle" [g 0];mov m 7 0;M.label m ready in
  List.iter(fun(name,symbol)->
    let finish=begin_ name in handle();
    (* Cap each transfer to a signed DWORD; callers loop on partial progress. *)
    int m 0 0x7fffffff;M.bytes m[0x48;0x39;0xc2;0x48;0x0f;0x47;0xd0];
    lea m 8 5 (-144);int m 0 0;store m 5 (-144)0;
    api symbol [g 7;g 6;g 2;g 8;n 0];
    let ok="__xen_win_"^name^"_ok" and done_="__xen_win_"^name^"_return"in
    test m 0;jump m 0x85 ok;
    if name="read" then begin
      api "GetLastError" [];
      cmp m 0 109;jump m 0x84 ok;cmp m 0 38;jump m 0x84 ok
    end;
    error();goto m done_;
    M.label m ok;load m 0 5 (-144);M.label m done_;finish())
    ["read","ReadFile";"write","WriteFile"];
  let finish=begin_ "close"in handle();api "CloseHandle" [g 7];
  let ok="__xen_win_close_ok"in test m 0;jump m 0x85 ok;error();
  goto m "__xen_win_close_return";M.label m ok;int m 0 0;
  M.label m "__xen_win_close_return";finish();
  let finish=begin_ "open"in
  let failure="__xen_win_open_failure" and release="__xen_win_open_release"
  and done_="__xen_win_open_return"in
  (* 0 read, 1 truncate/create, 2 atomic append/create, 3 directory,
     4 metadata (internal). Reject unknown modes before opening a path. *)
  cmp m 6 4;jump m 0x86 "__xen_win_open_mode_ok";
  int m 0 (-22);goto m done_;M.label m "__xen_win_open_mode_ok";
  api "MultiByteToWideChar" [n 65001;n 8;g 7;n (-1);n 0;n 0];
  test m 0;jump m 0x84 failure;
  store m 5 (-152)0;M.bytes m[0x48;0xd1;0xe0];mov m 6 0;alloc m;
  test m 0;jump m 0x88 done_;store m 5 (-160)0;
  load m 7 5 (-64);load m 9 5 (-152);
  api "MultiByteToWideChar" [n 65001;n 8;g 7;n (-1);g 0;g 9];
  test m 0;jump m 0x84 failure;
  load m 7 5 (-160);load m 6 5 (-56);
  int m 2 0x80000000;int m 8 3;int m 9 0x80;
  cmp m 6 0;jump m 0x84 "__xen_win_open_create";
  cmp m 6 1;jump m 0x85 "__xen_win_open_not_truncate";
  int m 2 0x40000000;int m 8 2;goto m "__xen_win_open_create";
  M.label m "__xen_win_open_not_truncate";
  cmp m 6 2;jump m 0x85 "__xen_win_open_not_append";
  int m 2 4;int m 8 4;goto m "__xen_win_open_create";
  M.label m "__xen_win_open_not_append";
  int m 9 0x02000000; (* FILE_FLAG_BACKUP_SEMANTICS *)
  cmp m 6 4;jump m 0x85 "__xen_win_open_create";int m 2 0;
  M.label m "__xen_win_open_create";
  api "CreateFileW" [g 7;g 2;n 7;n 0;g 8;g 9;n 0];
  cmp m 0 (-1);jump m 0x85 release;
  M.label m failure;error();
  M.label m release;store m 5 (-168)0;load m 7 5 (-160);
  test m 7;jump m 0x84 "__xen_win_open_no_buffer";
  unmap m;M.label m "__xen_win_open_no_buffer";load m 0 5 (-168);
  M.label m done_;finish();
  let finish=begin_ "directory"in
  let invalid="__xen_win_directory_invalid" and done_="__xen_win_directory_return"
  and failed="__xen_win_directory_failed" and loop="__xen_win_directory_loop"in
  cmp m 2 68;jump m 0x82 invalid;cmp m 2 0x7fffffff;jump m 0x87 invalid;
  api "GetFileInformationByHandleEx" [g 7;n 14;g 6;g 2];
  test m 0;jump m 0x85 loop;
  api "GetLastError" [];cmp m 0 18;jump m 0x85 failed;
  int m 0 0;goto m done_;
  M.label m loop;mov m 7 6;int m 8 0;
  M.label m "__xen_win_directory_record";
  mov m 9 2;M.bytes m[0x4d;0x29;0xc1];cmp m 9 68;jump m 0x82 invalid;
  load32 m 0 7 60;cmp m 0 2;jump m 0x82 invalid;
  M.bytes m[0xa8;1];jump m 0x85 invalid;
  M.bytes m[0x48;0x83;0xc0;68;0x4c;0x39;0xc8];jump m 0x87 invalid;
  load32 m 10 7 0;test m 10;jump m 0x85 "__xen_win_directory_next";
  M.bytes m[0x4c;0x01;0xc0];goto m done_;
  M.label m "__xen_win_directory_next";
  M.bytes m[0x49;0x39;0xc2];jump m 0x82 invalid; (* next >= header+name *)
  M.bytes m[0x4d;0x39;0xca];jump m 0x87 invalid;
  M.bytes m[0x41;0xf6;0xc2;7];jump m 0x85 invalid;
  M.bytes m[0x4d;0x01;0xd0;0x4c;0x01;0xd7];goto m "__xen_win_directory_record";
  M.label m failed;error();goto m done_;
  M.label m invalid;int m 0 (-22);M.label m done_;finish();
  let finish=begin_ "cwd"in
  let failure="__xen_win_cwd_failure" and release="__xen_win_cwd_release"
  and done_="__xen_win_cwd_return"in
  api "GetCurrentDirectoryW" [n 0;n 0];
  test m 0;jump m 0x84 failure;store m 5 (-144)0;
  M.bytes m[0x48;0xd1;0xe0];mov m 6 0;alloc m;
  test m 0;jump m 0x88 done_;store m 5 (-152)0;
  load m 7 5 (-144);api "GetCurrentDirectoryW" [g 7;g 0];
  test m 0;jump m 0x84 failure;
  load m 2 5 (-144);M.bytes m[0x48;0x39;0xd0];jump m 0x82 "__xen_win_cwd_convert";
  int m 0 (-34);goto m release; (* directory grew between query and fill *)
  M.label m "__xen_win_cwd_convert";
  load m 7 5 (-152);load m 6 5 (-64);load m 9 5 (-56);
  api "WideCharToMultiByte" [n 65001;n 0x80;g 7;n (-1);n 0;n 0;n 0;n 0];
  test m 0;jump m 0x84 failure;
  test m 6;jump m 0x84 release;
  M.bytes m[0x4c;0x39;0xc8];jump m 0x86 "__xen_win_cwd_copy";
  int m 0 (-34);goto m release;
  M.label m "__xen_win_cwd_copy";
  (* Conversion capacity is the queried DWORD, never a truncated caller Int. *)
  mov m 9 0;
  api "WideCharToMultiByte" [n 65001;n 0x80;g 7;n (-1);g 6;g 9;n 0;n 0];
  test m 0;jump m 0x85 release;
  M.label m failure;error();
  M.label m release;store m 5 (-160)0;load m 7 5 (-152);
  test m 7;jump m 0x84 "__xen_win_cwd_no_buffer";unmap m;
  M.label m "__xen_win_cwd_no_buffer";load m 0 5 (-160);
  M.label m done_;finish();
  let finish=begin_ "metadata"in
  let failure="__xen_win_metadata_failure" and close_="__xen_win_metadata_close"
  and release="__xen_win_metadata_release" and done_="__xen_win_metadata_return"in
  int m 6 4;open_ m;test m 0;jump m 0x88 done_;store m 5 (-144)0;
  int m 6 64;alloc m;test m 0;jump m 0x88 close_;store m 5 (-152)0;
  load m 7 5 (-144);api "GetFileInformationByHandle" [g 7;g 0];
  test m 0;jump m 0x84 failure;
  api "GetFileType" [g 7];store m 5 (-176)0;
  load m 6 5 (-152);load m 7 5 (-56);
  load32 m 0 6 32;M.bytes m[0x48;0xc1;0xe0;32];load32 m 2 6 36;
  M.bytes m[0x48;0x09;0xd0];store m 7 0 0;
  load m 0 6 20;int m 2 0;int m 1 10000000;M.bytes m[0x48;0xf7;0xf1];
  imm m 1 11644473600L;M.bytes m[0x48;0x29;0xc8];store m 7 8 0;
  load32 m 0 6 0;M.bytes m[0x48;0xc1;0xe8;4;0x48;0x83;0xe0;1];store m 7 16 0;
  M.bytes m[0x48;0x83;0xf0;1];load m 2 5 (-176);cmp m 2 1;
  jump m 0x84 "__xen_win_metadata_kind";int m 0 0;
  M.label m "__xen_win_metadata_kind";store m 7 24 0;int m 0 0;goto m close_;
  M.label m failure;error();
  M.label m close_;store m 5 (-160)0;load m 7 5 (-144);close m;
  load m 2 5 (-160);test m 2;jump m 0x88 release;store m 5 (-160)0;
  M.label m release;load m 7 5 (-152);test m 7;jump m 0x84 "__xen_win_metadata_no_buffer";
  unmap m;M.label m "__xen_win_metadata_no_buffer";load m 0 5 (-160);
  M.label m done_;finish();
  let finish=begin_ "id"in api "GetCurrentProcessId" [];finish();
  let finish=begin_ "parent_id"in
  let failure="__xen_win_parent_failure" and release="__xen_win_parent_release"
  and done_="__xen_win_parent_return" and loop="__xen_win_parent_loop"in
  api "GetCurrentProcessId" [];store m 5 (-144)0;
  int m 6 568;alloc m;test m 0;jump m 0x88 done_;store m 5 (-152)0;
  int m 2 568;store m 0 0 2;
  api "CreateToolhelp32Snapshot" [n 2;n 0];cmp m 0 (-1);jump m 0x84 failure;
  store m 5 (-160)0;mov m 7 0;load m 6 5 (-152);
  api "Process32FirstW" [g 7;g 6];
  M.label m loop;test m 0;jump m 0x84 failure;
  load32 m 0 6 8;load m 2 5 (-144);M.bytes m[0x48;0x39;0xd0];
  jump m 0x84 "__xen_win_parent_found";
  api "Process32NextW" [g 7;g 6];goto m loop;
  M.label m "__xen_win_parent_found";load32 m 0 6 32;goto m release;
  M.label m failure;error();
  M.label m release;store m 5 (-168)0;load m 7 5 (-160);
  test m 7;jump m 0x84 "__xen_win_parent_no_handle";close m;
  load m 2 5 (-168);test m 2;jump m 0x88 "__xen_win_parent_no_handle";
  test m 0;jump m 0x89 "__xen_win_parent_no_handle";store m 5 (-168)0;
  M.label m "__xen_win_parent_no_handle";load m 7 5 (-152);unmap m;
  load m 0 5 (-168);M.label m done_;finish();
  let finish=begin_ "exit"in api "ExitProcess" [g 7];M.bytes m[0x0f;0x0b];finish();
  let finish=begin_ "startup"in
  let failed="__xen_win_startup_failed" and loop="__xen_win_startup_loop"
  and done_="__xen_win_startup_done"in
  api "GetCommandLineW" [];lea m 2 5 (-144);
  api ~library:"SHELL32.dll" "CommandLineToArgvW" [g 0;g 2];
  test m 0;jump m 0x84 failed;store m 5 (-152)0;
  load m 0 5 (-144); (* zero initialized count slot, written DWORD by Win32 *)
  cmp m 0 1;jump m 0x82 failed;M.bytes m[0x48;0xff;0xc8];
  store m 5 (-160)0;data m 0x89 0 "__xen_argc";
  M.bytes m[0x48;0x8d;0x34;0xc5;8;0;0;0];alloc m;
  test m 0;jump m 0x88 failed;store m 5 (-168)0;
  data m 0x89 0 "__xen_argv";int m 0 0;store m 5 (-176)0;
  M.label m loop;load m 0 5 (-176);load m 2 5 (-160);
  M.bytes m[0x48;0x39;0xd0];jump m 0x83 done_;
  load m 2 5 (-152);M.bytes m[0x48;0x8b;0x7c;0xc2;8];store m 5 (-184)7;
  api "WideCharToMultiByte" [n 65001;n 0x80;g 7;n (-1);n 0;n 0;n 0;n 0];
  test m 0;jump m 0x84 failed;store m 5 (-192)0;mov m 6 0;alloc m;
  test m 0;jump m 0x88 failed;store m 5 (-200)0;
  load m 7 5 (-184);load m 9 5 (-192);
  api "WideCharToMultiByte" [n 65001;n 0x80;g 7;n (-1);g 0;g 9;n 0;n 0];
  test m 0;jump m 0x84 failed;
  load m 0 5 (-176);load m 2 5 (-168);load m 6 5 (-200);
  M.bytes m[0x48;0x89;0x34;0xc2;0x48;0xff;0xc0];store m 5 (-176)0;goto m loop;
  M.label m done_;load m 0 5 (-168);load m 2 5 (-160);
  M.bytes m[0x48;0xc7;0x04;0xd0;0;0;0;0];load m 7 5 (-152);
  api "LocalFree" [g 7];goto m "__xen_win_startup_return";
  M.label m failed;
  let text="xen runtime error: Windows argument initialization failed\n"in
  M.add_rodata m "__xen_win_startup_error" text;
  int m 7 2;M.bytes m[0x48;0x8d;0x35];M.rip_rel32 m M.Rodata "__xen_win_startup_error";
  int m 2(String.length text);write m;exit m 1;
  M.label m "__xen_win_startup_return";finish();
  List.iter(fun(label,library,symbol,sources)->
    frames:= !frames@[W.emit_bridge m ~label ~library ~symbol
      ~arguments:(List.map(fun source->{W.scalar=W.I64;source})sources) ~result:(Some W.I64)])!bridges;
  !frames

let executable ~entry:_ m =
  M.end_helpers m;
  let functions=emit m in
  m.M.frames<-m.M.frames@functions;
  Pe_image.executable ~stack_reserve:0x2000000L ~entry:"_start" ~functions:m.M.frames m
