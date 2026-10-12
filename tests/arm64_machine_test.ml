(* SPDX-License-Identifier: MIT OR Apache-2.0 *)
module M = Xen_arm64.Machine_ir
let expect yes message = if not yes then failwith message
let word bytes at =
  let value=ref 0 in for i=0 to 3 do value:= !value lor (Char.code(Bytes.get bytes(at+i)) lsl (8*i))done;!value
let rejects f = try f();false with M.Error _->true
let () =
  let m=M.create()in
  M.imm m 0 0x123456789abcdef0L;M.mov m 3 4;
  M.add m 1 2 3;M.sub m 1 2 3;M.mul m 1 2 3;M.cmp m 2 3;M.cset m 0 11;
  M.rr m 0x8b206000 31 31 16;M.rr m 0xcb000000 9 29 16;
  M.load m ~bytes:1 ~signed:true 0 15 0;M.load m ~bytes:2 ~signed:true 1 15 2;
  M.load m ~bytes:4 ~signed:true 2 15 4;M.load m 3 31 8;
  M.store m ~bytes:1 0 15 0;M.store m ~bytes:2 1 15 2;
  M.store m ~bytes:4 2 15 4;M.store m 3 31 8;
  M.rr m 0x9ac00800 2 0 1;M.rr m 0x9ac00c00 2 0 1;
  List.iter(M.word m)[0xa9bf7bfd;0x910003fd;0x910003bf;0xa8c17bfd;0xd63f0220];
  M.syscall m;M.ret m;
  (* Independently assembled with GNU aarch64-linux-gnu-as; see the instruction
     meanings in machine_ir.ml and linux_runtime.ml. No assembler needed here. *)
  let expected=[0xd29bde00;0xf2b35780;0xf2cacf00;0xf2e24680;0xaa0403e3;
    0x8b030041;0xcb030041;0x9b037c41;0xeb03005f;0x9a9fa7e0;0x8b3063ff;0xcb1003a9;
    0x398001e0;0x798005e1;0xb98005e2;0xf94007e3;0x390001e0;0x790005e1;
    0xb90005e2;0xf90007e3;0x9ac10802;0x9ac10c02;0xa9bf7bfd;0x910003fd;
    0x910003bf;0xa8c17bfd;0xd63f0220;0xd4000001;0xd65f03c0]in
  let bytes=M.encode m ~code_address:0L ~rodata_address:0L ~data_address:0L in
  List.iteri(fun i n->expect(word bytes(i*4)=n)("encoding mismatch at "^string_of_int i))expected;
  expect(M.branch_bits(-134217728)=0x2000000)"negative branch boundary";
  let product=M.create() in M.multiply_high product 9 1 2;
  let encoded=M.encode product ~code_address:0L ~rodata_address:0L ~data_address:0L in
  expect(word encoded 0=0x9bc27c29) "UMULH encoding mismatch (fixtures/arm64_heap.s)";
  expect(M.branch_bits 134217724=0x1ffffff)"positive branch boundary";
  List.iter(fun n->expect(rejects(fun()->ignore(M.branch_bits n)))"unchecked branch overflow")
    [-134217732;134217728;2];
  expect(rejects(fun()->M.load m 0 1 32768))"unchecked memory offset";
  let m=M.create()in M.label m "back";M.branch m "forward";M.branch m ~link:true "back";
  M.label m "forward";M.cond m 0 "back";
  let data=M.constant m "data"in M.address m 7 data;
  let bytes=M.encode m ~code_address:0x410000L ~rodata_address:0x420000L ~data_address:0x430000L in
  expect(word bytes 0=0x14000002 && word bytes 4=0x97ffffff)"branch relocation";
  expect(word bytes 8=0x54000041 && word bytes 12=0x17fffffd)"long conditional branch";
  expect(word bytes 16=0xd2800007 && word bytes 20=0xf2a00847)"address relocation";
  let pie=M.encode ~position_independent:true m
    ~code_address:0x100041000L ~rodata_address:0x100042008L ~data_address:0x100043000L in
  let slid=M.encode ~position_independent:true m
    ~code_address:0x124041000L ~rodata_address:0x124042008L ~data_address:0x124043000L in
  expect(pie=slid)"PIE code changed under a common ASLR slide";
  (* ADRP x7,+4096; ADD x7,x7,#8; two NOPs, independently assembled. *)
  expect(word pie 16=0xb0000007 && word pie 20=0x910020e7 &&
    word pie 24=0xd503201f && word pie 28=0xd503201f)"PIE address relocation";
  expect(rejects(fun()->ignore(M.encode ~position_independent:true m
    ~code_address:0x100000000L ~rodata_address:0x200000000L ~data_address:0x100000000L)))
    "unchecked positive ADRP overflow";
  expect(rejects(fun()->ignore(M.encode ~position_independent:true m
    ~code_address:0x200001000L ~rodata_address:0x100000000L ~data_address:0x100000000L)))
    "unchecked negative ADRP overflow";
  M.branch m "missing";
  expect(rejects(fun()->ignore(M.encode m ~code_address:0L ~rodata_address:0L ~data_address:0L)))"undefined label";
  (* Independent assembly is retained in fixtures/arm64_fp.s. *)
  let m=M.create()in
  M.fp_from_bits m ~single:true 0 3;M.fp_from_bits m ~single:false 1 4;
  M.fp_to_bits m ~single:true 5 2;M.fp_to_bits m ~single:false 6 3;
  M.fp_neg m ~single:true 0 1;M.fp_neg m ~single:false 2 3;
  List.iter(fun op->M.fp_binary m ~single:true op 0 1 2)["+";"-";"*";"/"];
  List.iter(fun op->M.fp_binary m ~single:false op 3 4 5)["+";"-";"*";"/"];
  M.fp_cmp m ~single:true 1 2;M.fp_cmp m ~single:false 3 4;
  M.fp_convert m ~single:true 0 1;M.fp_convert m ~single:false 2 3;
  M.fp_of_int m ~single:true ~unsigned:false 0 1;
  M.fp_of_int m ~single:true ~unsigned:true 2 3;
  M.fp_of_int m ~single:false ~unsigned:false 4 5;
  M.fp_of_int m ~single:false ~unsigned:true 6 7;
  M.fp_to_int m ~single:true ~unsigned:false 0 1;
  M.fp_to_int m ~single:true ~unsigned:true 2 3;
  M.fp_to_int m ~single:false ~unsigned:false 4 5;
  M.fp_to_int m ~single:false ~unsigned:true 6 7;
  M.shift_right m 0 1 52;M.bit_and m 2 3 4;M.bit_or m 5 6 7;
  let expected=[0x1e270060;0x9e670081;0x1e260045;0x9e660066;0x1e214020;0x1e614062;
    0x1e222820;0x1e223820;0x1e220820;0x1e221820;0x1e652883;0x1e653883;0x1e650883;0x1e651883;
    0x1e222020;0x1e642060;0x1e624020;0x1e22c062;0x9e220020;0x9e230062;0x9e6200a4;0x9e6300e6;
    0x9e380020;0x9e390062;0x9e7800a4;0x9e7900e6;0xd374fc20;0x8a040062;0xaa0700c5]in
  let bytes=M.encode m ~code_address:0L ~rodata_address:0L ~data_address:0L in
  List.iteri(fun i n->expect(word bytes(i*4)=n)("FP encoding mismatch at "^string_of_int i))expected;
  print_endline "ARM64 encodings, relocations and range checks passed"
