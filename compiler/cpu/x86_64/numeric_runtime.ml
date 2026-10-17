(* SPDX-License-Identifier: Apache-2.0 *)
(* Generated runtime code has the additional MIT OR Apache-2.0 permission in LICENSE.
   Pure x86-64 token parsing; no OS services or host assembler are required.
   Parsers take rdi = token bytes, rsi = length, rdx = output scalar address,
   returning eax = 0 success / 5 syntax / 6 range. Callee-saved GP registers
   survive; caller-saved GP/FP registers and flags may change. Preserve the
   existing x87 decimal arithmetic and binary64 overflow/underflow checks. *)
module M = Machine_ir

(* edi = unsigned byte -> eax = boolean. The numeric token grammar accepts
   ASCII space, horizontal tab, LF and CR; vertical tab/form feed are invalid. *)
let emit_whitespace output =
  M.function_label output "__xen_numeric_whitespace";
  M.bytes output [0x31;0xc0]; (* xor    eax,eax *)
  M.bytes output [0x40;0x80;0xff;0x20]; (* cmp    dil,0x20 *)
  M.branch output [0x0f;0x87] "__xen_numeric_whitespace_return"; (* ja *)
  M.bytes output [0xb8;0x13;0x00;0x80;0x00]; (* mov    eax,0x800013 *)
  M.bytes output [0x48;0xc1;0xe0;0x09]; (* shl    rax,0x9 *)
  M.bytes output [0x48;0x0f;0xa3;0xf8]; (* bt     rax,rdi *)
  M.bytes output [0x0f;0x92;0xc0]; (* setb   al *)
  M.bytes output [0x0f;0xb6;0xc0]; (* movzx  eax,al *)
  M.label output "__xen_numeric_whitespace_return";
  M.ret output; (* ret *)
  ()

(* Optional sign and decimal digits, with an unsigned pre-multiply limit so
   the asymmetric signed minimum is accepted without signed overflow. *)
let emit_int output =
  M.function_label ~frame:12 output "__xen_numeric_parse_int";
  M.bytes output [0x49;0x89;0xfa]; (* mov    r10,rdi *)
  M.bytes output [0x49;0x89;0xf0]; (* mov    r8,rsi *)
  M.bytes output [0x49;0x89;0xd3]; (* mov    r11,rdx *)
  M.bytes output [0x48;0x85;0xf6]; (* test   rsi,rsi *)
  M.branch output [0x0f;0x8e] "__xen_int_empty"; (* jle *)
  M.bytes output [0x8a;0x07]; (* mov    al,BYTE PTR [rdi] *)
  M.bytes output [0x8d;0x50;0xd5]; (* lea    edx,[rax-0x2b] *)
  M.bytes output [0x80;0xe2;0xfd]; (* and    dl,0xfd *)
  M.branch output [0x0f;0x85] "__xen_int_unsigned"; (* jne *)
  M.bytes output [0x45;0x31;0xc9]; (* xor    r9d,r9d *)
  M.bytes output [0x3c;0x2d]; (* cmp    al,0x2d *)
  M.bytes output [0xbe;0x01;0x00;0x00;0x00]; (* mov    esi,0x1 *)
  M.bytes output [0x41;0x0f;0x94;0xc1]; (* sete   r9b *)
  M.branch output [0xe9] "__xen_int_require_digit"; (* jmp *)
  M.label output "__xen_int_empty";
  M.bytes output [0x45;0x31;0xc9]; (* xor    r9d,r9d *)
  M.bytes output [0x31;0xf6]; (* xor    esi,esi *)
  M.label output "__xen_int_require_digit";
  M.bytes output [0xb8;0x05;0x00;0x00;0x00]; (* mov    eax,0x5 *)
  M.bytes output [0x4c;0x39;0xc6]; (* cmp    rsi,r8 *)
  M.branch output [0x0f;0x85] "__xen_int_limit"; (* jne *)
  M.ret output; (* ret *)
  M.label output "__xen_int_unsigned";
  M.bytes output [0x45;0x31;0xc9]; (* xor    r9d,r9d *)
  M.bytes output [0x31;0xf6]; (* xor    esi,esi *)
  M.label output "__xen_int_limit";
  M.bytes output [0x48;0xb8;0xff;0xff;0xff;0xff;0xff;0xff;0xff;0x7f]; (* movabs rax,0x7fffffffffffffff *)
  M.bytes output [0x55]; (* push   rbp *)
  M.bytes output [0x31;0xc9]; (* xor    ecx,ecx *)
  M.bytes output [0xbd;0x0a;0x00;0x00;0x00]; (* mov    ebp,0xa *)
  M.bytes output [0x53]; (* push   rbx *)
  M.bytes output [0x49;0x63;0xd9]; (* movsxd rbx,r9d *)
  M.bytes output [0x48;0x01;0xc3]; (* add    rbx,rax *)
  M.label output "__xen_int_digit";
  M.bytes output [0x4c;0x39;0xc6]; (* cmp    rsi,r8 *)
  M.branch output [0x0f;0x8d] "__xen_int_sign"; (* jge *)
  M.bytes output [0x41;0x0f;0xb6;0x3c;0x32]; (* movzx  edi,BYTE PTR [r10+rsi*1] *)
  M.bytes output [0x83;0xef;0x30]; (* sub    edi,0x30 *)
  M.bytes output [0x83;0xff;0x09]; (* cmp    edi,0x9 *)
  M.branch output [0x0f;0x87] "__xen_int_invalid"; (* ja *)
  M.bytes output [0x48;0x63;0xff]; (* movsxd rdi,edi *)
  M.bytes output [0x48;0x89;0xd8]; (* mov    rax,rbx *)
  M.bytes output [0x31;0xd2]; (* xor    edx,edx *)
  M.bytes output [0x48;0x29;0xf8]; (* sub    rax,rdi *)
  M.bytes output [0x48;0xf7;0xf5]; (* div    rbp *)
  M.bytes output [0x48;0x39;0xc8]; (* cmp    rax,rcx *)
  M.branch output [0x0f;0x82] "__xen_int_range"; (* jb *)
  M.bytes output [0x48;0x6b;0xc9;0x0a]; (* imul   rcx,rcx,0xa *)
  M.bytes output [0x48;0xff;0xc6]; (* inc    rsi *)
  M.bytes output [0x48;0x01;0xf9]; (* add    rcx,rdi *)
  M.branch output [0xe9] "__xen_int_digit"; (* jmp *)
  M.label output "__xen_int_sign";
  M.bytes output [0x45;0x85;0xc9]; (* test   r9d,r9d *)
  M.branch output [0x0f;0x84] "__xen_int_store"; (* je *)
  M.bytes output [0x48;0xf7;0xd9]; (* neg    rcx *)
  M.label output "__xen_int_store";
  M.bytes output [0x49;0x89;0x0b]; (* mov    QWORD PTR [r11],rcx *)
  M.bytes output [0x31;0xc0]; (* xor    eax,eax *)
  M.branch output [0xe9] "__xen_int_return"; (* jmp *)
  M.label output "__xen_int_invalid";
  M.bytes output [0xb8;0x05;0x00;0x00;0x00]; (* mov    eax,0x5 *)
  M.branch output [0xe9] "__xen_int_return"; (* jmp *)
  M.label output "__xen_int_range";
  M.bytes output [0xb8;0x06;0x00;0x00;0x00]; (* mov    eax,0x6 *)
  M.label output "__xen_int_return";
  M.bytes output [0x5b]; (* pop    rbx *)
  M.bytes output [0x5d]; (* pop    rbp *)
  M.ret output; (* ret *)
  ()

(* Decimal significand, optional decimal point and signed exponent. Accumulate
   in x87 extended precision in the original order, then check the binary64
   result for infinity and nonzero decimal input rounded to zero. *)
let emit_float output =
  M.function_label ~frame:12 output "__xen_numeric_parse_float";
  M.bytes output [0x55]; (* push   rbp *)
  M.bytes output [0x48;0x89;0xf1]; (* mov    rcx,rsi *)
  M.bytes output [0x49;0x89;0xd1]; (* mov    r9,rdx *)
  M.bytes output [0x53]; (* push   rbx *)
  M.bytes output [0x48;0x83;0xec;0x10]; (* explicit scratch; no red zone *)
  M.bytes output [0x48;0x85;0xf6]; (* test   rsi,rsi *)
  M.branch output [0x0f;0x8e] "__xen_decimal_unsigned"; (* jle *)
  M.bytes output [0x8a;0x07]; (* mov    al,BYTE PTR [rdi] *)
  M.bytes output [0x8d;0x50;0xd5]; (* lea    edx,[rax-0x2b] *)
  M.bytes output [0x80;0xe2;0xfd]; (* and    dl,0xfd *)
  M.branch output [0x0f;0x85] "__xen_decimal_unsigned"; (* jne *)
  M.bytes output [0x45;0x31;0xc0]; (* xor    r8d,r8d *)
  M.bytes output [0x3c;0x2d]; (* cmp    al,0x2d *)
  M.bytes output [0xb8;0x01;0x00;0x00;0x00]; (* mov    eax,0x1 *)
  M.bytes output [0x41;0x0f;0x94;0xc0]; (* sete   r8b *)
  M.branch output [0xe9] "__xen_decimal_init"; (* jmp *)
  M.label output "__xen_decimal_unsigned";
  M.bytes output [0x45;0x31;0xc0]; (* xor    r8d,r8d *)
  M.bytes output [0x31;0xc0]; (* xor    eax,eax *)
  M.label output "__xen_decimal_init";
  M.bytes output [0xd9;0xee]; (* fldz *)
  M.bytes output [0x31;0xf6]; (* xor    esi,esi *)
  M.label output "__xen_decimal_integer";
  M.bytes output [0x48;0x39;0xc8]; (* cmp    rax,rcx *)
  M.branch output [0x0f;0x8d] "__xen_decimal_integer_end"; (* jge *)
  M.bytes output [0x0f;0xb6;0x14;0x07]; (* movzx  edx,BYTE PTR [rdi+rax*1] *)
  M.bytes output [0x44;0x8d;0x52;0xd0]; (* lea    r10d,[rdx-0x30] *)
  M.bytes output [0x41;0x80;0xfa;0x09]; (* cmp    r10b,0x9 *)
  M.branch output [0x0f;0x87] "__xen_decimal_point"; (* ja *)
  M.bytes output [0x83;0xea;0x30]; (* sub    edx,0x30 *)
  M.bytes output [0xd8;0x0d]; (* fmul   DWORD PTR [decimal_ten] *)
  M.rip_rel32 output M.Rodata "__xen_decimal_ten";
  M.bytes output [0x48;0xff;0xc0]; (* inc    rax *)
  M.bytes output [0xbe;0x01;0x00;0x00;0x00]; (* mov    esi,0x1 *)
  M.bytes output [0x89;0x14;0x24]; (* mov    DWORD PTR [rsp],edx *)
  M.bytes output [0xda;0x04;0x24]; (* fiadd  DWORD PTR [rsp] *)
  M.branch output [0xe9] "__xen_decimal_integer"; (* jmp *)
  M.label output "__xen_decimal_point";
  M.bytes output [0x80;0xfa;0x2e]; (* cmp    dl,0x2e *)
  M.branch output [0x0f;0x85] "__xen_decimal_no_point"; (* jne *)
  M.bytes output [0x48;0xff;0xc0]; (* inc    rax *)
  M.bytes output [0x45;0x31;0xd2]; (* xor    r10d,r10d *)
  M.label output "__xen_decimal_fraction";
  M.bytes output [0x48;0x39;0xc8]; (* cmp    rax,rcx *)
  M.branch output [0x0f;0x84] "__xen_decimal_require_digit"; (* je *)
  M.bytes output [0x0f;0xb6;0x14;0x07]; (* movzx  edx,BYTE PTR [rdi+rax*1] *)
  M.bytes output [0x44;0x8d;0x5a;0xd0]; (* lea    r11d,[rdx-0x30] *)
  M.bytes output [0x41;0x80;0xfb;0x09]; (* cmp    r11b,0x9 *)
  M.branch output [0x0f;0x87] "__xen_decimal_require_digit"; (* ja *)
  M.bytes output [0x83;0xea;0x30]; (* sub    edx,0x30 *)
  M.bytes output [0xd8;0x0d]; (* fmul   DWORD PTR [decimal_ten] *)
  M.rip_rel32 output M.Rodata "__xen_decimal_ten";
  M.bytes output [0x48;0xff;0xc0]; (* inc    rax *)
  M.bytes output [0x41;0xff;0xc2]; (* inc    r10d *)
  M.bytes output [0x89;0x14;0x24]; (* mov    DWORD PTR [rsp],edx *)
  M.bytes output [0xbe;0x01;0x00;0x00;0x00]; (* mov    esi,0x1 *)
  M.bytes output [0xda;0x04;0x24]; (* fiadd  DWORD PTR [rsp] *)
  M.branch output [0xe9] "__xen_decimal_fraction"; (* jmp *)
  M.label output "__xen_decimal_require_digit";
  M.bytes output [0xba;0x05;0x00;0x00;0x00]; (* mov    edx,0x5 *)
  M.bytes output [0x85;0xf6]; (* test   esi,esi *)
  M.branch output [0x0f;0x84] "__xen_decimal_no_digits"; (* je *)
  M.bytes output [0x48;0x39;0xc8]; (* cmp    rax,rcx *)
  M.branch output [0x0f;0x8d] "__xen_decimal_plain_end"; (* jge *)
  M.label output "__xen_decimal_exponent";
  M.bytes output [0x40;0x8a;0x34;0x07]; (* mov    sil,BYTE PTR [rdi+rax*1] *)
  M.bytes output [0xba;0x05;0x00;0x00;0x00]; (* mov    edx,0x5 *)
  M.bytes output [0x83;0xe6;0xdf]; (* and    esi,0xffffffdf *)
  M.bytes output [0x40;0x80;0xfe;0x45]; (* cmp    sil,0x45 *)
  M.branch output [0x0f;0x85] "__xen_decimal_bad_exponent"; (* jne *)
  M.bytes output [0x4c;0x8d;0x58;0x01]; (* lea    r11,[rax+0x1] *)
  M.bytes output [0x31;0xdb]; (* xor    ebx,ebx *)
  M.bytes output [0x4c;0x39;0xd9]; (* cmp    rcx,r11 *)
  M.branch output [0x0f;0x8e] "__xen_decimal_exponent_init"; (* jle *)
  M.bytes output [0x8a;0x54;0x07;0x01]; (* mov    dl,BYTE PTR [rdi+rax*1+0x1] *)
  M.bytes output [0x8d;0x72;0xd5]; (* lea    esi,[rdx-0x2b] *)
  M.bytes output [0x40;0x80;0xe6;0xfd]; (* and    sil,0xfd *)
  M.branch output [0x0f;0x85] "__xen_decimal_exponent_init"; (* jne *)
  M.bytes output [0x31;0xdb]; (* xor    ebx,ebx *)
  M.bytes output [0x80;0xfa;0x2d]; (* cmp    dl,0x2d *)
  M.bytes output [0x4c;0x8d;0x58;0x02]; (* lea    r11,[rax+0x2] *)
  M.bytes output [0x0f;0x94;0xc3]; (* sete   bl *)
  M.label output "__xen_decimal_exponent_init";
  M.bytes output [0x4c;0x89;0xde]; (* mov    rsi,r11 *)
  M.bytes output [0x31;0xc0]; (* xor    eax,eax *)
  M.label output "__xen_decimal_exponent_scan";
  M.bytes output [0x48;0x39;0xce]; (* cmp    rsi,rcx *)
  M.branch output [0x0f;0x8c] "__xen_decimal_exponent_digit"; (* jl *)
  M.bytes output [0xba;0x05;0x00;0x00;0x00]; (* mov    edx,0x5 *)
  M.bytes output [0x49;0x39;0xf3]; (* cmp    r11,rsi *)
  M.branch output [0x0f;0x85] "__xen_decimal_exponent_end"; (* jne *)
  M.bytes output [0xdd;0xd8]; (* fstp   st(0) *)
  M.branch output [0xe9] "__xen_decimal_return"; (* jmp *)
  M.label output "__xen_decimal_exponent_digit";
  M.bytes output [0x0f;0xb6;0x14;0x37]; (* movzx  edx,BYTE PTR [rdi+rsi*1] *)
  M.bytes output [0x8d;0x6a;0xd0]; (* lea    ebp,[rdx-0x30] *)
  M.bytes output [0x40;0x80;0xfd;0x09]; (* cmp    bpl,0x9 *)
  M.branch output [0x0f;0x87] "__xen_decimal_exponent_invalid"; (* ja *)
  M.bytes output [0x3d;0x0f;0x27;0x00;0x00]; (* cmp    eax,0x270f *)
  M.branch output [0x0f;0x8f] "__xen_decimal_exponent_next"; (* jg *)
  M.bytes output [0x6b;0xc0;0x0a]; (* imul   eax,eax,0xa *)
  M.bytes output [0x8d;0x44;0x10;0xd0]; (* lea    eax,[rax+rdx*1-0x30] *)
  M.label output "__xen_decimal_exponent_next";
  M.bytes output [0x48;0xff;0xc6]; (* inc    rsi *)
  M.branch output [0xe9] "__xen_decimal_exponent_scan"; (* jmp *)
  M.label output "__xen_decimal_exponent_invalid";
  M.bytes output [0xdd;0xd8]; (* fstp   st(0) *)
  M.bytes output [0xba;0x05;0x00;0x00;0x00]; (* mov    edx,0x5 *)
  M.branch output [0xe9] "__xen_decimal_return"; (* jmp *)
  M.label output "__xen_decimal_exponent_end";
  M.bytes output [0xba;0x05;0x00;0x00;0x00]; (* mov    edx,0x5 *)
  M.bytes output [0x48;0x39;0xce]; (* cmp    rsi,rcx *)
  M.branch output [0x0f;0x85] "__xen_decimal_trailing"; (* jne *)
  M.bytes output [0x85;0xdb]; (* test   ebx,ebx *)
  M.branch output [0x0f;0x84] "__xen_decimal_scale"; (* je *)
  M.bytes output [0xf7;0xd8]; (* neg    eax *)
  M.label output "__xen_decimal_scale";
  M.bytes output [0x44;0x29;0xd0]; (* sub    eax,r10d *)
  M.bytes output [0xba;0x06;0x00;0x00;0x00]; (* mov    edx,0x6 *)
  M.bytes output [0x8d;0xb0;0x10;0x27;0x00;0x00]; (* lea    esi,[rax+0x2710] *)
  M.bytes output [0x81;0xfe;0x20;0x4e;0x00;0x00]; (* cmp    esi,0x4e20 *)
  M.branch output [0x0f;0x87] "__xen_decimal_scale_range"; (* ja *)
  M.bytes output [0x89;0xc2]; (* mov    edx,eax *)
  M.label output "__xen_decimal_multiply";
  M.bytes output [0x85;0xd2]; (* test   edx,edx *)
  M.branch output [0x0f;0x8e] "__xen_decimal_divide_init"; (* jle *)
  M.bytes output [0xd8;0x0d]; (* fmul   DWORD PTR [decimal_ten] *)
  M.rip_rel32 output M.Rodata "__xen_decimal_ten";
  M.bytes output [0xff;0xca]; (* dec    edx *)
  M.branch output [0xe9] "__xen_decimal_multiply"; (* jmp *)
  M.label output "__xen_decimal_divide_init";
  M.bytes output [0x31;0xf6]; (* xor    esi,esi *)
  M.bytes output [0x85;0xc0]; (* test   eax,eax *)
  M.bytes output [0x0f;0x49;0xf0]; (* cmovns esi,eax *)
  M.bytes output [0x29;0xf0]; (* sub    eax,esi *)
  M.bytes output [0x89;0xc2]; (* mov    edx,eax *)
  M.label output "__xen_decimal_divide";
  M.bytes output [0x85;0xd2]; (* test   edx,edx *)
  M.branch output [0x0f;0x84] "__xen_decimal_sign"; (* je *)
  M.bytes output [0xd8;0x35]; (* fdiv   DWORD PTR [decimal_ten] *)
  M.rip_rel32 output M.Rodata "__xen_decimal_ten";
  M.bytes output [0xff;0xc2]; (* inc    edx *)
  M.branch output [0xe9] "__xen_decimal_divide"; (* jmp *)
  M.label output "__xen_decimal_sign";
  M.bytes output [0x45;0x85;0xc0]; (* test   r8d,r8d *)
  M.branch output [0x0f;0x84] "__xen_decimal_binary64"; (* je *)
  M.bytes output [0xd9;0xe0]; (* fchs *)
  M.label output "__xen_decimal_binary64";
  M.bytes output [0xdd;0x1c;0x24]; (* fstp   QWORD PTR [rsp] *)
  M.bytes output [0xf2;0x0f;0x10;0x04;0x24]; (* movsd  xmm0,QWORD PTR [rsp] *)
  M.bytes output [0xb8;0xff;0x07;0x00;0x00]; (* mov    eax,0x7ff *)
  M.bytes output [0x48;0xc1;0xe0;0x34]; (* shl    rax,0x34 *)
  M.bytes output [0x66;0x48;0x0f;0x7e;0xc6]; (* movq   rsi,xmm0 *)
  M.bytes output [0x49;0x89;0xf0]; (* mov    r8,rsi *)
  M.bytes output [0x49;0xf7;0xd0]; (* not    r8 *)
  M.bytes output [0x49;0x85;0xc0]; (* test   r8,rax *)
  M.branch output [0x0f;0x84] "__xen_decimal_range"; (* je *)
  M.bytes output [0x45;0x31;0xc0]; (* xor    r8d,r8d *)
  M.bytes output [0x31;0xc0]; (* xor    eax,eax *)
  M.bytes output [0x41;0xbb;0x01;0x00;0x00;0x00]; (* mov    r11d,0x1 *)
  M.label output "__xen_decimal_nonzero_scan";
  M.bytes output [0x48;0x39;0xc8]; (* cmp    rax,rcx *)
  M.branch output [0x0f;0x8d] "__xen_decimal_underflow"; (* jge *)
  M.bytes output [0x8a;0x1c;0x07]; (* mov    bl,BYTE PTR [rdi+rax*1] *)
  M.bytes output [0x44;0x8d;0x53;0xcf]; (* lea    r10d,[rbx-0x31] *)
  M.bytes output [0x41;0x80;0xfa;0x08]; (* cmp    r10b,0x8 *)
  M.bytes output [0x45;0x0f;0x46;0xc3]; (* cmovbe r8d,r11d *)
  M.bytes output [0x48;0xff;0xc0]; (* inc    rax *)
  M.branch output [0xe9] "__xen_decimal_nonzero_scan"; (* jmp *)
  M.label output "__xen_decimal_underflow";
  M.bytes output [0x45;0x85;0xc0]; (* test   r8d,r8d *)
  M.branch output [0x0f;0x84] "__xen_decimal_store"; (* je *)
  M.bytes output [0x48;0x01;0xf6]; (* add    rsi,rsi *)
  M.branch output [0x0f;0x84] "__xen_decimal_range"; (* je *)
  M.label output "__xen_decimal_store";
  M.bytes output [0xf2;0x41;0x0f;0x11;0x01]; (* movsd  QWORD PTR [r9],xmm0 *)
  M.branch output [0xe9] "__xen_decimal_return"; (* jmp *)
  M.label output "__xen_decimal_range";
  M.bytes output [0xba;0x06;0x00;0x00;0x00]; (* mov    edx,0x6 *)
  M.branch output [0xe9] "__xen_decimal_return"; (* jmp *)
  M.label output "__xen_decimal_integer_end";
  M.bytes output [0xba;0x05;0x00;0x00;0x00]; (* mov    edx,0x5 *)
  M.bytes output [0x45;0x31;0xd2]; (* xor    r10d,r10d *)
  M.bytes output [0x85;0xf6]; (* test   esi,esi *)
  M.branch output [0x0f;0x84] "__xen_decimal_empty"; (* je *)
  M.label output "__xen_decimal_plain_end";
  M.bytes output [0xba;0x05;0x00;0x00;0x00]; (* mov    edx,0x5 *)
  M.bytes output [0x48;0x39;0xc1]; (* cmp    rcx,rax *)
  M.branch output [0x0f;0x85] "__xen_decimal_invalid"; (* jne *)
  M.bytes output [0x31;0xc0]; (* xor    eax,eax *)
  M.branch output [0xe9] "__xen_decimal_scale"; (* jmp *)
  M.label output "__xen_decimal_no_point";
  M.bytes output [0xba;0x05;0x00;0x00;0x00]; (* mov    edx,0x5 *)
  M.bytes output [0x45;0x31;0xd2]; (* xor    r10d,r10d *)
  M.bytes output [0x85;0xf6]; (* test   esi,esi *)
  M.branch output [0x0f;0x85] "__xen_decimal_exponent"; (* jne *)
  M.bytes output [0xdd;0xd8]; (* fstp   st(0) *)
  M.branch output [0xe9] "__xen_decimal_return"; (* jmp *)
  M.label output "__xen_decimal_no_digits";
  M.bytes output [0xdd;0xd8]; (* fstp   st(0) *)
  M.branch output [0xe9] "__xen_decimal_return"; (* jmp *)
  M.label output "__xen_decimal_bad_exponent";
  M.bytes output [0xdd;0xd8]; (* fstp   st(0) *)
  M.branch output [0xe9] "__xen_decimal_return"; (* jmp *)
  M.label output "__xen_decimal_trailing";
  M.bytes output [0xdd;0xd8]; (* fstp   st(0) *)
  M.branch output [0xe9] "__xen_decimal_return"; (* jmp *)
  M.label output "__xen_decimal_scale_range";
  M.bytes output [0xdd;0xd8]; (* fstp   st(0) *)
  M.branch output [0xe9] "__xen_decimal_return"; (* jmp *)
  M.label output "__xen_decimal_empty";
  M.bytes output [0xdd;0xd8]; (* fstp   st(0) *)
  M.branch output [0xe9] "__xen_decimal_return"; (* jmp *)
  M.label output "__xen_decimal_invalid";
  M.bytes output [0xdd;0xd8]; (* fstp   st(0) *)
  M.label output "__xen_decimal_return";
  M.bytes output [0x89;0xd0]; (* mov    eax,edx *)
  M.bytes output [0x48;0x83;0xc4;0x10];
  M.bytes output [0x5b]; (* pop    rbx *)
  M.bytes output [0x5d]; (* pop    rbp *)
  M.ret output; (* ret *)
  ()

let emit output =
  M.add_rodata output "__xen_decimal_ten" "\000\000\032\065";
  emit_whitespace output;emit_int output;emit_float output
