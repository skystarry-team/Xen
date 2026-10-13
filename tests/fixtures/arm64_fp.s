// SPDX-License-Identifier: MIT OR Apache-2.0
// Independent oracle for arm64_machine_test.ml; regenerate with:
// aarch64-linux-gnu-as arm64_fp.s -o /tmp/arm64_fp.o
// aarch64-linux-gnu-objdump -d /tmp/arm64_fp.o
.text
fmov s0, w3
fmov d1, x4
fmov w5, s2
fmov x6, d3
fneg s0, s1
fneg d2, d3
fadd s0, s1, s2
fsub s0, s1, s2
fmul s0, s1, s2
fdiv s0, s1, s2
fadd d3, d4, d5
fsub d3, d4, d5
fmul d3, d4, d5
fdiv d3, d4, d5
fcmp s1, s2
fcmp d3, d4
fcvt s0, d1
fcvt d2, s3
scvtf s0, x1
ucvtf s2, x3
scvtf d4, x5
ucvtf d6, x7
fcvtzs x0, s1
fcvtzu x2, s3
fcvtzs x4, d5
fcvtzu x6, d7
lsr x0, x1, #52
and x2, x3, x4
orr x5, x6, x7
