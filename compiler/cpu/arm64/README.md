# Linux ARM64 backend

```sh
make build
compiler/dist/xen build examples/arm64_core.xen --target=aarch64-linux --jit=off -o app
qemu-aarch64 ./app hello
make test-arm64
```

`arm64-linux` is an alias. The compiler emits AArch64 machine code and a static,
little-endian Linux ELF64 executable directly; no assembler, linker, libc, cross
toolchain or emulator is required to **build** it. Execution requires Linux ARM64
or an emulator such as QEMU. `run` and `test` use the host kernel and never launch
QEMU automatically. Their process-launch errors identify the selected target.
The default target remains `x86_64-linux` for compatibility.

This is a deliberately limited first implementation, not feature parity with the
x86-64 backend. Unsupported types, operations and builtins produce source-located
compile errors before an output executable is written.

| Feature | Current support |
| --- | --- |
| I8/U8/I16/U16/I32/U32/I64/U64, Bool, Unit | Yes, including wrapping arithmetic, comparisons and checked integer conversions |
| F32/F64 (Float), numeric conversions | Yes, scalar arithmetic, IEEE comparisons, checked conversions and 17-significant-digit output |
| Branches, loops, match, short circuit operators | Yes, through checked Semantic IR CFG |
| Functions, recursion, function pointers, generics | Yes, existing six-argument limit and 4096 logical-call-depth limit |
| Shared/mutable references | Yes, for supported referent types |
| Structs, tuples, enums | Yes, when all lowered fields have supported types |
| String literals, `arg`, `arg_count`, `len` | Yes, UTF-8 byte lengths and embedded NUL bytes |
| String copy/move/clone, equality, parameters and returns | Yes, with independent heap clones and ownership transfer |
| String concatenation, `int_to_str` | Yes, byte-preserving heap storage and lexical cleanup |
| Box<T>, recursive ownership | Yes, move-only allocation, borrowing, `into_inner`, and iterative recursive cleanup |
| `print`/`println`, `assert`/`assert_msg`, `panic` | Yes, for supported types |
| `--opt=off` / `--opt=basic` | Both |
| JIT and JIT reports | Rejected; specify `--jit=off` even without a JIT scope |
| Vec, Slice, Ptr, raw memory, files, `read_text` | Rejected |
| User raw syscalls, platform-dependent stdlib | Rejected; existing x86 syscall numbers are never emitted as ARM64 calls |

The compiler generates every function retained in checked IR, so unsupported code
in an unused function or imported module may also reject a build. `check` only
validates language semantics; it does not certify support by this backend.

## Internal calling convention and storage

This is a Xen-only convention, not a C FFI ABI. x0..x5 hold pointers to argument
values. The callee copies arguments into its frame before evaluating its body.
x8 points to caller-provided result storage for every return type. Aggregate and
String returns therefore never point into a returned stack frame. x29/x30 form
the frame record and are preserved; SP is always 16-byte aligned. Scratch code
uses x0..x17, leaving x18 and the other callee-saved registers untouched. Frames
use computed addresses, so local storage is not limited to a small instruction
immediate. The shared 64-bit Xen layout remains unchanged.
F32/F64 occupy 4/8 bytes and use the same argument/result pointers as other
values. Floating-point scratch uses v0..v7, leaving v8..v15 untouched.

## Floating point

Scalar `+`, `-`, `*`, `/`, negation and all six comparisons use A64 FP
instructions. Division by zero follows IEEE behavior (infinity or NaN), rather
than the integer division diagnostic. Unordered comparisons return false except
`!=`. Explicit numeric conversions and the compatibility `float`/`int` builtins
follow the existing x86-64 range checks: float-to-integer checks the input in
`[min, max+1)` before truncating toward zero; F64-to-F32 rejects NaN, infinities
and magnitudes above the largest finite F32. F32-to-F64 and same-type
conversions preserve nonfinite values; narrowing may underflow to signed zero.

`float_runtime.ml` emits a libc-free decimal formatter. It computes an exact
decimal digit array from the binary64 significand and exponent, rounds to 17
significant digits with ties to even, and selects fixed/scientific spelling as
in `%.17g`. F32 is widened exactly before printing. The existing scalar `.0`
suffix for values that round-trip through signed I64 is retained, including
`1e17` printing as `1e+17.0`. Negative zero prints as `-0.0`.
NaN spelling preserves the machine result's sign: invalid A64 arithmetic
such as `0.0/0.0` produces `nan`, while x86-64 SSE produces `-nan`;
negation flips that sign. This difference is tested explicitly.
The formatter uses a bounded 896-byte stack frame with 800 bytes for exact
decimal digits (at most 767 are required). It favors auditability over speed;
no heap storage, assembler, linker or host formatting library is needed.

## Allocation and ownership

Strings retain the shared 24-byte `(pointer, byte length, ownership marker)`
descriptor. Literals and argv have marker zero and borrow process-lifetime bytes.
Concatenation, `int_to_str`, and Clone produce independent mappings with marker
one; that marker is not allocation capacity. Nonempty String mappings have exactly
the requested byte length, which is also passed to `munmap`. Empty heap results
have a zero descriptor and do not call `mmap`. Embedded NULs and UTF-8 bytes are
copied by length. No supported operation mutates the underlying bytes.

`Read` observes storage, `Clone` independently copies every String leaf of an
aggregate, and `Move` transfers ownership. `Forget` disables flags and clears
descriptors without freeing them; `Drop` releases only active resources and
clears their descriptors. Function frames carry an initialized flag per owned
leaf, including partially moved fields. Parameters and newly produced values
activate their flags; elaborated `Drop_flag` updates also handle fields restored
by a callee. Dereferenced caller storage has no local flag and uses the same
inactive descriptor/pointer representation after moves or cleanup.

`Box<T>` keeps its public 8-byte pointer representation and the existing
move-only rule. It supports construction, shared/mutable borrowing, parameter
and aggregate transfer, returns, and `into_inner`. The allocation contains a
private 16-byte header followed by `max(1, sizeof(T))` payload bytes; the Xen
pointer addresses the payload, preserving its alignment. `into_inner` transfers
the value and unmaps the allocation without dropping the transferred contents.
Even `Box<Unit>` has a valid allocation.

Recursive Box cleanup uses an intrusive worklist in those private headers.
Helpers release String leaves and enqueue owned Box children in their own
headers before unmapping the parent. The dispatcher pops each allocation before
calling its type helper. Pending entries never point into freed parent storage;
cleanup neither allocates memory nor consumes a call frame per node. Mutually
recursive and generic helper definitions are registered before their child types
are visited. Enum cleanup relies on checked IR's separately stored payload fields
and inactive defaults; it does not interpret overlapping union storage.

`heap_runtime.ml` emits Linux AArch64 `mmap`/`munmap` services with RW,
private anonymous mappings. Size arithmetic and negative syscall errors are
checked before pointers are used. Allocation failure is fatal and exits without
unwinding, as in the existing runtime. Vec/Slice/Ptr, raw access and files remain
rejected until their own lifetime and platform contracts are implemented.

`machine_ir.ml` owns A64 instructions, labels and checked relocations. Conditional
branches use an inverted short condition plus a checked 26-bit branch. Addresses
use fixed four-instruction MOVZ/MOVK sequences. `linux_runtime.ml` owns the Linux
write/exit ABI, integer formatting and output retries. `elf_writer.ml` emits
EM_AARCH64, separate RX/R/RW load segments with 64KiB alignment (for 4/16/64KiB
Linux page sizes), and a non-executable GNU stack. No RWX segment is created.

The implementation was checked against [AAPCS64](https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst),
[AAELF64](https://github.com/ARM-software/abi-aa/blob/main/aaelf64/aaelf64.rst), and
the [Linux generic syscall table](https://github.com/torvalds/linux/blob/master/include/uapi/asm-generic/unistd.h).

## Next stages

Add collection and file operations with differential execution tests. Full stdlib
support needs explicit platform services or target-selected module implementations,
including ARM64 syscall numbers and kernel structures. Keep user raw syscall
numbers raw; do not silently translate them. The future OS boundary is documented
in [platform/](../../platform/README.md).

`make test-arm64` checks integer and FP instruction words against independent
assembly, then runs both optimization levels under Linux ARM64 or QEMU.
Execution coverage includes mixed numeric calls, recursion, references,
aggregate returns, all NaN comparisons, checked conversion boundaries and
deterministic generated float output against Python and x86-64 oracles.
Ownership tests exercise deep String clones, partial moves and reinitialization,
mutable replacement, recursive Box graphs, and `return`/`break`/`continue`/`?`
cleanup. With QEMU, a guest syscall ledger matches every successful allocation's
address and length to exactly one unmap, a 64KiB stack tests 20,000-node cleanup,
and a bounded guest address space verifies actual allocation failures.

Implement ARM64 JIT encoding, relocation, executable permissions and instruction
cache synchronization as a separate stage. Keep explicit JIT rejection until then.
Future inline assembly follows the [common/CPU boundary](../../README.md): common
typed operands and effects; backend instructions, registers and constraints.
