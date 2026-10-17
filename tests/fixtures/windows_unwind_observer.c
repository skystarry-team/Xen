/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Native-only observer called through the generated program's real IAT. */
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0602
#endif
#include <windows.h>
#include <tlhelp32.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <stddef.h>
_Static_assert(sizeof(CONTEXT)==1232,"unexpected AMD64 CONTEXT size");
_Static_assert(offsetof(CONTEXT,Xmm0)==416,"unexpected AMD64 XMM context layout");
_Static_assert(sizeof(PROCESSENTRY32W)==568,"unexpected process snapshot size");
_Static_assert(offsetof(PROCESSENTRY32W,th32ProcessID)==8,"unexpected PID offset");
_Static_assert(offsetof(PROCESSENTRY32W,th32ParentProcessID)==32,"unexpected parent PID offset");
_Static_assert(sizeof(BY_HANDLE_FILE_INFORMATION)==52,"unexpected metadata size");
_Static_assert(offsetof(BY_HANDLE_FILE_INFORMATION,ftLastWriteTime)==20,"unexpected FILETIME offset");
_Static_assert(offsetof(FILE_FULL_DIR_INFO,FileName)==68,"unexpected directory name offset");

__declspec(dllexport) DWORD RunOnSmallStack(LPTHREAD_START_ROUTINE code) {
    HANDLE thread=CreateThread(NULL,4096,code,NULL,0,NULL);
    if(!thread)return 97;
    DWORD status=98;
    if(WaitForSingleObject(thread,INFINITE)==WAIT_OBJECT_0)GetExitCodeThread(thread,&status);
    CloseHandle(thread);return status;
}

static unsigned observed_float;
static DWORD64 gp(CONTEXT *context,unsigned reg) {
    switch(reg){case 3:return context->Rbx;case 5:return context->Rbp;
      case 6:return context->Rsi;case 7:return context->Rdi;case 12:return context->R12;
      case 13:return context->R13;case 14:return context->R14;case 15:return context->R15;
      default:ExitProcess(99);}
}
static void observe(CONTEXT *context,int exact) {
    DWORD64 main_base=(DWORD64)(uintptr_t)GetModuleHandleW(NULL);
    const char *expected=getenv("XEN_TEST_UNWIND_FRAMES");
    if(exact && !expected)ExitProcess(92);
    const char *float_frame=getenv("XEN_TEST_FLOAT_FRAME");
    unsigned seen=0;
    for(unsigned depth=0;depth<64;depth++) {
        DWORD64 image=0;
        PRUNTIME_FUNCTION function=RtlLookupFunctionEntry(context->Rip,&image,NULL);
        if(!function)ExitProcess(93);
        if(image==main_base) {
            unsigned info=*((unsigned char*)(uintptr_t)(image+function->UnwindData)+3);
            if(!(info&15) || ((gp(context,info&15)-16*(info>>4))&15))ExitProcess(99);
            if(float_frame && function->BeginAddress==strtoul(float_frame,NULL,10))observed_float=1;
            if(exact) {
                char *end=NULL;
                unsigned long begin=strtoul(expected,&end,10);
                if(end==expected || function->BeginAddress!=begin)ExitProcess(94);
                expected=(*end==',')?end+1:end;
            }
            seen++;
        } else if(seen) {
            break;
        }
        PVOID handler=NULL;DWORD64 frame=0,previous=context->Rsp;
        RtlVirtualUnwind(UNW_FLAG_NHANDLER,image,context->Rip,function,context,&handler,&frame,NULL);
        if(context->Rsp<=previous)ExitProcess(95);
        if(exact && !*expected)break;
    }
    if((exact && (*expected || seen!=6)) || seen<3)ExitProcess(96);
}

__declspec(dllexport) BOOL InspectReadFile(HANDLE file,void *buffer,DWORD length,DWORD *count,OVERLAPPED *overlapped) {
    CONTEXT context;
    RtlCaptureContext(&context);observe(&context,1);
    return ReadFile(file,buffer,length,count,overlapped);
}

__declspec(dllexport) BOOL InspectWriteFile(HANDLE file,const void *buffer,DWORD length,DWORD *count,OVERLAPPED *overlapped) {
    CONTEXT context;
    RtlCaptureContext(&context);observe(&context,0);
    return WriteFile(file,buffer,length,count,overlapped);
}
__declspec(dllexport) void CheckExitProcess(unsigned status) {
    ExitProcess(status==0 && !observed_float?91:status);
}
