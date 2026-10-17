(* SPDX-License-Identifier: Apache-2.0 *)
(* Generated runtime code has the additional MIT OR Apache-2.0 permission in LICENSE.
   CPU algorithms use explicit platform services; no OS implementation is selected here. *)
module M = Machine_ir
module Make(R : Runtime_intf.S) = struct
let emit output ~fresh =
  (* Open using a temporary NUL-terminated copy of the Xen String. *)
  M.function_label output "__xen_file_open";
  M.bytes output [0x53;0x41;0x54;0x41;0x55;0x41;0x56;0x49;0x89;0xfc;0x49;0x89;0xf5;0x49;0x89;0xd6;0x48;0x31;0xc9];
  let scan=fresh "file_path_scan" and scan_done=fresh "file_path_scan_done" and nul=fresh "file_path_nul" and open_ret=fresh "file_open_ret" in
  M.label output scan;M.bytes output [0x4c;0x39;0xe9];M.branch output [0x0f;0x83] scan_done;
  M.bytes output [0x41;0x80;0x3c;0x0c;0x00];M.branch output [0x0f;0x84] nul;M.bytes output [0x48;0xff;0xc1];M.branch output [0xe9] scan;
  M.label output nul;M.bytes output [0x48;0xc7;0xc0;0x00;0xf0;0xff;0xff];M.branch output [0xe9] open_ret;
  M.label output scan_done;M.bytes output [0x4c;0x89;0xee;0x48;0xff;0xc6]; R.alloc output; M.bytes output [0x48;0x3d;0x01;0xf0;0xff;0xff];
  M.branch output [0x0f;0x83] open_ret;M.bytes output [0x48;0x89;0xc3;0x48;0x89;0xc7;0x4c;0x89;0xe6;0x4c;0x89;0xe9;0xf3;0xa4;0x42;0xc6;0x04;0x2b;0x00];
  M.bytes output [0x48;0x89;0xdf;0x4c;0x89;0xf6]; R.open_ output; M.bytes output [0x49;0x89;0xc4;0x48;0x89;0xdf;0x4c;0x89;0xee;0x48;0xff;0xc6]; R.unmap output; M.bytes output [0x4c;0x89;0xe0];
  M.label output open_ret;M.bytes output [0x41;0x5e;0x41;0x5d;0x41;0x5c;0x5b];M.ret output;
  (* Grow an anonymous mapping geometrically while reading to EOF. *)
  M.function_label output "__xen_file_read";M.bytes output [0x53;0x41;0x54;0x41;0x55;0x41;0x56;0x41;0x57;0x49;0x89;0xfc;0x45;0x31;0xed;0x41;0xbf;0x00;0x10;0x00;0x00]; M.bytes output [0x4c;0x89;0xfe]; R.alloc output; M.bytes output [0x48;0x3d;0x01;0xf0;0xff;0xff];
  let read_fail=fresh "file_read_fail" and read_loop=fresh "file_read_loop" and read_grow=fresh "file_read_grow" and grow_fail=fresh "file_read_grow_fail" and read_retry=fresh "file_read_retry" and read_done=fresh "file_read_done" and read_ret=fresh "file_read_ret" in
  M.branch output [0x0f;0x83] read_fail;M.bytes output [0x49;0x89;0xc5;0x45;0x31;0xf6];M.label output read_loop;
  M.bytes output [0x4d;0x39;0xfe];M.branch output [0x0f;0x83] read_grow;M.label output read_retry;
  M.bytes output [0x4c;0x89;0xe7;0x4b;0x8d;0x74;0x35;0x00;0x4c;0x89;0xfa;0x4c;0x29;0xf2;]; R.read output; M.bytes output [0x48;0x83;0xf8;0xfc];M.branch output [0x0f;0x84] read_retry;
  M.bytes output [0x48;0x85;0xc0];M.branch output [0x0f;0x88] read_fail;M.branch output [0x0f;0x84] read_done;M.bytes output [0x49;0x01;0xc6];M.branch output [0xe9] read_loop;
  M.label output read_grow;M.bytes output [0x41;0x57;0x4d;0x01;0xff];M.branch output [0x0f;0x82] grow_fail;
  M.bytes output [0x4c;0x89;0xfe]; R.alloc output; M.bytes output [0x48;0x3d;0x01;0xf0;0xff;0xff];M.branch output [0x0f;0x83] grow_fail;
  M.bytes output [0x48;0x89;0xc3;0x48;0x89;0xc7;0x4c;0x89;0xee;0x4c;0x89;0xf1;0xf3;0xa4;0x4c;0x89;0xef;0x48;0x8b;0x34;0x24]; R.unmap output; M.bytes output [0x48;0x83;0xc4;0x08;0x49;0x89;0xdd];M.branch output [0xe9] read_loop;
  M.label output grow_fail;M.bytes output [0x48;0x83;0xc4;8];M.branch output [0xe9] read_fail;
  M.label output read_done;M.bytes output [0x4d;0x85;0xf6];let read_nonempty=fresh "file_read_nonempty" in M.branch output [0x0f;0x85] read_nonempty;
  M.bytes output [0x4c;0x89;0xef;0x4c;0x89;0xfe]; R.unmap output; M.bytes output [0x31;0xc0;0x31;0xd2;0x31;0xc9];M.branch output [0xe9] read_ret;
  M.label output read_nonempty;M.bytes output [0x4c;0x89;0xe8;0x4c;0x89;0xf2;0x4c;0x89;0xf9];M.branch output [0xe9] read_ret;
  M.label output read_fail;M.bytes output [0x4d;0x85;0xed];let no_unmap=fresh "file_read_no_unmap" in M.branch output [0x0f;0x84] no_unmap;M.bytes output [0x4c;0x89;0xef;0x4c;0x89;0xfe]; R.unmap output;M.label output no_unmap;M.bytes output [0x31;0xc0;0x31;0xd2;0x48;0xc7;0xc1;0xff;0xff;0xff;0xff];M.label output read_ret;M.bytes output [0x41;0x5f;0x41;0x5e;0x41;0x5d;0x41;0x5c;0x5b];M.ret output;
  M.function_label output "__xen_file_write";M.bytes output [0x41;0x54;0x41;0x55;0x49;0x89;0xfc;0x49;0x89;0xf5];
  let write_loop=fresh "file_write_loop" and write_retry=fresh "file_write_retry" and write_ok=fresh "file_write_ok" and write_ret=fresh "file_write_ret" in
  M.label output write_loop;M.bytes output [0x48;0x85;0xd2];M.branch output [0x0f;0x84] write_ok;M.label output write_retry;M.bytes output [0x4c;0x89;0xe7;0x4c;0x89;0xee]; R.write output; M.bytes output [0x48;0x83;0xf8;0xfc];M.branch output [0x0f;0x84] write_retry;M.bytes output [0x48;0x85;0xc0];M.branch output [0x0f;0x88] write_ret;M.bytes output [0x49;0x01;0xc5;0x48;0x29;0xc2];M.branch output [0xe9] write_loop;M.label output write_ok;M.bytes output [0x31;0xc0];M.label output write_ret;M.bytes output [0x41;0x5d;0x41;0x5c];M.ret output

(* read_text/read_ints/read_floats: rdi/rsi = path bytes/length,
   rdx = 0 text / 1 signed integer / 2 F64, rcx = result descriptor.
   Return status in rax: 0 success, 1 NUL path, 2 open, 3 read, 4 close,
   5 syntax, 6 range, 7 size, 8 allocation. Callee-saved GP registers survive.
   Copy the path, close the fd once, release temporary mappings on every path,
   and publish an owned String/Vec only after all validation succeeds.
   Numeric input is counted/validated before allocating its exact output size. *)
let emit_builtin output =
  M.function_label ~frame:14 output "__xen_read_builtin";
  M.bytes output [0xf3;0x0f;0x1e;0xfa]; (* endbr64 *)
  M.bytes output [0x41;0x57]; (* push   r15 *)
  M.bytes output [0x49;0x89;0xd7]; (* mov    r15,rdx *)
  M.bytes output [0x31;0xd2]; (* xor    edx,edx *)
  M.bytes output [0x31;0xc0]; (* xor    eax,eax *)
  M.bytes output [0x41;0x56]; (* push   r14 *)
  M.bytes output [0x41;0x55]; (* push   r13 *)
  M.bytes output [0x41;0x54]; (* push   r12 *)
  M.bytes output [0x49;0x89;0xfc]; (* mov    r12,rdi *)
  M.bytes output [0x55]; (* push   rbp *)
  M.bytes output [0x53]; (* push   rbx *)
  M.bytes output [0x48;0x89;0xf3]; (* mov    rbx,rsi *)
  M.bytes output [0x48;0x83;0xec;0x38]; (* sub    rsp,0x38 *)
  M.bytes output [0x48;0x89;0x4c;0x24;0x30]; (* output descriptor; r14 may be the platform frame *)
  M.bytes output [0x48;0x89;0x11]; (* mov    QWORD PTR [rcx],rdx *)
  M.bytes output [0x48;0x89;0x51;0x08]; (* mov    QWORD PTR [rcx+0x8],rdx *)
  M.bytes output [0x48;0x89;0x51;0x10]; (* mov    QWORD PTR [rcx+0x10],rdx *)
  M.label output "__xen_read_path_scan";
  M.bytes output [0x48;0x39;0xd8]; (* cmp    rax,rbx *)
  M.branch output [0x0f;0x8d] "__xen_read_path_allocate"; (* jge *)
  M.bytes output [0x41;0x80;0x3c;0x04;0x00]; (* cmp    BYTE PTR [r12+rax*1],0x0 *)
  M.branch output [0x0f;0x84] "__xen_read_nul_error"; (* je *)
  M.bytes output [0x48;0xff;0xc0]; (* inc    rax *)
  M.branch output [0xe9] "__xen_read_path_scan"; (* jmp *)
  M.label output "__xen_read_path_allocate";
  M.bytes output [0x48;0x8d;0x6b;0x01]; (* lea    rbp,[rbx+0x1] *)
  M.bytes output [0x48;0x89;0xef]; (* mov    rdi,rbp *)
  M.branch output [0xe8] "__xen_read_allocate"; (* call *)
  M.bytes output [0x49;0x89;0xc0]; (* mov    r8,rax *)
  M.bytes output [0x31;0xc0]; (* xor    eax,eax *)
  M.bytes output [0x4d;0x85;0xc0]; (* test   r8,r8 *)
  M.branch output [0x0f;0x84] "__xen_read_alloc_error"; (* je *)
  M.label output "__xen_read_path_copy";
  M.bytes output [0x48;0x39;0xd8]; (* cmp    rax,rbx *)
  M.branch output [0x0f;0x8d] "__xen_read_path_terminate"; (* jge *)
  M.bytes output [0x41;0x8a;0x14;0x04]; (* mov    dl,BYTE PTR [r12+rax*1] *)
  M.bytes output [0x41;0x88;0x14;0x00]; (* mov    BYTE PTR [r8+rax*1],dl *)
  M.bytes output [0x48;0xff;0xc0]; (* inc    rax *)
  M.branch output [0xe9] "__xen_read_path_copy"; (* jmp *)
  M.label output "__xen_read_path_terminate";
  M.bytes output [0x41;0xc6;0x04;0x18;0x00]; (* mov    BYTE PTR [r8+rbx*1],0x0 *)
  M.bytes output [0x4c;0x89;0xc7]; (* mov rdi,r8 *)
  M.u8 output 0xbe;M.u32 output (Int64.of_int R.open_read_flags);
  R.open_ output;
  M.bytes output [0x48;0x89;0x04;0x24]; (* mov    QWORD PTR [rsp],rax *)
  M.bytes output [0x4c;0x89;0xc7]; (* mov    rdi,r8 *)
  M.bytes output [0x48;0x89;0xee]; (* mov    rsi,rbp *)
  R.unmap output;
  M.bytes output [0x48;0x83;0x3c;0x24;0x00]; (* cmp    QWORD PTR [rsp],0x0 *)
  M.bytes output [0x41;0xbd;0x02;0x00;0x00;0x00]; (* mov    r13d,0x2 *)
  M.branch output [0x0f;0x88] "__xen_read_return"; (* js *)
  M.bytes output [0xbf;0x00;0x10;0x00;0x00]; (* mov    edi,0x1000 *)
  M.bytes output [0x45;0x31;0xe4]; (* xor    r12d,r12d *)
  M.bytes output [0xbd;0x00;0x10;0x00;0x00]; (* mov    ebp,0x1000 *)
  M.bytes output [0x49;0xbd;0xff;0xff;0xff;0xff;0xff;0xff;0xff;0x3f]; (* movabs r13,0x3fffffffffffffff *)
  M.branch output [0xe8] "__xen_read_allocate"; (* call *)
  M.bytes output [0x48;0x89;0xc3]; (* mov    rbx,rax *)
  M.bytes output [0x48;0x85;0xc0]; (* test   rax,rax *)
  M.branch output [0x0f;0x85] "__xen_read_read"; (* jne *)
  M.bytes output [0x48;0x8b;0x3c;0x24]; (* mov    rdi,QWORD PTR [rsp] *)
  R.close output;
  M.branch output [0xe9] "__xen_read_alloc_error"; (* jmp *)
  M.label output "__xen_read_grow_release";
  M.bytes output [0x48;0x89;0xdf]; (* mov    rdi,rbx *)
  M.bytes output [0x48;0x89;0xee]; (* mov    rsi,rbp *)
  R.unmap output;
  M.bytes output [0x48;0x8b;0x6c;0x24;0x08]; (* mov    rbp,QWORD PTR [rsp+0x8] *)
  M.bytes output [0x48;0x89;0xd3]; (* mov    rbx,rdx *)
  M.label output "__xen_read_read";
  M.bytes output [0x48;0x89;0xea]; (* mov    rdx,rbp *)
  M.bytes output [0x48;0x8b;0x3c;0x24]; (* mov    rdi,QWORD PTR [rsp] *)
  M.bytes output [0x4a;0x8d;0x34;0x23]; (* lea    rsi,[rbx+r12*1] *)
  M.bytes output [0x4c;0x29;0xe2]; (* sub    rdx,r12 *)
  R.read output;
  M.bytes output [0x48;0x85;0xc0]; (* test   rax,rax *)
  M.branch output [0x0f;0x88] "__xen_read_read_error"; (* js *)
  M.branch output [0x0f;0x84] "__xen_read_read_eof"; (* je *)
  M.bytes output [0x49;0x01;0xc4]; (* add    r12,rax *)
  M.bytes output [0x4c;0x39;0xe5]; (* cmp    rbp,r12 *)
  M.branch output [0x0f;0x85] "__xen_read_read"; (* jne *)
  M.bytes output [0x4c;0x39;0xed]; (* cmp    rbp,r13 *)
  M.branch output [0x0f;0x8f] "__xen_read_size_error"; (* jg *)
  M.bytes output [0x48;0x8d;0x44;0x2d;0x00]; (* lea    rax,[rbp+rbp*1+0x0] *)
  M.bytes output [0x48;0x89;0xc7]; (* mov    rdi,rax *)
  M.bytes output [0x48;0x89;0x44;0x24;0x08]; (* mov    QWORD PTR [rsp+0x8],rax *)
  M.branch output [0xe8] "__xen_read_allocate"; (* call *)
  M.bytes output [0x48;0x89;0xc2]; (* mov    rdx,rax *)
  M.bytes output [0x48;0x85;0xc0]; (* test   rax,rax *)
  M.branch output [0x0f;0x84] "__xen_read_grow_alloc_error"; (* je *)
  M.bytes output [0x31;0xc0]; (* xor    eax,eax *)
  M.label output "__xen_read_grow_copy";
  M.bytes output [0x4c;0x39;0xe0]; (* cmp    rax,r12 *)
  M.branch output [0x0f;0x8d] "__xen_read_grow_release"; (* jge *)
  M.bytes output [0x8a;0x0c;0x03]; (* mov    cl,BYTE PTR [rbx+rax*1] *)
  M.bytes output [0x88;0x0c;0x02]; (* mov    BYTE PTR [rdx+rax*1],cl *)
  M.bytes output [0x48;0xff;0xc0]; (* inc    rax *)
  M.branch output [0xe9] "__xen_read_grow_copy"; (* jmp *)
  M.label output "__xen_read_size_error";
  M.bytes output [0x41;0xbd;0x07;0x00;0x00;0x00]; (* mov    r13d,0x7 *)
  M.branch output [0xe9] "__xen_read_close"; (* jmp *)
  M.label output "__xen_read_grow_alloc_error";
  M.bytes output [0x41;0xbd;0x08;0x00;0x00;0x00]; (* mov    r13d,0x8 *)
  M.branch output [0xe9] "__xen_read_close"; (* jmp *)
  M.label output "__xen_read_read_error";
  M.bytes output [0x41;0xbd;0x03;0x00;0x00;0x00]; (* mov    r13d,0x3 *)
  M.branch output [0xe9] "__xen_read_close"; (* jmp *)
  M.label output "__xen_read_read_eof";
  M.bytes output [0x45;0x31;0xed]; (* xor    r13d,r13d *)
  M.label output "__xen_read_close";
  M.bytes output [0x48;0x8b;0x3c;0x24]; (* mov    rdi,QWORD PTR [rsp] *)
  R.close output;
  M.bytes output [0x45;0x85;0xed]; (* test   r13d,r13d *)
  M.branch output [0x0f;0x85] "__xen_read_input_release"; (* jne *)
  M.bytes output [0x48;0x85;0xc0]; (* test   rax,rax *)
  M.branch output [0x0f;0x88] "__xen_read_close_error"; (* js *)
  M.bytes output [0x45;0x85;0xed]; (* test   r13d,r13d *)
  M.branch output [0x0f;0x84] "__xen_read_select_kind"; (* je *)
  M.branch output [0xe9] "__xen_read_input_release"; (* jmp *)
  M.label output "__xen_read_close_error";
  M.bytes output [0x41;0xbd;0x04;0x00;0x00;0x00]; (* mov    r13d,0x4 *)
  M.branch output [0xe9] "__xen_read_input_release"; (* jmp *)
  M.label output "__xen_read_select_kind";
  M.bytes output [0x4d;0x85;0xff]; (* test   r15,r15 *)
  M.branch output [0x0f;0x85] "__xen_read_count_init"; (* jne *)
  M.bytes output [0x4d;0x85;0xe4]; (* test   r12,r12 *)
  M.branch output [0x0f;0x84] "__xen_read_input_release"; (* je *)
  M.bytes output [0x4c;0x89;0xe7]; (* mov    rdi,r12 *)
  M.branch output [0xe8] "__xen_read_allocate"; (* call *)
  M.bytes output [0x48;0x89;0xc2]; (* mov    rdx,rax *)
  M.bytes output [0x48;0x85;0xc0]; (* test   rax,rax *)
  M.branch output [0x0f;0x84] "__xen_read_values_alloc_error"; (* je *)
  M.label output "__xen_read_text_copy";
  M.bytes output [0x4d;0x39;0xfc]; (* cmp    r12,r15 *)
  M.branch output [0x0f;0x8e] "__xen_read_text_release"; (* jle *)
  M.bytes output [0x42;0x8a;0x04;0x3b]; (* mov    al,BYTE PTR [rbx+r15*1] *)
  M.bytes output [0x42;0x88;0x04;0x3a]; (* mov    BYTE PTR [rdx+r15*1],al *)
  M.bytes output [0x49;0xff;0xc7]; (* inc    r15 *)
  M.branch output [0xe9] "__xen_read_text_copy"; (* jmp *)
  M.label output "__xen_read_text_release";
  M.bytes output [0x48;0x89;0xdf]; (* mov    rdi,rbx *)
  M.bytes output [0x48;0x89;0xee]; (* mov    rsi,rbp *)
  R.unmap output;
  M.bytes output [0x4c;0x8b;0x5c;0x24;0x30];M.bytes output [0x49;0x89;0x13]; (* mov    QWORD PTR [r11],rdx *)
  M.bytes output [0x4c;0x8b;0x5c;0x24;0x30];M.bytes output [0x4d;0x89;0x63;0x08]; (* mov    QWORD PTR [r11+0x8],r12 *)
  M.branch output [0xe9] "__xen_read_result_owned"; (* jmp *)
  M.label output "__xen_read_count_init";
  M.bytes output [0x31;0xc0]; (* xor    eax,eax *)
  M.bytes output [0x31;0xd2]; (* xor    edx,edx *)
  M.bytes output [0x48;0x89;0x04;0x24]; (* mov    QWORD PTR [rsp],rax *)
  M.label output "__xen_read_count_scan";
  M.bytes output [0x49;0x39;0xd4]; (* cmp    r12,rdx *)
  M.branch output [0x0f;0x8e] "__xen_read_count_done"; (* jle *)
  M.label output "__xen_read_count_whitespace";
  M.bytes output [0x0f;0xb6;0x3c;0x13]; (* movzx  edi,BYTE PTR [rbx+rdx*1] *)
  M.branch output [0xe8] "__xen_numeric_whitespace"; (* call *)
  M.bytes output [0x85;0xc0]; (* test   eax,eax *)
  M.branch output [0x0f;0x84] "__xen_read_count_token_start"; (* je *)
  M.bytes output [0x48;0xff;0xc2]; (* inc    rdx *)
  M.bytes output [0x49;0x39;0xd4]; (* cmp    r12,rdx *)
  M.branch output [0x0f;0x85] "__xen_read_count_whitespace"; (* jne *)
  M.branch output [0xe9] "__xen_read_count_done"; (* jmp *)
  M.label output "__xen_read_count_token_start";
  M.bytes output [0x48;0x89;0x54;0x24;0x08]; (* mov    QWORD PTR [rsp+0x8],rdx *)
  M.label output "__xen_read_count_token_end";
  M.bytes output [0x48;0x8b;0x44;0x24;0x08]; (* mov    rax,QWORD PTR [rsp+0x8] *)
  M.bytes output [0x49;0x39;0xc4]; (* cmp    r12,rax *)
  M.branch output [0x0f;0x8e] "__xen_read_validate_int"; (* jle *)
  M.bytes output [0x0f;0xb6;0x3c;0x03]; (* movzx  edi,BYTE PTR [rbx+rax*1] *)
  M.branch output [0xe8] "__xen_numeric_whitespace"; (* call *)
  M.bytes output [0x85;0xc0]; (* test   eax,eax *)
  M.branch output [0x0f;0x85] "__xen_read_validate_int"; (* jne *)
  M.bytes output [0x48;0xff;0x44;0x24;0x08]; (* inc    QWORD PTR [rsp+0x8] *)
  M.branch output [0xe9] "__xen_read_count_token_end"; (* jmp *)
  M.label output "__xen_read_validate_int";
  M.bytes output [0x48;0x8b;0x74;0x24;0x08]; (* mov    rsi,QWORD PTR [rsp+0x8] *)
  M.bytes output [0x48;0x8d;0x3c;0x13]; (* lea    rdi,[rbx+rdx*1] *)
  M.bytes output [0x48;0x29;0xd6]; (* sub    rsi,rdx *)
  M.bytes output [0x49;0x83;0xff;0x01]; (* cmp    r15,0x1 *)
  M.branch output [0x0f;0x85] "__xen_read_validate_float"; (* jne *)
  M.bytes output [0x48;0x8d;0x54;0x24;0x20]; (* lea    rdx,[rsp+0x20] *)
  M.branch output [0xe8] "__xen_numeric_parse_int"; (* call *)
  M.branch output [0xe9] "__xen_read_validate_result"; (* jmp *)
  M.label output "__xen_read_validate_float";
  M.bytes output [0x48;0x8d;0x54;0x24;0x28]; (* lea    rdx,[rsp+0x28] *)
  M.branch output [0xe8] "__xen_numeric_parse_float"; (* call *)
  M.label output "__xen_read_validate_result";
  M.bytes output [0x89;0xc2]; (* mov    edx,eax *)
  M.bytes output [0x85;0xc0]; (* test   eax,eax *)
  M.branch output [0x0f;0x84] "__xen_read_count_limit"; (* je *)
  M.bytes output [0x48;0x89;0xdf]; (* mov    rdi,rbx *)
  M.bytes output [0x48;0x89;0xee]; (* mov    rsi,rbp *)
  R.unmap output;
  M.branch output [0xe9] "__xen_read_token_error"; (* jmp *)
  M.label output "__xen_read_count_limit";
  M.bytes output [0x48;0xb9;0xff;0xff;0xff;0xff;0xff;0xff;0xff;0x0f]; (* movabs rcx,0xfffffffffffffff *)
  M.bytes output [0x48;0x39;0x0c;0x24]; (* cmp    QWORD PTR [rsp],rcx *)
  M.branch output [0x0f;0x85] "__xen_read_count_next"; (* jne *)
  M.bytes output [0x48;0x89;0xdf]; (* mov    rdi,rbx *)
  M.bytes output [0x48;0x89;0xee]; (* mov    rsi,rbp *)
  R.unmap output;
  M.bytes output [0xba;0x07;0x00;0x00;0x00]; (* mov    edx,0x7 *)
  M.branch output [0xe9] "__xen_read_token_error"; (* jmp *)
  M.label output "__xen_read_count_next";
  M.bytes output [0x48;0xff;0x04;0x24]; (* inc    QWORD PTR [rsp] *)
  M.bytes output [0x48;0x8b;0x54;0x24;0x08]; (* mov    rdx,QWORD PTR [rsp+0x8] *)
  M.branch output [0xe9] "__xen_read_count_scan"; (* jmp *)
  M.label output "__xen_read_token_error";
  M.bytes output [0x41;0x89;0xd5]; (* mov    r13d,edx *)
  M.branch output [0xe9] "__xen_read_return"; (* jmp *)
  M.label output "__xen_read_count_done";
  M.bytes output [0x48;0x83;0x3c;0x24;0x00]; (* cmp    QWORD PTR [rsp],0x0 *)
  M.branch output [0x0f;0x85] "__xen_read_values_allocate"; (* jne *)
  M.label output "__xen_read_input_release";
  M.bytes output [0x48;0x89;0xdf]; (* mov    rdi,rbx *)
  M.bytes output [0x48;0x89;0xee]; (* mov    rsi,rbp *)
  R.unmap output;
  M.branch output [0xe9] "__xen_read_return"; (* jmp *)
  M.label output "__xen_read_values_allocate";
  M.bytes output [0x48;0x8b;0x04;0x24]; (* mov    rax,QWORD PTR [rsp] *)
  M.bytes output [0x48;0x8d;0x3c;0xc5;0x00;0x00;0x00;0x00]; (* lea    rdi,[rax*8+0x0] *)
  M.branch output [0xe8] "__xen_read_allocate"; (* call *)
  M.bytes output [0x48;0x89;0x44;0x24;0x10]; (* mov    QWORD PTR [rsp+0x10],rax *)
  M.bytes output [0x48;0x85;0xc0]; (* test   rax,rax *)
  M.branch output [0x0f;0x84] "__xen_read_values_alloc_error"; (* je *)
  M.bytes output [0x48;0x89;0x44;0x24;0x18]; (* mov    QWORD PTR [rsp+0x18],rax *)
  M.bytes output [0x31;0xd2]; (* xor    edx,edx *)
  M.branch output [0xe9] "__xen_read_values_scan"; (* jmp *)
  M.label output "__xen_read_values_alloc_error";
  M.bytes output [0x48;0x89;0xdf]; (* mov    rdi,rbx *)
  M.bytes output [0x48;0x89;0xee]; (* mov    rsi,rbp *)
  R.unmap output;
  M.branch output [0xe9] "__xen_read_alloc_error"; (* jmp *)
  M.label output "__xen_read_values_skip_space";
  M.bytes output [0x48;0xff;0xc2]; (* inc    rdx *)
  M.bytes output [0x49;0x39;0xd4]; (* cmp    r12,rdx *)
  M.branch output [0x0f;0x84] "__xen_read_values_release"; (* je *)
  M.label output "__xen_read_values_whitespace";
  M.bytes output [0x0f;0xb6;0x3c;0x13]; (* movzx  edi,BYTE PTR [rbx+rdx*1] *)
  M.branch output [0xe8] "__xen_numeric_whitespace"; (* call *)
  M.bytes output [0x85;0xc0]; (* test   eax,eax *)
  M.branch output [0x0f;0x85] "__xen_read_values_skip_space"; (* jne *)
  M.bytes output [0x48;0x89;0x54;0x24;0x08]; (* mov    QWORD PTR [rsp+0x8],rdx *)
  M.label output "__xen_read_values_token_end";
  M.bytes output [0x48;0x8b;0x44;0x24;0x08]; (* mov    rax,QWORD PTR [rsp+0x8] *)
  M.bytes output [0x49;0x39;0xc4]; (* cmp    r12,rax *)
  M.branch output [0x0f;0x8f] "__xen_read_values_token_space"; (* jg *)
  M.label output "__xen_read_values_parse";
  M.bytes output [0x48;0x8b;0x74;0x24;0x08]; (* mov    rsi,QWORD PTR [rsp+0x8] *)
  M.bytes output [0x48;0x8d;0x3c;0x13]; (* lea    rdi,[rbx+rdx*1] *)
  M.bytes output [0x48;0x29;0xd6]; (* sub    rsi,rdx *)
  M.bytes output [0x48;0x8b;0x54;0x24;0x18]; (* mov    rdx,QWORD PTR [rsp+0x18] *)
  M.bytes output [0x49;0x83;0xff;0x01]; (* cmp    r15,0x1 *)
  M.branch output [0x0f;0x85] "__xen_read_values_float"; (* jne *)
  M.branch output [0xe8] "__xen_numeric_parse_int"; (* call *)
  M.label output "__xen_read_values_next";
  M.bytes output [0x48;0x83;0x44;0x24;0x18;0x08]; (* add    QWORD PTR [rsp+0x18],0x8 *)
  M.bytes output [0x48;0x8b;0x54;0x24;0x08]; (* mov    rdx,QWORD PTR [rsp+0x8] *)
  M.label output "__xen_read_values_scan";
  M.bytes output [0x49;0x39;0xd4]; (* cmp    r12,rdx *)
  M.branch output [0x0f;0x8f] "__xen_read_values_whitespace"; (* jg *)
  M.branch output [0xe9] "__xen_read_values_release"; (* jmp *)
  M.label output "__xen_read_values_token_space";
  M.bytes output [0x0f;0xb6;0x3c;0x03]; (* movzx  edi,BYTE PTR [rbx+rax*1] *)
  M.branch output [0xe8] "__xen_numeric_whitespace"; (* call *)
  M.bytes output [0x85;0xc0]; (* test   eax,eax *)
  M.branch output [0x0f;0x85] "__xen_read_values_parse"; (* jne *)
  M.bytes output [0x48;0xff;0x44;0x24;0x08]; (* inc    QWORD PTR [rsp+0x8] *)
  M.branch output [0xe9] "__xen_read_values_token_end"; (* jmp *)
  M.label output "__xen_read_values_float";
  M.branch output [0xe8] "__xen_numeric_parse_float"; (* call *)
  M.branch output [0xe9] "__xen_read_values_next"; (* jmp *)
  M.label output "__xen_read_values_release";
  M.bytes output [0x48;0x89;0xdf]; (* mov    rdi,rbx *)
  M.bytes output [0x48;0x89;0xee]; (* mov    rsi,rbp *)
  R.unmap output;
  M.bytes output [0x48;0x8b;0x44;0x24;0x10]; (* mov    rax,QWORD PTR [rsp+0x10] *)
  M.bytes output [0x4c;0x8b;0x5c;0x24;0x30];M.bytes output [0x49;0x89;0x03]; (* mov    QWORD PTR [r11],rax *)
  M.bytes output [0x48;0x8b;0x04;0x24]; (* mov    rax,QWORD PTR [rsp] *)
  M.bytes output [0x4c;0x8b;0x5c;0x24;0x30];M.bytes output [0x49;0x89;0x43;0x08]; (* mov    QWORD PTR [r11+0x8],rax *)
  (* Vec word 2 is capacity in bytes, unlike String's ownership marker.
     These exact-size Int/F64 allocations contain count*8 bytes. *)
  M.bytes output [0x48;0xc1;0xe0;0x03]; (* shl rax,3 *)
  M.bytes output [0x4c;0x8b;0x5c;0x24;0x30];M.bytes output [0x49;0x89;0x43;0x10]; (* mov [r11+16],rax *)
  M.branch output [0xe9] "__xen_read_return";
  M.label output "__xen_read_result_owned";
  M.bytes output [0x4c;0x8b;0x5c;0x24;0x30];M.bytes output [0x49;0xc7;0x43;0x10;0x01;0x00;0x00;0x00]; (* mov    QWORD PTR [r11+0x10],0x1 *)
  M.branch output [0xe9] "__xen_read_return"; (* jmp *)
  M.label output "__xen_read_alloc_error";
  M.bytes output [0x41;0xbd;0x08;0x00;0x00;0x00]; (* mov    r13d,0x8 *)
  M.branch output [0xe9] "__xen_read_return"; (* jmp *)
  M.label output "__xen_read_nul_error";
  M.bytes output [0x41;0xbd;0x01;0x00;0x00;0x00]; (* mov    r13d,0x1 *)
  M.label output "__xen_read_return";
  M.bytes output [0x48;0x83;0xc4;0x38]; (* add    rsp,0x38 *)
  M.bytes output [0x44;0x89;0xe8]; (* mov    eax,r13d *)
  M.bytes output [0x5b]; (* pop    rbx *)
  M.bytes output [0x5d]; (* pop    rbp *)
  M.bytes output [0x41;0x5c]; (* pop    r12 *)
  M.bytes output [0x41;0x5d]; (* pop    r13 *)
  M.bytes output [0x41;0x5e]; (* pop    r14 *)
  M.bytes output [0x41;0x5f]; (* pop    r15 *)
  M.ret output; (* ret *)
  M.function_label output "__xen_read_allocate";
  (* The read helper accepts size in rdi and returns NULL on failure. Do not
     depend on a platform's incidental rdi value after allocation. *)
  M.bytes output [0x48;0x89;0xfe]; (* mov rsi,rdi *)
  R.alloc output;
  M.bytes output [0x48;0x3d;0x01;0xf0;0xff;0xff]; (* cmp rax,-4095 *)
  M.branch output [0x0f;0x82] "__xen_read_allocate_return";
  M.bytes output [0x31;0xc0]; (* xor eax,eax *)
  M.label output "__xen_read_allocate_return";
  M.ret output
end
