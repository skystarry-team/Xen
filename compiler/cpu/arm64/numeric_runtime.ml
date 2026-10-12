(* SPDX-License-Identifier: Apache-2.0 *)
(* Generated runtime carries the additional MIT OR Apache-2.0 permission in LICENSE.
   Checked decimal file readers, independent of libc and the host architecture.
   Parsers return x0=value bits, x1=status (0, 5 syntax, 6 range). File readers
   return status in x0 after releasing their input and any partial output.

   Decimal -> binary64 uses an exact integer ratio and one nearest/even rounding.
   Keep 800 significant decimal digits plus a sticky bit. Every binary64 rounding
   boundary is an integer times 2^p with p >= -1075 and a <=54-bit significand:
   its terminating decimal has fewer than 800 significant digits. Truncation can
   therefore affect a boundary comparison only when the retained prefix equals
   that boundary, in which case sticky distinguishes equality from greater-than.
   Normalized decimal orders [-324,308] need at most 10^1123 in the denominator;
   two 128-limb base-2^32 integers (4096 bits each) include normalization headroom.
   All scratch is bounded stack storage; only x0..x17 are used. *)
module M = Machine_ir
let call m name = M.branch m ~link:true name
let compare m reg n = M.int m 16 n;M.cmp m reg 16
let emit_big m =
  (* multiply/add(x0 limbs, x1 multiplier, x2 initial carry). *)
  M.label m "numeric_big_multiply";M.int m 3 0;
  M.label m "numeric_big_multiply_loop";M.int m 7 4;M.mul m 7 3 7;M.add m 7 0 7;
  M.load m ~bytes:4 4 7 0;M.mul m 4 4 1;M.add m 4 4 2;
  M.store m ~bytes:4 4 7 0;M.shift_right m 2 4 32;
  M.offset m 3 3 1;compare m 3 128;M.cond m 3 "numeric_big_multiply_loop";M.ret m;
  (* compare(x0 lhs, x1 rhs) -> -1/0/1. *)
  M.label m "numeric_big_compare";M.int m 3 127;
  M.label m "numeric_big_compare_loop";M.int m 7 4;M.mul m 7 3 7;
  M.add m 4 0 7;M.add m 5 1 7;M.load m ~bytes:4 4 4 0;M.load m ~bytes:4 5 5 0;
  M.cmp m 4 5;M.cond m 3 "numeric_big_less";M.cond m 8 "numeric_big_greater";
  M.offset m 3 3 (-1);M.cmp_zero m 3;M.cond m 10 "numeric_big_compare_loop";
  M.int m 0 0;M.ret m;
  M.label m "numeric_big_less";M.int m 0 (-1);M.ret m;
  M.label m "numeric_big_greater";M.int m 0 1;M.ret m;
  (* subtract(x0 lhs, x1 rhs), with lhs >= rhs. *)
  M.label m "numeric_big_subtract";M.int m 3 0;M.int m 2 0;
  M.label m "numeric_big_subtract_loop";M.int m 7 4;M.mul m 7 3 7;
  M.add m 7 0 7;M.int m 6 4;M.mul m 6 3 6;M.add m 6 1 6;
  M.load m ~bytes:4 4 7 0;M.load m ~bytes:4 5 6 0;
  M.sub m 4 4 5;M.sub m 4 4 2;M.cmp_zero m 4;M.cset m 2 11;
  M.store m ~bytes:4 4 7 0;M.offset m 3 3 1;compare m 3 128;
  M.cond m 3 "numeric_big_subtract_loop";M.ret m;
  (* bit length(x0 limbs), zero -> 0. *)
  M.label m "numeric_big_bits";M.int m 3 127;
  M.label m "numeric_big_bits_find";M.int m 7 4;M.mul m 7 3 7;M.add m 7 0 7;
  M.load m ~bytes:4 4 7 0;M.cmp_zero m 4;M.cond m 1 "numeric_big_bits_count";
  M.offset m 3 3 (-1);M.cmp_zero m 3;M.cond m 10 "numeric_big_bits_find";
  M.int m 0 0;M.ret m;
  M.label m "numeric_big_bits_count";M.int m 0 32;M.mul m 0 3 0;
  M.label m "numeric_big_bits_loop";M.offset m 0 0 1;M.shift_right m 4 4 1;
  M.cmp_zero m 4;M.cond m 1 "numeric_big_bits_loop";M.ret m

let emit_int m =
  (* Optional sign, at least one decimal digit; accumulate unsigned magnitude
     with a pre-multiply check, including the asymmetric signed minimum. *)
  M.label m "runtime_parse_int";M.mov m 2 0;M.add m 3 0 1;
  M.int m 4 0;M.int m 5 0;M.cmp m 2 3;M.cond m 0 "parse_int_invalid";
  M.load m ~bytes:1 6 2 0;compare m 6 45;M.cond m 1 "parse_int_plus";
  M.int m 5 1;M.branch m "parse_int_sign";
  M.label m "parse_int_plus";compare m 6 43;M.cond m 1 "parse_int_limit";
  M.label m "parse_int_sign";M.offset m 2 2 1;M.cmp m 2 3;M.cond m 0 "parse_int_invalid";
  M.label m "parse_int_limit";M.imm m 7 922337203685477580L;
  M.int m 8 7;M.add m 8 8 5;M.int m 9 10;
  M.label m "parse_int_digit";M.load m ~bytes:1 6 2 0;M.offset m 6 6 (-48);
  compare m 6 9;M.cond m 8 "parse_int_invalid";
  M.cmp m 4 7;M.cond m 8 "parse_int_range";M.cond m 1 "parse_int_accumulate";
  M.cmp m 6 8;M.cond m 8 "parse_int_range";
  M.label m "parse_int_accumulate";M.mul m 4 4 9;M.add m 4 4 6;
  M.offset m 2 2 1;M.cmp m 2 3;M.cond m 3 "parse_int_digit";
  M.mov m 0 4;M.cmp_zero m 5;M.cond m 0 "parse_int_ok";M.sub m 0 31 0;
  M.label m "parse_int_ok";M.int m 1 0;M.ret m;
  M.label m "parse_int_invalid";M.int m 1 5;M.ret m;
  M.label m "parse_int_range";M.int m 1 6;M.ret m

let emit_float m =
  let mark s=M.label m ("parse_float_"^s) in
  let jump s=M.branch m ("parse_float_"^s) in
  let branch c s=M.cond m c ("parse_float_"^s) in
  let get r off=M.load m r 31 off in
  let put r off=M.store m r 31 off in
  let numerator ()=M.offset m 0 31 160 in
  let denominator ()=M.offset m 0 31 672 in
  let pair ()=numerator();M.offset m 1 31 672 in
  let double_num ()=numerator();M.int m 1 2;M.int m 2 0;call m "numeric_big_multiply" in
  (* [0,160) scalar state; [160,672) numerator; [672,1184) denominator.
     0 cursor, 8 end, 16 negative, 24 decimal point seen, 32 total digits,
     40 significant digits, 48 fractional digits, 56 retained, 64 sticky,
     72 exponent magnitude, 80 exponent sign, 88 exponent cap,
     96 decimal scale / binary exponent, 104 shift count / quotient,
     112 remaining fraction bits, 120 normal flag, 1192 LR. *)
  M.label m "runtime_parse_float";M.offset m 31 31 (-1200);put 30 1192;
  M.add m 9 0 1;put 0 0;put 9 8;
  M.offset m 9 31 16;M.int m 10 1168;
  mark "clear";M.store m ~bytes:1 31 9 0;M.offset m 9 9 1;
  M.offset m 10 10 (-1);M.cmp_zero m 10;branch 1 "clear";
  (* Exponent cap lies in the cleared range; initialize after clearing. *)
  M.offset m 9 1 16384;put 9 88;
  get 9 0;get 10 8;M.cmp m 9 10;branch 0 "invalid";
  M.load m ~bytes:1 11 9 0;compare m 11 45;branch 1 "plus";
  M.int m 11 1;put 11 16;jump "sign";
  mark "plus";compare m 11 43;branch 1 "mantissa";
  mark "sign";M.offset m 9 9 1;put 9 0;
  mark "mantissa";get 9 0;get 10 8;M.cmp m 9 10;branch 0 "mantissa_done";
  M.load m ~bytes:1 11 9 0;M.offset m 12 11 (-48);compare m 12 9;branch 8 "not_digit";
  get 10 32;M.offset m 10 10 1;put 10 32;
  get 10 24;M.cmp_zero m 10;branch 0 "whole_digit";
  get 10 48;M.offset m 10 10 1;put 10 48;
  mark "whole_digit";get 10 40;M.cmp_zero m 10;branch 1 "significant";
  M.cmp_zero m 12;branch 0 "advance";
  mark "significant";M.offset m 10 10 1;put 10 40;
  get 10 56;compare m 10 800;branch 2 "discard";
  M.offset m 10 10 1;put 10 56;M.mov m 2 12;numerator();M.int m 1 10;
  call m "numeric_big_multiply";jump "advance";
  mark "discard";M.cmp_zero m 12;branch 0 "advance";M.int m 10 1;put 10 64;
  mark "advance";get 9 0;M.offset m 9 9 1;put 9 0;jump "mantissa";
  mark "not_digit";compare m 11 46;branch 1 "mantissa_done";
  get 10 24;M.cmp_zero m 10;branch 1 "invalid";M.int m 10 1;put 10 24;jump "advance";
  mark "mantissa_done";get 10 32;M.cmp_zero m 10;branch 0 "invalid";
  get 9 0;get 10 8;M.cmp m 9 10;branch 0 "decimal_order";
  M.load m ~bytes:1 11 9 0;compare m 11 101;branch 0 "exponent_start";
  compare m 11 69;branch 1 "invalid";
  mark "exponent_start";M.offset m 9 9 1;M.cmp m 9 10;branch 0 "invalid";
  M.load m ~bytes:1 11 9 0;compare m 11 45;branch 1 "exponent_plus";
  M.int m 11 1;put 11 80;jump "exponent_sign";
  mark "exponent_plus";compare m 11 43;branch 1 "exponent_digit";
  mark "exponent_sign";M.offset m 9 9 1;M.cmp m 9 10;branch 0 "invalid";
  mark "exponent_digit";M.load m ~bytes:1 11 9 0;M.offset m 11 11 (-48);
  compare m 11 9;branch 8 "invalid";
  get 12 72;get 13 88;M.int m 14 10;
  M.rr m 0x9ac00800 15 13 14;M.cmp m 12 15;branch 8 "exponent_saturate";
  M.mul m 12 12 14;M.add m 12 12 11;M.cmp m 12 13;branch 9 "exponent_store";
  mark "exponent_saturate";M.mov m 12 13;
  mark "exponent_store";put 12 72;M.offset m 9 9 1;M.cmp m 9 10;branch 3 "exponent_digit";
  mark "decimal_order";get 9 72;get 10 80;M.cmp_zero m 10;branch 0 "exponent_signed";
  M.sub m 9 31 9;
  mark "exponent_signed";get 10 40;M.cmp_zero m 10;branch 0 "zero";
  get 11 48;M.sub m 10 10 11;M.offset m 10 10 (-1);
  (* Compare before adding: even a saturated exponent cannot overflow order. *)
  M.int m 11 308;M.sub m 11 11 10;M.cmp m 9 11;branch 12 "range";
  M.int m 11 (-324);M.sub m 11 11 10;M.cmp m 9 11;branch 11 "range";
  M.add m 9 9 10;get 10 56;M.offset m 10 10 (-1);M.sub m 9 9 10;put 9 96;
  denominator();M.int m 9 1;M.store m ~bytes:4 9 0 0;
  get 9 96;M.cmp_zero m 9;branch 10 "positive_scale";
  M.sub m 9 31 9;put 9 104;
  mark "denominator_power";get 9 104;M.cmp_zero m 9;branch 0 "binary_order";
  M.offset m 9 9 (-1);put 9 104;denominator();M.int m 1 10;M.int m 2 0;
  call m "numeric_big_multiply";jump "denominator_power";
  mark "positive_scale";put 9 104;
  mark "numerator_power";get 9 104;M.cmp_zero m 9;branch 0 "binary_order";
  M.offset m 9 9 (-1);put 9 104;numerator();M.int m 1 10;M.int m 2 0;
  call m "numeric_big_multiply";jump "numerator_power";
  mark "binary_order";numerator();call m "numeric_big_bits";put 0 104;
  denominator();call m "numeric_big_bits";get 9 104;M.sub m 9 9 0;put 9 96;
  M.cmp_zero m 9;branch 11 "scale_numerator";put 9 104;
  mark "align_denominator";get 9 104;M.cmp_zero m 9;branch 0 "aligned_denominator";
  M.offset m 9 9 (-1);put 9 104;denominator();M.int m 1 2;M.int m 2 0;
  call m "numeric_big_multiply";jump "align_denominator";
  (* Rather than shifting denominator back, double numerator if ratio <1.
     Both yield the same normalized ratio while decreasing binary order. *)
  mark "aligned_denominator";pair();call m "numeric_big_compare";M.cmp_zero m 0;
  branch 10 "normalized";jump "normalize_double";
  mark "scale_numerator";M.sub m 9 31 9;put 9 104;
  mark "align_numerator";get 9 104;M.cmp_zero m 9;branch 0 "aligned_numerator";
  M.offset m 9 9 (-1);put 9 104;double_num();jump "align_numerator";
  mark "aligned_numerator";pair();call m "numeric_big_compare";M.cmp_zero m 0;
  branch 10 "normalized";
  mark "normalize_double";double_num();get 9 96;M.offset m 9 9 (-1);put 9 96;
  mark "normalized";get 9 96;compare m 9 1023;branch 12 "range";
  compare m 9 (-1075);branch 11 "range";
  compare m 9 (-1022);branch 11 "subnormal";
  M.int m 10 52;M.int m 11 1;put 11 120;jump "fraction_start";
  mark "subnormal";compare m 9 (-1075);branch 0 "half_subnormal";
  M.offset m 10 9 1074;
  mark "fraction_start";put 10 112;M.int m 9 1;put 9 104;
  pair();call m "numeric_big_subtract";
  mark "fraction";get 9 112;M.cmp_zero m 9;branch 0 "round";
  M.offset m 9 9 (-1);put 9 112;double_num();
  get 9 104;M.add m 9 9 9;put 9 104;
  pair();call m "numeric_big_compare";M.cmp_zero m 0;branch 11 "fraction";
  pair();call m "numeric_big_subtract";get 9 104;M.offset m 9 9 1;put 9 104;jump "fraction";
  mark "round";double_num();pair();call m "numeric_big_compare";
  M.cmp_zero m 0;branch 12 "round_up";branch 11 "rounded";
  get 9 64;M.cmp_zero m 9;branch 1 "round_up";
  get 9 104;M.int m 10 1;M.bit_and m 9 9 10;M.cmp_zero m 9;branch 0 "rounded";
  mark "round_up";get 9 104;M.offset m 9 9 1;put 9 104;
  mark "rounded";get 0 104;get 9 120;M.cmp_zero m 9;branch 0 "sign_bits";
  M.imm m 10 0x0020000000000000L;M.cmp m 0 10;branch 1 "normal_bits";
  M.shift_right m 0 0 1;get 9 96;M.offset m 9 9 1;put 9 96;
  compare m 9 1023;branch 12 "range";
  mark "normal_bits";get 9 96;M.offset m 9 9 1023;M.imm m 10 0x0010000000000000L;
  M.mul m 9 9 10;M.sub m 0 0 10;M.bit_or m 0 0 9;jump "sign_bits";
  (* At e=-1075 ratio is [1,2): only exact half with no tail rounds to zero. *)
  mark "half_subnormal";pair();call m "numeric_big_compare";M.cmp_zero m 0;
  branch 1 "minimum_subnormal";get 9 64;M.cmp_zero m 9;branch 0 "range";
  mark "minimum_subnormal";M.int m 0 1;jump "sign_bits";
  mark "zero";
  (* Preserve legacy zero exponent range errors while avoiding FP overflow. *)
  get 10 48;M.sub m 9 9 10;compare m 9 10000;branch 12 "range";
  compare m 9 (-10000);branch 11 "range";M.int m 0 0;
  mark "sign_bits";get 9 16;M.cmp_zero m 9;branch 0 "ok";
  M.imm m 9 Int64.min_int;M.bit_or m 0 0 9;
  mark "ok";M.int m 1 0;jump "return";
  mark "invalid";M.int m 1 5;jump "return";
  mark "range";M.int m 1 6;
  mark "return";get 30 1192;M.offset m 31 31 1200;M.ret m

let emit_reader m =
  (* read_numbers(x0 Vec descriptor, x1 path descriptor, x2 mode:1 int,2 float).
     Read and close the file before transferring its owned String to the parser.
     parse_numbers(x0 Vec descriptor, x1 owned String cell, x2 mode) consumes
     and clears the String cell, including on returned errors. *)
  M.label m "runtime_read_numbers";M.offset m 31 31 (-48);M.store m 30 31 40;
  M.store m 0 31 0;M.store m 2 31 8;
  List.iter(fun off->M.store m 31 0 off)[0;8;16];
  M.offset m 0 31 16;call m "runtime_read_text";
  M.cmp_zero m 0;M.cond m 1 "numbers_read_return";
  M.load m 0 31 0;M.offset m 1 31 16;M.load m 2 31 8;
  call m "runtime_parse_numbers";
  M.label m "numbers_read_return";M.load m 30 31 40;M.offset m 31 31 48;M.ret m;
  (*
     Two passes: validate/count before allocating, then populate exact capacity.
     String cleanup happens on every returned error, including output mmap.
     [0] result, [8] mode, [16..40] input String, [40] cursor, [48] count,
     [56] status, [64] output extent, [72] token start, [80] token end,
     [88] output cursor, [96] pass (0 count / 1 write), [120] LR. *)
  M.label m "runtime_parse_numbers";M.offset m 31 31 (-128);M.store m 30 31 120;
  M.store m 0 31 0;M.store m 2 31 8;
  List.iter(fun off->M.store m 31 0 off)[0;8;16];
  List.iter(fun off->M.store m 31 31 off)[40;48;56;64;88;96];
  List.iter(fun off->M.load m 9 1 off;M.store m 9 31 (16+off);M.store m 31 1 off)[0;8;16];
  M.label m "numbers_restart";M.load m 9 31 16;M.store m 9 31 40;
  M.label m "numbers_skip";M.load m 9 31 40;M.load m 10 31 16;
  M.load m 11 31 24;M.add m 10 10 11;M.cmp m 9 10;M.cond m 0 "numbers_pass_done";
  M.load m ~bytes:1 11 9 0;
  List.iter(fun byte->compare m 11 byte;M.cond m 0 "numbers_space")[32;9;10;13];
  M.store m 9 31 72;
  M.label m "numbers_token";M.cmp m 9 10;M.cond m 0 "numbers_parse";
  M.load m ~bytes:1 11 9 0;
  List.iter(fun byte->compare m 11 byte;M.cond m 0 "numbers_parse")[32;9;10;13];
  M.offset m 9 9 1;M.branch m "numbers_token";
  M.label m "numbers_space";M.offset m 9 9 1;M.store m 9 31 40;M.branch m "numbers_skip";
  M.label m "numbers_parse";M.store m 9 31 80;M.load m 0 31 72;M.sub m 1 9 0;
  M.load m 9 31 8;compare m 9 1;M.cond m 1 "numbers_float";
  call m "runtime_parse_int";M.branch m "numbers_parsed";
  M.label m "numbers_float";call m "runtime_parse_float";
  M.label m "numbers_parsed";M.cmp_zero m 1;M.cond m 1 "numbers_parse_failed";
  M.load m 9 31 96;M.cmp_zero m 9;M.cond m 0 "numbers_count";
  M.load m 9 31 88;M.store m 0 9 0;M.offset m 9 9 8;M.store m 9 31 88;
  M.branch m "numbers_next";
  M.label m "numbers_count";M.load m 9 31 48;
  M.imm m 10 (Int64.div (Int64.sub Int64.max_int 32L) 8L);
  M.cmp m 9 10;M.cond m 2 "numbers_large";
  M.offset m 9 9 1;M.store m 9 31 48;
  M.label m "numbers_next";M.load m 9 31 80;M.store m 9 31 40;M.branch m "numbers_skip";
  M.label m "numbers_pass_done";M.load m 9 31 96;M.cmp_zero m 9;
  M.cond m 1 "numbers_release";M.load m 9 31 48;M.cmp_zero m 9;
  M.cond m 0 "numbers_release";M.int m 10 8;M.mul m 0 9 10;M.offset m 0 0 32;
  M.store m 0 31 64;call m "runtime_alloc";
  M.imm m 9 (-4095L);M.cmp m 0 9;M.cond m 2 "numbers_alloc_failed";
  M.offset m 0 0 32;M.store m 0 31 88;M.load m 9 31 0;M.load m 10 31 48;
  M.store m 0 9 0;M.store m 10 9 8;M.store m 10 9 16;
  M.int m 9 1;M.store m 9 31 96;M.branch m "numbers_restart";
  M.label m "numbers_parse_failed";M.store m 1 31 56;M.branch m "numbers_output_release";
  M.label m "numbers_large";M.int m 9 7;M.store m 9 31 56;M.branch m "numbers_release";
  M.label m "numbers_alloc_failed";M.int m 9 8;M.store m 9 31 56;M.branch m "numbers_release";
  M.label m "numbers_output_release";M.load m 9 31 96;M.cmp_zero m 9;
  M.cond m 0 "numbers_release";M.load m 9 31 0;M.load m 0 9 0;M.offset m 0 0 (-32);
  List.iter(fun off->M.store m 31 9 off)[0;8;16];
  M.load m 1 31 64;call m "runtime_unmap";
  M.label m "numbers_release";M.offset m 0 31 16;call m "runtime_string_drop";
  M.load m 0 31 56;
  M.load m 30 31 120;M.offset m 31 31 128;M.ret m

let emit m = emit_big m;emit_int m;emit_float m;emit_reader m
