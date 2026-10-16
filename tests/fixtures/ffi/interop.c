/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <pthread.h>
#include <stdint.h>
#include <stdatomic.h>
#include <unistd.h>

static int initialized, marker;
__attribute__((constructor)) static void initialize(void) { initialized = 42; }
__attribute__((destructor)) static void finalize(void) {
    if (marker) { (void)write(1, "bye\n", 4); }
}
int32_t init_value(void) { return initialized; }
void mark_exit(void) { marker = 1; }
int64_t sum6(int64_t a,int64_t b,int64_t c,int64_t d,int64_t e,int64_t f) { return a+b+c+d+e+f; }
double mixed(int8_t a,float b,uint32_t c,double d,int64_t e,float f) { return a+b+c+d+e+f; }
float small_float(float a,int16_t b) { return a+b; }
int8_t signed_byte(void) { return -128; }
uint8_t unsigned_byte(void) { return 255; }
int16_t signed_half(void) { return -32768; }
uint16_t unsigned_half(void) { return 65535; }
int32_t signed_word(void) { return INT32_MIN; }
uint32_t unsigned_word(void) { return UINT32_MAX; }
void store_value(int64_t *p,int64_t n) { *p=n; }

static pthread_t thread;
static _Atomic uint64_t *shared;
static uint64_t iterations;
static int mode;
static void *worker(void *unused) {
    (void)unused;
    uint64_t *data=(uint64_t *)shared;
    if (mode==0) {
        for (uint64_t i=0;i<iterations;i++) atomic_fetch_add_explicit(shared,1,memory_order_relaxed);
    } else if (mode==1) {
        while (!atomic_load_explicit(shared,memory_order_acquire)) { }
        return (void *)(uintptr_t)data[1];
    } else {
        data[1]=42;
        atomic_store_explicit(shared,1,memory_order_release);
    }
    return 0;
}
int32_t start_worker(_Atomic uint64_t *p,uint64_t n,int32_t kind) {
    shared=p;iterations=n;mode=kind;
    return pthread_create(&thread,0,worker,0);
}
int64_t join_worker(void) {
    void *result=0;
    return pthread_join(thread,&result) ? -1 : (int64_t)(uintptr_t)result;
}
