/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Linux-only service-contract oracle. Native CI executes the unmodified PE
   against real Win32 APIs; these ms_abi exports provide local fault injection. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#define RESULT(value) ((UINT64_C(0xabcddcba)<<32)|(uint32_t)(value))
#define API __attribute__((ms_abi,visibility("default")))
static unsigned last_error, allocations, conversions, path_conversions;
static int arg_count;
static char **arg_values;
static struct {void *address;size_t size;int persistent;} maps[1024];
static unsigned char files[1024];
void xen_test_arguments(int count,char **values) {arg_count=count;arg_values=values;}
static unsigned native_error(void) {
    switch(errno) {case ENOENT:return 2;case EACCES:return 5;case EBADF:return 6;
      case ENOMEM:return 8;case EPIPE:return 109;default:return 87;}
}
static int fail_nth(const char *name,unsigned count) {
    const char *value=getenv(name);return value && strtoul(value,NULL,10)==count;
}
API uint64_t GetLastError(void) {return RESULT(last_error);}
API void *VirtualAlloc(void *address,uint64_t size,unsigned type,unsigned protect) {
    (void)address;(void)type;(void)protect;
    if(fail_nth("XEN_TEST_ALLOC_FAIL",++allocations)) {last_error=8;return NULL;}
    void *p=mmap(NULL,size,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
    if(p==MAP_FAILED) {last_error=8;return NULL;}
    for(unsigned i=0;i<1024;i++)if(!maps[i].address){
        maps[i].address=p;maps[i].size=size;
        /* argv table + one UTF-8 allocation per argument live until exit. */
        maps[i].persistent=allocations<=(unsigned)arg_count;return p;
    }
    abort();
}
API uint64_t VirtualFree(void *address,uint64_t size,unsigned type) {
    if(size || type!=0x8000) abort();
    for(unsigned i=0;i<1024;i++)if(maps[i].address==address){
        munmap(address,maps[i].size);maps[i].address=NULL;return RESULT(1);}
    last_error=87;return RESULT(0);
}
/* Explicit UTF-8/UTF-16 conversion avoids depending on Linux wchar_t width. */
static int to_wide(const unsigned char *s,uint16_t *out,int cap) {
    int length=0;
    while(*s) {
        uint32_t c=*s++;unsigned continuation=0;uint32_t min=0;
        if(c>=0xf0 && c<=0xf4){c&=7;continuation=3;min=0x10000;}
        else if(c>=0xe0 && c<=0xef){c&=15;continuation=2;min=0x800;}
        else if(c>=0xc2 && c<=0xdf){c&=31;continuation=1;min=0x80;}
        else if(c>=0x80)return 0;
        for(unsigned i=0;i<continuation;i++){if((*s&0xc0)!=0x80)return 0;c=(c<<6)|(*s++&63);}
        if(c<min || c>0x10ffff || (c>=0xd800 && c<=0xdfff))return 0;
        if(c>=0x10000){c-=0x10000;if(out && length<cap)out[length]=0xd800+(c>>10);length++;c=0xdc00+(c&1023);}
        if(out && length<cap)out[length]=c;
        length++;
    }
    if(out && length<cap)out[length]=0;
    return length+1;
}
static int to_utf8(const uint16_t *s,char *out,int cap) {
    int length=0;
    while(*s){uint32_t c=*s++;unsigned char bytes[4];int n;
        if(c>=0xd800 && c<=0xdbff){unsigned low=*s++;if(low<0xdc00 || low>0xdfff)return 0;c=0x10000+((c-0xd800)<<10)+low-0xdc00;}
        else if(c>=0xdc00 && c<=0xdfff)return 0;
        if(c<128){bytes[0]=c;n=1;}else if(c<0x800){bytes[0]=0xc0|(c>>6);bytes[1]=0x80|(c&63);n=2;}
        else if(c<0x10000){bytes[0]=0xe0|(c>>12);bytes[1]=0x80|((c>>6)&63);bytes[2]=0x80|(c&63);n=3;}
        else {bytes[0]=0xf0|(c>>18);bytes[1]=0x80|((c>>12)&63);bytes[2]=0x80|((c>>6)&63);bytes[3]=0x80|(c&63);n=4;}
        for(int i=0;i<n;i++){if(out && length<cap)out[length]=bytes[i];length++;}
    }
    if(out && length<cap)out[length]=0;
    return length+1;
}
API uint64_t MultiByteToWideChar(unsigned cp,unsigned flags,const char *s,int bytes,uint16_t *out,int cap) {
    if(cp!=65001 || flags!=8 || bytes!=-1)abort();
    if(fail_nth("XEN_TEST_PATH_CONVERT_FAIL",++path_conversions)){last_error=1113;return RESULT(0);}
    int size=to_wide((const unsigned char*)s,NULL,0);
    if(!size || (out && size>cap)){last_error=1113;return RESULT(0);}
    return RESULT(to_wide((const unsigned char*)s,out,cap));
}
API uint64_t WideCharToMultiByte(unsigned cp,unsigned flags,const uint16_t *s,int chars,char *out,int cap,void *def,void *used) {
    if(cp!=65001 || flags!=0x80 || chars!=-1 || def || used)abort();
    if(fail_nth("XEN_TEST_CONVERT_FAIL",++conversions)){last_error=1113;return RESULT(0);}
    int size=to_utf8(s,NULL,0);
    if(!size || (out && size>cap)){last_error=1113;return RESULT(0);}
    return RESULT(to_utf8(s,out,cap));
}
API void *GetCommandLineW(void) {return (void*)1;}
API void *CommandLineToArgvW(void *command,unsigned *count) {
    if(command!=(void*)1)abort();
    size_t bytes=(arg_count+1)*sizeof(void*);
    for(int i=0;i<arg_count;i++)bytes+=2*to_wide((unsigned char*)arg_values[i],NULL,0);
    uint16_t **args=calloc(1,bytes),*at=(uint16_t*)(args+arg_count+1);
    for(int i=0;i<arg_count;i++){args[i]=at;at+=to_wide((unsigned char*)arg_values[i],at,0x7fffffff);}
    *count=arg_count;return args;
}
API void *LocalFree(void *address) {free(address);return NULL;}
API uint64_t GetStdHandle(unsigned code) {return (uint64_t)((int32_t)-10-(int32_t)code)+16;}
API uint64_t CreateFileW(const uint16_t *path,unsigned access,unsigned share,void *security,unsigned disposition,unsigned attrs,void *template) {
    if(share!=7 || security || attrs!=0x80 || template)abort();
    char *name=malloc(to_utf8(path,NULL,0));to_utf8(path,name,0x7fffffff);
    int fd=open(name,access==0x80000000?O_RDONLY:O_WRONLY|O_CREAT|O_TRUNC,0644);free(name);
    if((access==0x80000000 && disposition!=3)||(access==0x40000000 && disposition!=2))abort();
    if(fd<0){last_error=native_error();return UINT64_MAX;}
    if(fd>=1024)abort();
    files[fd]=1;return fd+16;
}
API uint64_t ReadFile(uint64_t file,void *buffer,unsigned length,unsigned *count,void *overlapped) {
    if(overlapped)abort();
    *count=0;
    if(getenv("XEN_TEST_READ_FAIL")){last_error=0xffffffff;return RESULT(0);}
    ssize_t result=read(file-16,buffer,length);if(result<0){last_error=native_error();return RESULT(0);}
    *count=result;if(!result && getenv("XEN_TEST_BROKEN_PIPE")){last_error=109;return RESULT(0);}return RESULT(1);
}
API uint64_t WriteFile(uint64_t file,const void *buffer,unsigned length,unsigned *count,void *overlapped) {
    if(overlapped)abort();
    *count=0;
    if(getenv("XEN_TEST_PARTIAL") && length>3)length=3;
    ssize_t result=write(file-16,buffer,length);if(result<0){last_error=native_error();return RESULT(0);}*count=result;return RESULT(1);
}
API uint64_t CloseHandle(uint64_t file) {
    unsigned fd=(unsigned)(file-16);
    if(fd>=1024 || !files[fd]){last_error=6;return RESULT(0);}
    files[fd]=0;
    int result=close(fd);if(result){last_error=native_error();return RESULT(0);}
    if(getenv("XEN_TEST_CLOSE_FAIL")){last_error=0xffffffff;return RESULT(0);}return RESULT(1);
}
API __attribute__((noreturn)) void ExitProcess(unsigned status) {
    if(getenv("XEN_TEST_RESOURCE_CHECK")) {
        unsigned memory=0,handles=0;
        for(unsigned i=0;i<1024;i++){
            if(maps[i].address && !maps[i].persistent)memory++;
            if(files[i])handles++;
        }
        if(memory || handles){
            fprintf(stderr,"runtime resource leak: %u allocations, %u handles\n",memory,handles);exit(90);
        }
    }
    exit(status);
}
