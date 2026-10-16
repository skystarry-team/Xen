/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Independent AAPCS64 fixture; built with binutils, no cross C compiler needed. */
.data
.balign 8
initialized: .quad 0
marker: .quad 0
thread: .quad 0
shared: .quad 0
iterations: .quad 0
mode: .quad 0
.section .rodata
message: .ascii "bye\n"
.section .init_array,"aw"
.quad initialize
.section .fini_array,"aw"
.quad finalize
.text
initialize:
 adrp x9, initialized
 mov x10, 42
 str x10, [x9, :lo12:initialized]
 ret
finalize:
 adrp x9, marker
 ldr x9, [x9, :lo12:marker]
 cbz x9, 1f
 stp x29,x30,[sp,#-16]!
 mov x0, 1
 adrp x1, message
 add x1,x1,:lo12:message
 mov x2, 4
 bl write
 ldp x29,x30,[sp],#16
1: ret
.global init_value,mark_exit,sum6,mixed,small_float
.type init_value,%function
init_value:
 adrp x9, initialized
 ldr w0,[x9,:lo12:initialized]
 ret
mark_exit:
 adrp x9,marker
 mov x10,1
 str x10,[x9,:lo12:marker]
 ret
sum6:
 add x0,x0,x1
 add x0,x0,x2
 add x0,x0,x3
 add x0,x0,x4
 add x0,x0,x5
 ret
mixed:
 sxtb w0,w0
 scvtf d3,w0
 fcvt d4,s0
 ucvtf d5,w1
 scvtf d6,x2
 fcvt d7,s2
 fadd d0,d3,d4
 fadd d0,d0,d5
 fadd d0,d0,d1
 fadd d0,d0,d6
 fadd d0,d0,d7
 ret
small_float:
 sxth w0,w0
 scvtf s1,w0
 fadd s0,s0,s1
 ret
.global signed_byte,unsigned_byte,signed_half,unsigned_half,signed_word,unsigned_word,store_value
signed_byte: mov x0,#0x1280; ret
unsigned_byte: mov x0,#0x12ff; ret
signed_half: mov x0,#0x18000; ret
unsigned_half: mov x0,#0x1ffff; ret
signed_word: mov x0,#0x80000000; ret
unsigned_word: mov x0,#0xffffffff; ret
store_value: str x1,[x0]; ret
.global start_worker,join_worker
start_worker:
 stp x29,x30,[sp,#-16]!
 adrp x9,shared
 str x0,[x9,:lo12:shared]
 adrp x9,iterations
 str x1,[x9,:lo12:iterations]
 adrp x9,mode
 str x2,[x9,:lo12:mode]
 adrp x0,thread
 add x0,x0,:lo12:thread
 mov x1,0
 adr x2,worker
 mov x3,0
 bl pthread_create
 ldp x29,x30,[sp],#16
 ret
join_worker:
 stp x29,x30,[sp,#-32]!
 adrp x9,thread
 ldr x0,[x9,:lo12:thread]
 add x1,sp,16
 bl pthread_join
 cbnz w0,1f
 ldr x0,[sp,#16]
 b 2f
1: mov x0,-1
2: ldp x29,x30,[sp],#32
 ret
worker:
 adrp x9,shared
 ldr x9,[x9,:lo12:shared]
 adrp x10,iterations
 ldr x10,[x10,:lo12:iterations]
 adrp x11,mode
 ldr w11,[x11,:lo12:mode]
 cmp w11,1
 b.eq wait_value
 cmp w11,2
 b.eq publish_value
 cbz x10,worker_done
increment:
 ldaxr x0,[x9]
 add x0,x0,1
 stlxr w1,x0,[x9]
 cbnz w1,increment
 subs x10,x10,1
 b.ne increment
worker_done: mov x0,0; ret
wait_value:
 ldar x0,[x9]
 cbz x0,wait_value
 ldr x0,[x9,#8]
 ret
publish_value:
 mov x0,42
 str x0,[x9,#8]
 mov x0,1
 stlr x0,[x9]
 mov x0,0
 ret
.section .note.GNU-stack,"",%progbits
