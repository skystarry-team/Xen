(* SPDX-License-Identifier: Apache-2.0 *)
(* Generated runtime code carries the additional MIT OR Apache-2.0 permission
   specified in the root LICENSE. Exact binary64 -> decimal, rounded to 17
   significant digits (nearest, ties to even). No host formatter or libc.

   For value = mantissa * 2^power, form an exact decimal integer by multiplying
   by 2^power, or by 5^-power with decimal scale -power. The worst case is 767
   digits; 800 bytes includes carry room. Digits are little-endian, one per byte.
   This intentionally favors a small, auditable runtime over conversion speed.
   x0..x17 and v0..v2 are scratch; SP remains aligned, x18..x29 are untouched. *)
module M = Machine_ir
let emit m =
  let label name = "float_"^name in
  let mark name=M.label m(label name) in
  let jump name=M.branch m(label name) in
  let branch cond name=M.cond m cond(label name) in
  let compare reg n=M.int m 16 n;M.cmp m reg 16 in
  let append reg=M.store m ~bytes:1 reg 14 0;M.offset m 14 14 1 in
  let char c=M.int m 9(Char.code c);append 9 in
  let digit ()=M.add m 11 1 7;M.load m ~bytes:1 9 11 0;
    M.offset m 9 9 48;append 9;M.offset m 7 7 (-1) in
  M.label m "runtime_float";
  (* [0,800): exact digits; [800,864): output; 872: input; 880: LR. *)
  M.offset m 31 31 (-896);M.store m 30 31 880;M.store m 0 31 872;
  M.offset m 1 31 0;M.offset m 14 31 800;
  M.shift_right m 17 0 63;M.cmp_zero m 17;branch 0 "unsigned";char '-';mark "unsigned";
  M.shift_right m 3 0 52;M.int m 9 2047;M.bit_and m 3 3 9;
  M.imm m 9 0x000fffffffffffffL;M.bit_and m 0 0 9;
  compare 3 2047;branch 0 "special";
  (* Match the existing scalar print's .0 suffix: round-trip via signed I64.
     The positive 2^63 boundary must be excluded before A64's saturating FCVTZS. *)
  M.load m 9 31 872;M.fp_from_bits m ~single:false 0 9;
  M.fp_to_int m ~single:false ~unsigned:false 9 0;
  M.fp_of_int m ~single:false ~unsigned:false 1 9;
  M.fp_cmp m ~single:false 0 1;M.cset m 17 0;
  M.imm m 9 0x43e0000000000000L;M.fp_from_bits m ~single:false 2 9;
  M.fp_cmp m ~single:false 0 2;branch 4 "suffix_checked";M.int m 17 0;
  mark "suffix_checked";
  M.cmp_zero m 3;branch 1 "normal";
  M.cmp_zero m 0;branch 0 "zero";M.int m 3 (-1074);jump "power";
  mark "normal";M.imm m 9 0x0010000000000000L;M.bit_or m 0 0 9;
  M.offset m 3 3 (-1075);
  mark "power";M.int m 4 0;M.int m 5 2;M.cmp_zero m 3;branch 10 "mantissa";
  M.sub m 3 31 3;M.mov m 4 3;M.int m 5 5;
  mark "mantissa";M.int m 2 0;M.int m 6 10;
  mark "mantissa_digit";
  M.rr m 0x9ac00800 10 0 6;M.mul m 9 10 6;M.sub m 9 0 9;
  M.add m 11 1 2;M.store m ~bytes:1 9 11 0;M.offset m 2 2 1;
  M.mov m 0 10;M.cmp_zero m 0;branch 1 "mantissa_digit";
  mark "multiply";M.cmp_zero m 3;branch 0 "round";
  M.int m 7 0;M.int m 8 0;
  mark "multiply_digit";M.add m 11 1 7;M.load m ~bytes:1 9 11 0;
  M.mul m 9 9 5;M.add m 9 9 8;M.rr m 0x9ac00800 8 9 6;
  M.mul m 10 8 6;M.sub m 9 9 10;M.store m ~bytes:1 9 11 0;
  M.offset m 7 7 1;M.cmp m 7 2;branch 3 "multiply_digit";
  M.cmp_zero m 8;branch 0 "multiplied";
  M.add m 11 1 2;M.store m ~bytes:1 8 11 0;M.offset m 2 2 1;
  mark "multiplied";M.offset m 3 3 (-1);jump "multiply";
  mark "round";M.sub m 12 2 4;M.offset m 12 12 (-1);
  M.int m 13 0;compare 2 17;branch 13 "trim";
  M.offset m 13 2 (-17);M.offset m 7 13 (-1);
  M.add m 11 1 7;M.load m ~bytes:1 9 11 0;
  compare 9 5;branch 12 "round_up";branch 11 "trim";
  (* Halfway: any nonzero lower digit rounds up, otherwise use retained parity. *)
  mark "sticky";M.cmp_zero m 7;branch 0 "tie";
  M.offset m 7 7 (-1);M.add m 11 1 7;M.load m ~bytes:1 9 11 0;
  M.cmp_zero m 9;branch 1 "round_up";jump "sticky";
  mark "tie";M.add m 11 1 13;M.load m ~bytes:1 9 11 0;
  M.int m 10 1;M.bit_and m 9 9 10;M.cmp_zero m 9;branch 0 "trim";
  mark "round_up";M.mov m 7 13;
  mark "carry";M.add m 11 1 7;M.load m ~bytes:1 9 11 0;M.offset m 9 9 1;
  compare 9 10;branch 11 "carry_done";
  M.store m ~bytes:1 31 11 0;M.offset m 7 7 1;M.cmp m 7 2;branch 3 "carry";
  M.add m 11 1 2;M.int m 9 1;M.store m ~bytes:1 9 11 0;
  M.offset m 2 2 1;M.offset m 12 12 1;M.offset m 13 13 1; jump "trim";
  mark "carry_done";M.store m ~bytes:1 9 11 0;
  mark "trim";M.offset m 7 2 (-1);
  mark "trim_zero";M.cmp m 13 7;branch 0 "render";
  M.add m 11 1 13;M.load m ~bytes:1 9 11 0;M.cmp_zero m 9;branch 1 "render";
  M.offset m 13 13 1;jump "trim_zero";
  mark "render";
  compare 12 (-4);branch 11 "scientific";compare 12 17;branch 10 "scientific";
  M.cmp_zero m 12;branch 11 "small_fixed";
  M.mov m 8 12;
  mark "whole";M.cmp m 7 13;branch 11 "whole_zero";digit ();jump "whole_next";
  mark "whole_zero";char '0';
  mark "whole_next";M.offset m 8 8 (-1);M.cmp_zero m 8;branch 10 "whole";
  M.cmp m 7 13;branch 11 "suffix";char '.';jump "fraction";
  mark "small_fixed";char '0';char '.';M.offset m 8 12 1;M.sub m 8 31 8;
  mark "leading_zero";M.cmp_zero m 8;branch 0 "fraction";char '0';
  M.offset m 8 8 (-1);jump "leading_zero";
  mark "fraction";digit ();M.cmp m 7 13;branch 10 "fraction";jump "suffix";
  mark "scientific";digit ();M.cmp m 7 13;branch 11 "exponent";char '.';
  mark "scientific_digit";digit ();M.cmp m 7 13;branch 10 "scientific_digit";
  mark "exponent";char 'e';M.cmp_zero m 12;branch 11 "negative_exponent";
  char '+';jump "exponent_digits";
  mark "negative_exponent";char '-';M.sub m 12 31 12;
  mark "exponent_digits";compare 12 100;branch 11 "exponent_two";
  M.int m 10 100;M.rr m 0x9ac00800 9 12 10;M.mul m 11 9 10;
  M.sub m 12 12 11;M.offset m 9 9 48;append 9;
  mark "exponent_two";M.rr m 0x9ac00800 9 12 6;M.mul m 11 9 6;
  M.sub m 12 12 11;M.offset m 9 9 48;append 9;M.offset m 9 12 48;append 9;
  mark "suffix";M.cmp_zero m 17;branch 0 "output";char '.';char '0';jump "output";
  mark "zero";char '0';jump "suffix";
  mark "special";M.cmp_zero m 0;branch 1 "nan";
  char 'i';char 'n';char 'f';jump "output";
  mark "nan";char 'n';char 'a';char 'n';
  mark "output";M.offset m 1 31 800;M.sub m 2 14 1;M.int m 0 1;
  M.branch m ~link:true "runtime_write";
  M.load m 30 31 880;M.offset m 31 31 896;M.ret m
