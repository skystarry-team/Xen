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
      "CloseHandle";"MultiByteToWideChar";"WideCharToMultiByte"]in
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
     145,39;183,17;206,36;995,4;1113,84];
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
  api "MultiByteToWideChar" [n 65001;n 8;g 7;n (-1);n 0;n 0];
  test m 0;jump m 0x84 failure;
  store m 5 (-152)0;M.bytes m[0x48;0xd1;0xe0];mov m 6 0;alloc m;
  test m 0;jump m 0x88 done_;store m 5 (-160)0;
  load m 7 5 (-64);load m 9 5 (-152);
  api "MultiByteToWideChar" [n 65001;n 8;g 7;n (-1);g 0;g 9];
  test m 0;jump m 0x84 failure;
  load m 7 5 (-160);load m 6 5 (-56);
  let reading="__xen_win_open_reading"and create="__xen_win_open_create"in
  test m 6;jump m 0x84 reading;int m 2 0x40000000;int m 8 2;goto m create;
  M.label m reading;int m 2 0x80000000;int m 8 3;M.label m create;
  api "CreateFileW" [g 7;g 2;n 7;n 0;g 8;n 0x80;n 0];
  cmp m 0 (-1);jump m 0x85 release;
  M.label m failure;error();
  M.label m release;store m 5 (-168)0;load m 7 5 (-160);
  test m 7;jump m 0x84 "__xen_win_open_no_buffer";
  unmap m;M.label m "__xen_win_open_no_buffer";load m 0 5 (-168);
  M.label m done_;finish();
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
