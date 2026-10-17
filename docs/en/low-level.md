# Low-level operations in bb

`#scope[bb]` grants lexical access to raw memory, raw syscalls, volatile memory
access and inline assembly. `#![bb]` enables these operations throughout a function;
`#global[bb]` enables them throughout a module. `#scope[opt, bb]` also enables
scoped optimization, preserving volatile accesses and assembly effects.

## Addresses and bounded pointers

`Ptr<T>` contains an address and an element count. Existing operations include
`raw_alloc<T>(count)`, `raw_load(pointer, index)`, `raw_store(pointer, index, value)`,
`raw_free(pointer)` and `ptr_addr(pointer)`. Types must be raw-safe POD; managed
values such as `String` are excluded. `core.intrinsics.size_of<T>()` and
`core.intrinsics.align_of<T>()` describe Xen's layout, not a C ABI.

`ptr_from_addr<T>(address: Int, count: Int) -> Ptr<T>` constructs a descriptor
without allocat[low-level.md](low-level.md)ing or taking ownership. The address is an `Int` bit pattern,
matching `ptr_addr`. Construction rejects negative counts, byte sizes above
`Int`'s positive range, misalignment, null addresses with nonzero counts and
unsigned address-range wraparound. Empty pointers still require alignment.
Subsequent indexed accesses retain the usual bounds checks.

These checks do not establish that an address is mapped, readable or writable.
The caller supplies a valid region and lifetime. Aliases do not extend its lifetime.
Call `raw_free` only for an allocation whose mapping and size you own; never free
an alias twice or free a pointer into another allocation or a device mapping.

## Volatile memory

```xen
fn main() {
    #scope[bb] {
        let storage = raw_alloc<U32>(1);
        let alias = ptr_from_addr<U32>(ptr_addr(storage), 1);
        volatile_store(alias, 0, u32(42));
        println(volatile_load(alias, 0));
        raw_free(storage);
    }
}
```

`volatile_load<T>(pointer: Ptr<T>, index: Int) -> T` and
`volatile_store<T>(pointer: Ptr<T>, index: Int, value: T) -> Unit` infer `T` from
the pointer when omitted. They support `I8/U8` through `I64/U64`, `F32` and `F64`.
`Bool`, aggregates and managed types are excluded. Each operation emits one
access to the target address at the scalar's width (1, 2, 4 or 8 bytes).
The compiler preserves access order, including repeated reads and unused results.
Bounds checks remain active.

Volatile does not provide atomic operations, inter-thread synchronization or CPU
memory fences. Device access also requires a suitable mapping and the platform's
ordering rules. Emit CPU fences with `memory_fence()` or supported assembly.

## CPU hints and memory fences

`cpu_relax() -> Unit` and `memory_fence() -> Unit` are target-neutral builtins
requiring `bb`. Neither accepts value or type arguments.

| Function | x86-64 | AArch64 | Meaning |
| --- | --- | --- | --- |
| `cpu_relax()` | `pause` | `yield` | Processor hint suitable for repeated waiting |
| `memory_fence()` | `mfence` | `dmb ish` | Orders memory reads and writes across the fence |

Both are optimization boundaries: unused and repeated calls retain their count
and order. `cpu_relax()` does not yield to the OS scheduler or promise a delay.
`memory_fence()` does not make accesses atomic or independently establish
language-level inter-thread synchronization. AArch64's barrier is inner-shareable;
it does not replace platform-specific device ordering or device-completion barriers.

```xen
fn main() {
    #scope[bb, opt] {
        let storage = raw_alloc<Int>(1);
        volatile_store(storage, 0, 42);
        memory_fence();
        cpu_relax();
        println(volatile_load(storage, 0));
        raw_free(storage);
    }
}
```

For hardware semantics, see [Intel's MFENCE documentation](https://www.intel.com/content/www/us/en/docs/fortran-compiler/developer-guide-reference/2025-0/for-mfence.html)
and [Arm's barrier scope documentation](https://support.arm.com/documentation/102336/0100/Limiting-the-scope-of-memory-barriers?lang=en).

## Atomic memory operations

Integer atomics operate on raw `Ptr<T>`, for `I8/U8` through `I64/U64`. Each call
requires `bb`, infers `T` from its pointer (or accepts an explicit type argument),
and checks element bounds and natural alignment.

| Call | Result |
| --- | --- |
| `atomic_load(p, index, order?)` | Observed `T` |
| `atomic_store(p, index, value, order?)` | `Unit` |
| `atomic_exchange(p, index, value, order?)` | Previous `T` |
| `atomic_compare_exchange(p, index, expected, desired, success?, failure?)` | Previous `T` observed by the comparison |
| `atomic_fetch_add/sub/and/or/xor(p, index, value, order?)` | Previous `T` |

Orders are string literals: `"relaxed"`, `"acquire"`, `"release"`, `"acq_rel"`,
`"seq_cst"`. Omitted orders default to seq_cst. CAS takes either both orders or
neither. Loads reject release/acq_rel; stores reject acquire/acq_rel. CAS failure
must be relaxed/acquire/seq_cst and no stronger than success; release success
permits only relaxed failure.

CAS is strong: equality of its return value and `expected` means success. ARM
retries store-exclusive failure after an equal comparison. Fetch arithmetic wraps
at the integer width without the ordinary integer overflow trap. Unused calls
and their order are preserved as optimization boundaries. The implementation may
use stronger ordering than requested: x86 uses locked operations and mfence;
ARM uses acquire/release accesses, exclusive retry loops and dmb ish.

These operations target ordinary shared memory, not device-memory atomics.
Initialize atomic objects before sharing them; all conflicting concurrent access
must use Xen atomics or compatible C atomic operations. An acquire observing a
release on the same object makes memory writes published before release available
to subsequent reads. Unsynchronized conflicting ordinary/volatile access and
use after lifetime end are invalid. This API does not introduce thread creation;
the tests exercise C threads, atomic contention and release/acquire interoperability.

```xen
fn main() {
    #scope[bb, opt] {
        let counter = raw_alloc<U32>(1);
        atomic_store(counter, 0, u32(1), "release");
        let old = atomic_fetch_add(counter, 0, u32(41), "acq_rel");
        assert(old == u32(1));
        println(atomic_load(counter, 0, "acquire"));
        raw_free(counter);
    }
}
```

## External C functions

`extern_call<Result>("library", "symbol", arguments...)` invokes an external
function with Linux x86-64 System V ABI or the AArch64 C ABI on Linux and macOS. It requires `bb`,
an explicit result type and literal library/symbol names.

Up to six fixed arguments may be integer scalars, F32/F64 or `Ptr<T>`. Integer
and FP arguments use separate ABI register banks; pointers pass only their
addresses. Results may be numeric scalars or Unit; receive C pointer results as
Int/U64 addresses, then construct a bounded descriptor with `ptr_from_addr`.
Use i8/u8/i16/u16/i32/u32 conversions to match narrow C types exactly. Unit means
C void. Variadic calls, aggregates by value, managed values and C callbacks are
unsupported. String does not automatically become a C string: supply valid
NUL-terminated `Ptr<U8>` storage.

The caller supplies the actual C signature, pointer lifetimes and compatible
data layouts. Xen struct/tuple layouts do not define C struct layouts. Conflicting
library or signature declarations for the same symbol are diagnosed. Foreign calls
remain unknown memory read/write effects and optimization boundaries.

```xen
fn main() {
    #scope[bb] {
        println(extern_call<I32>("libc.so.6", "abs", i32(-42)));
    }
}
```

The example uses Linux's `libc.so.6`. On Apple Silicon macOS 15+, use
`"/usr/lib/libSystem.B.dylib"` or an absolute path to an arm64 dylib.

Linux programs with foreign calls use glibc dynamic ELF and `__libc_start_main` for C
initialization and normal termination, library constructors/destructors and stdio
cleanup. Interpreter paths are `/lib64/ld-linux-x86-64.so.2` and
`/lib/ld-linux-aarch64.so.1`. Programs without foreign calls retain static ELF.
Compiling Xen needs no host assembler/linker or installed target libraries;
executing the program needs its target loader and shared libraries. The loader
reports missing libraries/symbols at execution. Default RUNPATH is `$ORIGIN`.

`library` declares a DT_NEEDED dependency. Symbols follow global dynamic-loader
lookup/interposition rules rather than a library-private dlsym lookup. See
[ELF dynamic linking](https://refspecs.linuxfoundation.org/elf/gabi4%2B/ch5.dynamic.html)
and [AAPCS64](https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst).

Apple Silicon programs use Mach-O `LC_LOAD_DYLIB` and eager dyld bindings for
each imported C symbol. Their `LC_MAIN` entry returns through libSystem so
dylib constructors and destructors run. Missing libraries and symbols are
reported by dyld when the program starts. `@loader_path` is available for
dylibs placed beside the generated executable.

## Inline assembly

On Linux x86-64:

```xen
fn main() {
    #scope[bb] {
        let answer = asm<Int>("add rax, rcx",
            inout("rax", 17), in("rcx", 25));
        println(answer);
        asm("pause");
    }
}
```

On Linux AArch64, the equivalent expression is
`asm<Int>("add x0, x0, x1", inout("x0", 17), in("x1", 25))`;
`asm("yield")` emits a processor hint.

The template and register names must be string literals. Instructions use
lowercase target-specific names, separated by `;` or escaped newlines. Inputs
are evaluated once, from left to right, before registers are populated.

| Constraint | Meaning |
| --- | --- |
| `in("register", value)` | Read-only integer input, no wider than the named register |
| `out("register")` | Write-only result, initialized by the template |
| `inout("register", value)` | Result tied to an input register |
| `clobber("register")` | Additional scratch register the template may overwrite |

Use one explicit integer result type for each output: `asm<U8,U32>(..., out("al"), out("r8d"))`
returns `(U8,U32)`, in output declaration order. One output returns a scalar;
no outputs return `Unit` (the type argument may be omitted, or explicitly `Unit`).
Output types may be narrower than their registers. Inputs must fit the named
register width and are sign/zero extended when staged. All arguments are evaluated
once, left to right, before register setup. Tuple results support normal
indexing, destructuring and generic value passing.

Constraints own physical registers: `rax/eax/ax/al` and `x0/w0` overlap.
Duplicate or overlapping inputs, outputs and clobbers are rejected. Use `inout`
for tied input/output. Every read needs defined bits from an input or earlier
write, and every write needs an output or clobber. x86 byte/halfword writes
preserve the upper bits; x86 32-bit and ARM `w` writes zero the upper 32 bits.
Reading `rax` after only writing `al` is rejected. High-byte x86 registers such
as `ah` are unsupported. All outputs are captured before tuple construction.

Flags do not cross asm boundaries. x86 `setcc` reads flags established by `cmp/test`;
other flag-changing arithmetic invalidates this conservative condition contract.
ARM `cset` requires `cmp/tst/adds/subs` earlier in the same template. Flag outputs
are integer `0/1` values, for example `asm<U8>("cmp r8d,r9d; setl al", in("r8d",i32(-1)),
in("r9d",i32(1)), out("al"))`; ARM uses `cmp w8,w9; cset w0,lt` with `out("w0")` and `U32`.

All assembly is volatile and carries unknown memory read/write effects in Semantic
IR. The compiler preserves it even when the result is unused, and treats it as an
optimization boundary. `pure`, `nomem` and other optimization options are not
supported. Assembly memory operands use raw addresses, bypassing pointer bounds
checks; the caller is responsible for their validity and alignment.

| Target | Registers | Instructions |
| --- | --- | --- |
| x86-64 | `rax rbx rcx rdx rsi rdi r8..r15` and their 32/16/8-bit aliases; restricted `rsp` | `mov movzx movsx movsxd lea`, `push pop`, `add sub xor and or imul`, `shl shr sar`, `neg not bswap`, `cmp test setcc`, `rdtsc cpuid`, `nop pause mfence lfence sfence` |
| AArch64 | `x0..x14`, `x17`, `x19..x28` and their `w` aliases; restricted `sp` | `mov`, `add sub adds subs mul and orr eor`, `lsl lsr asr`, `neg mvn rev`, `sxtb sxth sxtw uxtb uxth`, `cmp tst cset`, `ldr str ldur stur` and byte/halfword forms, restricted `mrs`, `nop yield`, `dmb sy/ish` |

x86 register aliases include `eax/ax/al`, `ebx/bx/bl`, `ecx/cx/cl`, `edx/dx/dl`, `esi/si/sil`,
`edi/di/dil` and `r8d/r8w/r8b` through `r15d/r15w/r15b`. Register operands must
have matching widths except explicit extension instructions. `mov` memory access
width follows the register. Optional `byte/word/dword/qword [base+offset]` (also
`byte ptr ...`) must agree with it. `movzx/movsx` memory sources require an explicit
byte/word width; `movsxd` requires a dword source and 64-bit destination. Memory
bases must be 64-bit registers, with signed32 byte displacements.

x86 arithmetic accepts register or immediate sources. 64-bit ALU immediates
are signed32 and sign extended; narrower operations accept an immediate bit pattern
of their width. `imul` requires 16/32/64-bit operands. Immediate shifts accept
`0..width-1`; variable shifts use `cl`. Initialize `cl` or a wider `rcx` alias
through an input or earlier write. Variable shift counts use the low six bits for
64-bit operands, or low five bits otherwise. `bswap` supports 32/64 bits.
Conditions for `setcc` include `e/z ne/nz l le g ge b/c be a ae s ns o no p np`.

ARM register operations support matched `w` or `x` widths. `mov #integer` may
expand to several constant materialization instructions. `add/sub/adds/subs` and
`cmp` accept a register or `#0..#4095` last operand. `lsl/lsr/asr` accept a register
or `#0..#(width-1)` count; variable counts use the low five/six bits for w/x.
`cset` accepts `eq ne cs/hs cc/lo mi pl vs vc hi ls ge lt gt le`.

ARM `ldr/str` access 32 bits with `w`, 64 with `x`. `ldrb/strb` and `ldrh/strh`
access 1/2 bytes with a `w` register, with zero-extending loads. Memory bases are
`x` registers. `[base, #byte_offset]` accepts nonnegative multiples of the access
width through `4095*width`; `[base]` means offset zero. `ldur/stur`, `ldurb/sturb`
and `ldurh/sturh` accept byte offsets `-256..255`. Index registers and pre/post-index
writeback are unsupported.

This x86-64 example combines an immediate shift and arithmetic:

```xen
fn main() {
    #scope[bb] {
        println(asm<Int>("shl r8, 1; add r8, 8", inout("r8", 17)));
    }
}
```

The AArch64 equivalent is
`asm<Int>("lsl x8, x8, #1; add x8, x8, #8", inout("x8", 17))`.
`rdtsc` writes both `rax` and `rdx`;
declare one as the output and the other as a clobber, or declare both clobbers.

### Temporary stack storage and preserved registers

Within one template, x86 `sub rsp, N` reserves temporary stack storage and
`add rsp, N` releases it. `N` must be a nonnegative signed32 immediate.
`push` and `pop` accept 64-bit registers; `push rsp` stores its value before the
push, while `pop rsp` is rejected. `mov rax, rsp` reads the current stack pointer;
`lea rax, [rsp+8]` computes an address without accessing memory. `lea` requires a
64-bit destination and an unqualified `[base+offset]` source.

ARM uses `sub sp, sp, #N` and `add sp, sp, #N`, where `N` is `0..4095` and a
multiple of 16. `mov xN, sp` copies SP. Both targets accept SP as a memory base
with the same access widths and offsets as ordinary bases. ARM `sp` is not a
general arithmetic/data register; use a copied `x` register for address arithmetic.

The compiler tracks every adjustment: releasing more than allocated or leaving
storage allocated at template end is an error. Separate asm expressions cannot
share a stack allocation. `rsp/sp` are implicit operands, never `in/out/inout`
or `clobber` constraints. Arbitrary SP writes and partial aliases `esp/spl/wsp`
are rejected. Stack-pointer restoration does not bounds-check raw memory access;
use only valid storage, initialize it before reading, and do not retain addresses
to temporary storage after releasing it. The SP seen by a template is after any
compiler register saves, and its absolute value/layout is not a stable ABI.

For example, on x86-64:

```xen
fn main() {
    #scope[bb] {
        println(asm<Int>(
            "sub rsp,16; mov [rsp],r12; mov rax,[rsp]; add rsp,16",
            in("r12",42), out("rax")));
    }
}
```

The ARM template is `sub sp,sp,#16; str x19,[sp]; ldr x0,[sp]; add sp,sp,#16`,
with `in("x19",42)` and `out("x0")`.

x86 `rbx/r12..r15` and ARM `x19..x28` are available with the normal alias,
initialization and constraint rules. The compiler saves their incoming values
before staging inputs and restores them after capturing all outputs. This also
applies to input-only constraints and partial-width aliases. Frame registers
`rbp/x29`, ARM link register `x30`, platform register `x18` and compiler scratch
`x15/x16` remain reserved.

### CPU information

x86 `cpuid` reads `eax` (leaf) and `ecx` (subleaf), and writes `eax/ebx/ecx/edx`.
Declare all four writes, using `inout` for its two inputs:

```xen
let (leaf,b,c,d) = asm<U32,U32,U32,U32>("cpuid",
    inout("eax",u32(0)), out("ebx"),
    inout("ecx",u32(0)), out("edx"));
```

ARM `mrs xN, cntvct_el0`, `mrs xN, cntfrq_el0` and `mrs xN, tpidr_el0` read the
virtual counter, its frequency and the thread pointer. The destination needs an
output/clobber constraint. Other system registers and privileged instructions
are unsupported. Counter availability and access depend on the execution
environment; counter reads alone do not establish memory ordering.

SIMD operands, labels, directives,
branches, calls and arbitrary instruction text are rejected. `asm` is a reserved
keyword. Common contracts are checked by `xen check`; target-specific instruction
and register validation runs during code generation (`build`, `run`, `test`).
Both backends encode assembly internally and need no host assembler or linker.

[Contents](README.md) · [Syntax](reference.md) · [한국어](../ko/low-level.md)
