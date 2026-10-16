# x86-64 CPU backend

`xen_x86_64` depends on common compiler code and host file utilities only.
It has no Linux library dependency or default platform instance.

| Module | Responsibility |
| --- | --- |
| `machine_ir.ml` | x86 byte emission, labels, code/data relocations and import slots |
| `inline_asm.ml` | Checked scalar inline assembly encoding |
| `native_backend.ml` | Semantic IR lowering, frames, Xen calls, scalar System V C calls, atomics and type-specific ownership helpers |
| `output_runtime.ml` | Integer/boolean and 17-digit F64 formatting |
| `heap_runtime.ml` | String ownership, concatenation, integer conversion and argument access |
| `collection_runtime.ml` | Vector allocation policy, ownership, equality and output |
| `file_runtime.ml` | File path copying, buffer growth, read/write loops, read builtins and error cleanup |
| `numeric_runtime.ml` | Whitespace recognition, checked signed integer and x87 decimal F64 token parsing |
| `runtime_intf.ml` | Required inline platform services and their register/clobber/error/stack contracts |

Instantiate `Native_backend.Make(Runtime)` to supply allocation, unmap, file I/O,
termination, raw syscalls, process entry, C library startup and executable writing.
CPU code stages raw syscall operands once; the platform loads its own registers
and consumes the staged stack slots. CPU code owns the C ABI main thunk's saved
registers; the platform owns initial process-stack decoding and C startup.
Each `generate` call has its own layout table, helper queue and label counter.
The current foreign-call lowering uses the scalar System V C ABI. A platform
with a different C ABI also needs corresponding foreign-call lowering.

Linux composition lives in `compiler/platform/linux/x86_64/`. Its `native_backend.ml`
only applies the functor to `Linux_runtime`; its ELF writer chooses static or
dynamic output. Linux syscall numbers, open/mmap flags and loader lifecycle stay
in that directory.

Formatting and parsing use normal CPU instruction emission. All internal branches
and calls use labels; F64 parsing's decimal constant lives in rodata with a RIP
relocation. There are no opaque runtime blobs or platform formatting/parsing hooks.
File read builtins retain their status/descriptor calling convention. String
results own exactly their byte length; numeric Vec results record capacity in
bytes so growth and drop follow the ordinary Vec layout.

Integer `**` uses wrapping exponentiation by squaring and rejects negative
exponents. Real `**` and floating `%` use the portable checked-IR functions in
`common/numeric_math.ml`. This CPU supplies only bit reinterpretation, scalar
sqrt and final F32 rounding. The compiler links reachable math helpers before
ownership analysis; these helpers preserve the user's logical call-depth
budget and require no additional platform services or dynamic libraries.

`tests/x86_64_runtime_test.ml` links only CPU/common libraries and generates code
with a probe runtime: no ELF, Linux syscall or implicit libc startup is supplied.
Linux behavior is exercised by native core, stdlib and low-level integration tests.
`integration/x86_64_runtime_test.py` executes the same CPU algorithms with long
inline service implementations and injected allocation/read/close failures,
checking syscall ledgers for full mapping release and single fd close.
