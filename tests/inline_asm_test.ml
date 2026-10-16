(* SPDX-License-Identifier: MIT OR Apache-2.0 *)
open Ast
let spec template input_registers output_register clobbers =
  {template;input_registers;output_registers=Option.to_list output_register;output_types=List.map(fun _->I64)(Option.to_list output_register);clobbers;volatile=true;memory=Unknown_memory}
let hex text=String.concat ""(List.init(String.length text)(fun i->Printf.sprintf "%02x"(Char.code text.[i])))
let check name expected actual=if hex actual<>expected then failwith(name^" encoding mismatch: "^hex actual)
let rejected name assemble s =
  match assemble s with _->failwith("accepted "^name)|exception Asm_contract.Error _->()
let () =
  (* Independent GNU as reference bytes; no assembler is needed to run tests. *)
  check "x86-64"
    "4989c04901c84d29c84d89c24d31da4d21c24d09ca4d0fafc24d8b014d891a90f3900faef00faee80faef8"
    (Xen_x86_64.Inline_asm.assemble(spec
      "mov r8, rax; add r8, rcx; sub r8, r9; mov r10, r8; xor r10, r11; and r10, r8; or r10, r9; imul r8, r10; mov r8, [r9]; mov [r10], r11; nop; pause; mfence; lfence; sfence"
      ["rax";"rcx";"r9";"r11"](Some("r8",false))["r10"]));
  check "rdtsc" "0f31"
    (Xen_x86_64.Inline_asm.assemble(spec "rdtsc"[](Some("rax",false))["rdx"]));
  rejected "implicit rdtsc clobber" Xen_x86_64.Inline_asm.assemble(spec "rdtsc"[](Some("rax",false))[]);
  check "AArch64"
    "e80300aa0801018b080102cb0a0103ca4a01048a4a0105aa087d0a9b280140f94b0100f91f2003d53f2003d5bf3f03d5bf3b03d5"
    (Xen_arm64.Inline_asm.assemble(spec
      "mov x8, x0; add x8, x8, x1; sub x8, x8, x2; eor x10, x8, x3; and x10, x10, x4; orr x10, x10, x5; mul x8, x8, x10; ldr x8, [x9]; str x11, [x10]; nop; yield; dmb sy; dmb ish"
      ["x0";"x1";"x2";"x3";"x4";"x5";"x9";"x11"](Some("x8",false))["x10"]));
  check "asm whitespace" "90f390"
    (Xen_x86_64.Inline_asm.assemble(spec "nop\r\n\tpause"[]None[]));
  check "x86-64 phase two"
    "4d89c14d89c24d89c34c89c04981c0ffffff7f4981e9000000804981f27fffffff4981e3800000004981c8ffffff7f4d69c97fffffff49c1e00049c1e93f49c1fa3f49d3e348d3e849d3f849f7d949f7d2490fcb480fc84d8b82800000004d898b7fffffff488b82ffffff7f4c8986000000804c8b024c8906"
    (Xen_x86_64.Inline_asm.assemble(spec
      "mov r9, r8; mov r10, r8; mov r11, r8; mov rax, r8; add r8, 2147483647; sub r9, -2147483648; xor r10, -129; and r11, 128; or r8, 2147483647; imul r9, -129; shl r8, 0; shr r9, 63; sar r10, 63; shl r11, cl; shr rax, cl; sar r8, cl; neg r9; not r10; bswap r11; bswap rax; mov r8, [r10 + 128]; mov [r11 - 129], r9; mov rax, [rdx + 2147483647]; mov [rsi - 2147483648], r8; mov r8, [rdx + 0]; mov [rsi - 0], r8"
      ["r8";"rcx";"rdx";"rsi"](Some("r8",true))["r9";"r10";"r11";"rax"]));
  check "AArch64 phase two"
    "cefd3f91080000d109fd3fd1cefd40d3080041d309fc40d30afc7fd30bfc7f93c821c29ac925c29aca29c29aee030ecbe80320aac90dc0da28fc7ff92e0400f92a0040f9280050f82ef00ff8291040f8"
    (Xen_arm64.Inline_asm.assemble(spec
      "add x14, x14, #4095; sub x8, x0, #0; sub x9, x8, #4095; lsl x14, x14, #0; lsl x8, x0, #63; lsr x9, x0, #0; lsr x10, x0, #63; asr x11, x0, #63; lsl x8, x14, x2; lsr x9, x14, x2; asr x10, x14, x2; neg x14, x14; mvn x8, x0; rev x9, x14; ldr x8, [x1, #32760]; str x14, [x1, #8]; ldr x10, [x1, #0]; ldur x8, [x1, #-256]; stur x14, [x1, #255]; ldur x9, [x1, #1]"
      ["x0";"x1";"x2";"x14"](Some("x14",true))["x8";"x9";"x10";"x11"]));
  check "x86-64 scalar operands and condition outputs"
    "4188c0664189c94189d24100c8664129d14131f24120f8664109f166440fafca440fafd641c0e0076641c1e90f41c1fa1f41d2e041f6d86641f7d1410fca448a87800000004488878000000066448b8f800000006644898f80000000448b978000000044899780000000450fb6d84d0fbfd94d63da440fb69f800000004c0fbf9f800000004c639f800000004138c8410f94c34185f20f95c0664139d1410f9cc3"
    (Xen_x86_64.Inline_asm.assemble { (spec
      "mov r8b, al; mov r9w, cx; mov r10d, edx; add r8b, cl; sub r9w, dx; xor r10d, esi; and r8b, dil; or r9w, si; imul r9w, dx; imul r10d, esi; shl r8b, 7; shr r9w, 15; sar r10d, 31; shl r8b, cl; neg r8b; not r9w; bswap r10d; mov r8b, [rdi+128]; mov [rdi+128], r8b; mov r9w, [rdi+128]; mov [rdi+128], r9w; mov r10d, [rdi+128]; mov [rdi+128], r10d; movzx r11d, r8b; movsx r11, r9w; movsxd r11, r10d; movzx r11d, byte [rdi+128]; movsx r11, word [rdi+128]; movsxd r11, dword [rdi+128]; cmp r8b, cl; sete r11b; test r10d, esi; setne al; cmp r9w, dx; setl r11b"
      ["rax";"rcx";"rdx";"rsi";"rdi"](Some("rax",true))["r8";"r9";"r10"]) with
      output_registers=["rax",true;"r11b",false];output_types=[I64;U8] });
  check "AArch64 scalar operands and condition outputs"
    "e803002a0801010b0901024b2a7d031b4b01040a6c01052a8d01064a08fd3f1129fd3f5108010153297d1f534a7d1f136b21c11a8c25c21aad29c31ae803084be903292a4a09c05ac8fd3f39c9fd7f39cafd3f79cbfd7f79ccfd3fb9cdfd7fb9c8011038c9f14f38ca011078cbf14f78cc0110b8cdf14fb8081d4093293d00134a7d40936b1d00538c3d00531f01096beda79f1a5f010b6ae8079f9a2901012bec379f1a4a050071eb179f1a"
    (Xen_arm64.Inline_asm.assemble { (spec
      "mov w8,w0; add w8,w8,w1; sub w9,w8,w2; mul w10,w9,w3; and w11,w10,w4; orr w12,w11,w5; eor w13,w12,w6; add w8,w8,#4095; sub w9,w9,#4095; lsl w8,w8,#31; lsr w9,w9,#31; asr w10,w10,#31; lsl w11,w11,w1; lsr w12,w12,w2; asr w13,w13,w3; neg w8,w8; mvn w9,w9; rev w10,w10; strb w8,[x14,#4095]; ldrb w9,[x14,#4095]; strh w10,[x14,#8190]; ldrh w11,[x14,#8190]; str w12,[x14,#16380]; ldr w13,[x14,#16380]; sturb w8,[x14,#-256]; ldurb w9,[x14,#255]; sturh w10,[x14,#-256]; ldurh w11,[x14,#255]; stur w12,[x14,#-256]; ldur w13,[x14,#255]; sxtb x8,w8; sxth w9,w9; sxtw x10,w10; uxtb w11,w11; uxth w12,w12; cmp w8,w9; cset w13,lt; tst w10,w11; cset x8,ne; adds w9,w9,w1; cset w12,cs; subs w10,w10,#1; cset w11,eq"
      ["x0";"x1";"x2";"x3";"x4";"x5";"x6";"x14"]None["x8";"x9";"x10";"x11";"x12"]) with
      output_registers=["w13",false];output_types=[U32] });
  List.iter(fun template->rejected template Xen_x86_64.Inline_asm.assemble
    (spec template ["r8"](Some("r8",true))[]))[
      "add r8, 2147483648";"imul r8, -2147483649";
      "shl r8, 64";"shr r8, -1";"sar r8, cl";
      "mov r8, [r8 + 2147483648]";"mov r8, [r8 - 2147483649]";
      "mov r8, [r8 + -0]";"mov r8, [r8 + r8]";
      "mov r8, [r8";"mov r8, [[r8]]";"mov r8, r8]";
      "mov r8, ";"mov r8,,r8"];
  List.iter(fun template->rejected template Xen_arm64.Inline_asm.assemble
    (spec template ["x14"](Some("x14",true))[]))[
      "add x14, x14, #4096";"sub x14, x14, #-1";
      "lsl x14, x14, #64";"asr x14, x14, #-1";
      "ldr x14, [x14, #32768]";"str x14, [x14, #1]";
      "ldur x14, [x14, #-257]";"stur x14, [x14, #256]";
      "ldr x14, [x14, #8]!";"ldr x14, [x14], #8";
      "ldr x14, [x14, ]";"ldr x14, [[x14]]";"ldr x14, [x14, #8"];
  check "x86-64 stack, extended registers and cpuid"
    "4881ec800000004c8904244c8b0c244488842480000000440fb69424800000004c0fbf9c247fffffff486304244c8da424800000004d89b5000000004d8b3c244881c480000000415754415e415f0fa2"
    (Xen_x86_64.Inline_asm.assemble { (spec
      "sub rsp,128; mov [rsp],r8; mov r9,[rsp]; mov [rsp+128],r8b; movzx r10d,byte [rsp+128]; movsx r11,word [rsp-129]; movsxd rax,dword [rsp]; lea r12,[rsp+128]; mov [r13],r14; mov r15,[r12]; add rsp,128; push r15; push rsp; pop r14; pop r15; cpuid"
      ["rax";"rcx";"r8";"r13";"r14"]None["r9";"r10";"r11";"r12";"r15";"rbx";"rdx"]) with
      output_registers=["rax",true;"rcx",true;"r14",true];output_types=[I64;I64;I64] });
  check "AArch64 stack, extended registers and system reads"
    "ff4300d1ff8300d1f1030091f30300f9f40340f9f5030239f6034239f7f31778f8f35778ff830091ff43009159e03bd51ae03bd55bd03bd5"
    (Xen_arm64.Inline_asm.assemble(spec
      "sub sp,sp,#16; sub sp,sp,#32; mov x17,sp; str x19,[sp]; ldr x20,[sp]; strb w21,[sp,#128]; ldrb w22,[sp,#128]; sturh w23,[sp,#-129]; ldurh w24,[sp,#-129]; add sp,sp,#32; add sp,sp,#16; mrs x25,cntvct_el0; mrs x26,cntfrq_el0; mrs x27,tpidr_el0"
      ["x19";"w21";"w23"]None["x17";"x20";"x22";"x24";"x25";"x26";"x27"]));
  List.iter(fun template->rejected template Xen_x86_64.Inline_asm.assemble
    (spec template ["r8"](Some("r8",true))[]))[
      "sub rsp,16";"add rsp,16;sub rsp,16";"push r8";"pop r8;push r8";
      "sub rsp,8;add rsp,16";"mov rsp,r8";"mov esp,16";"and rsp,-16";
      "sub rsp,r8";"sub rsp,-16";"push r8d;pop r8d";"push r8;pop rsp";
      "lea rsp,[r8]";"lea r8,qword [rsp]";"lea r8d,[rsp]";
      "cmp r8,0;sub rsp,16;add rsp,16;sete r8b";
      "cpuid"];
  List.iter(fun template->rejected template Xen_arm64.Inline_asm.assemble
    (spec template ["x14"](Some("x14",true))[]))[
      "sub sp,sp,#16";"add sp,sp,#16;sub sp,sp,#16";
      "sub sp,sp,#8;add sp,sp,#8";"sub sp,sp,#16;add sp,sp,#32";
      "sub sp,sp,x14";"sub sp,x14,#16";"subs sp,sp,#16";
      "mov sp,x14";"mov w14,sp";"add x14,sp,#16";
      "ldr sp,[x14]";"ldr x14,[wsp]";"mrs x14,sctlr_el1";"mrs w14,cntvct_el0"];
  List.iter(fun r->rejected ("constraint "^r) Xen_x86_64.Inline_asm.assemble
    (spec "nop"[r]None[]))["rsp";"esp";"rbp"];
  List.iter(fun r->rejected ("constraint "^r) Xen_arm64.Inline_asm.assemble
    (spec "nop"[r]None[]))["sp";"wsp";"x15";"x16";"x18";"x29";"x30"];
  print_endline "Inline asm encodings and implicit clobber checks passed"
