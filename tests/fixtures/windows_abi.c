/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <stdint.h>
#include <stddef.h>
#ifdef _WIN32
#include <windows.h>
#define API __declspec(dllexport)
#define ABI
#else
#define API __attribute__((visibility("default")))
#define ABI __attribute__((ms_abi))
#endif
#ifndef EXPORT_DELTA
#define EXPORT_DELTA 1
#endif

API ABI uint64_t same_export(uint64_t value) { return value + EXPORT_DELTA; }
API ABI uint64_t run_on_small_stack(void *code) {
#ifdef _WIN32
    /* A fresh thread avoids depending on how deeply the loader previously
       committed the process entry thread's stack. 4096 is the initial commit;
       the image still reserves 1 MiB, leaving room for the probed 128 KiB. */
    HANDLE thread=CreateThread(NULL,4096,(LPTHREAD_START_ROUTINE)code,NULL,0,NULL);
    if (!thread) return 0;
    DWORD status=0;
    if (WaitForSingleObject(thread,INFINITE)!=WAIT_OBJECT_0 || !GetExitCodeThread(thread,&status)) status=0;
    CloseHandle(thread);
    return status;
#else
    return ((uint64_t(ABI *)(void *))code)(NULL);
#endif
}
API ABI double double_result(int64_t a, double b, float c, int64_t d,
                            double e, float f, int64_t g, int64_t h) {
    return a+b+c+d+e+f+g+h;
}
API ABI float float_result(float a, double b, int64_t c, float d,
                          int64_t e, double f, int64_t g, float h) {
    return (float)(a+b+c+d+e+f+g+h);
}

/* Check positional GP/FP arguments, four stack arguments and 16-byte call
   alignment BEFORE using a compiler prolog. Then overwrite the entire shadow
   area and every Win64 volatile GP/FP register. A bridge that merely calls the
   API without preserving Xen's stronger contract must fail the caller checks. */
API ABI __attribute__((naked)) uint64_t probe(uint64_t a, double b, uint64_t c,
        float d, uint64_t e, double f, uint64_t g, float h) {
    __asm__ volatile(
        "mov %rsp,%r10\n\tand $15,%r10\n\tcmp $8,%r10\n\tjne 1f\n\t"
        "cmp $0x1122,%rcx\n\tjne 1f\n\tcmp $0x3344,%r8\n\tjne 1f\n\t"
        "movq %xmm1,%r10\n\tmovabs $0x4004000000000000,%r11\n\t"
        "cmp %r11,%r10\n\tjne 1f\n\t"
        "movd %xmm3,%r10d\n\tcmp $0xbfa00000,%r10d\n\tjne 1f\n\t"
        "cmpq $0x5566,40(%rsp)\n\tjne 1f\n\t"
        "movabs $0x4012000000000000,%r10\n\tcmp %r10,48(%rsp)\n\tjne 1f\n\t"
        "cmpq $0x7788,56(%rsp)\n\tjne 1f\n\t"
        "cmpl $0x40c80000,64(%rsp)\n\tjne 1f\n\t"
        "movq $-1,8(%rsp)\n\tmovq $-1,16(%rsp)\n\t"
        "movq $-1,24(%rsp)\n\tmovq $-1,32(%rsp)\n\t"
        "mov $-1,%rcx\n\tmov $-1,%rdx\n\tmov $-1,%r8\n\t"
        "mov $-1,%r9\n\tmov $-1,%r10\n\tmov $-1,%r11\n\t"
        "pxor %xmm0,%xmm0\n\tpxor %xmm1,%xmm1\n\tpxor %xmm2,%xmm2\n\t"
        "pxor %xmm3,%xmm3\n\tpxor %xmm4,%xmm4\n\tpxor %xmm5,%xmm5\n\t"
        "movabs $0x123456789abcdef,%rax\n\tret\n\t"
        "1: xor %eax,%eax\n\tret\n\t");
}
