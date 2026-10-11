# Initial Linux ARM64 backend

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

| Feature | Initial support |
| --- | --- |
| I8/U8/I16/U16/I32/U32/I64/U64, Bool, Unit | Yes, including wrapping arithmetic, comparisons and checked integer conversions |
| Branches, loops, match, short circuit operators | Yes, through checked Semantic IR CFG |
| Functions, recursion, function pointers, generics | Yes, existing six-argument limit and 4096 logical-call-depth limit |
| Shared/mutable references | Yes, for supported referent types |
| Structs, tuples, enums | Yes, when all lowered fields have supported types |
| String literals, `arg`, `arg_count`, `len` | Yes, UTF-8 byte lengths and embedded NUL bytes |
| String copy/move/clone, equality, parameters and returns | Yes, for process-lifetime immutable storage |
| `print`/`println`, `assert`/`assert_msg`, `panic` | Yes, for supported types |
| `--opt=off` / `--opt=basic` | Both |
| JIT and JIT reports | Rejected; specify `--jit=off` even without a JIT scope |
| Floating point | Rejected |
| String concatenation, `int_to_str`, heap string producers | Rejected |
| Vec, Slice, Box, Ptr, raw memory, files | Rejected |
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

All supported Strings originate in read-only ELF data or the initial process argv.
They use the existing 24-byte descriptor with capacity zero, own no allocation,
and stay valid for the process lifetime. Clone can share immutable bytes. Move and
cleanup clear descriptors, including borrowed fields, but never unmap the bytes.
No supported operation exposes or mutates the underlying bytes. Heap ownership
flags and deep clone/drop routines must be introduced **before** enabling a heap
producer or raw access; these operations must not simply be added to the allowlist.

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

Add floating-point lowering/formatting, then allocation and recursive ownership,
collection and file operations with differential execution tests. Full stdlib
support needs explicit platform services or target-selected module implementations,
including ARM64 syscall numbers and kernel structures. Keep user raw syscall
numbers raw; do not silently translate them. The future OS boundary is documented
in [platform/](../../platform/README.md).

Implement ARM64 JIT encoding, relocation, executable permissions and instruction
cache synchronization as a separate stage. Keep explicit JIT rejection until then.
Future inline assembly follows the [common/CPU boundary](../../README.md): common
typed operands and effects; backend instructions, registers and constraints.
