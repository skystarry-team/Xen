# Linux ARM64 backend

```sh
make build
compiler/dist/xen build examples/arm64_core.xen --target=aarch64-linux --jit=off -o app
qemu-aarch64 ./app hello
python3 scripts/test.py --suite arm64
```

`arm64-linux` is an alias. The compiler emits AArch64 machine code and a static,
little-endian Linux ELF64 executable directly; no assembler, linker, libc, cross
toolchain or emulator is required to **build** it. Execution requires Linux ARM64
or an emulator such as QEMU. `run` and `test` use the host kernel and never launch
QEMU automatically. Their process-launch errors identify the selected target.
The CLI defaults to the compiler's build architecture on Linux: `x86_64-linux`
on x86-64, `aarch64-linux` on ARM64. Explicit `--target` overrides that default.
JIT defaults to off for the ARM64 target and on for x86-64, independently of
option order; explicit ARM64 `--jit=on` or `--jit-report` is still rejected.

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
| Vec<T> | Supported elements: scalars, Unit, String, File, supported aggregates, Box and nested Vec; construction, growth, get/index for cloneable elements, set, pop, swap, replace, deep clone, equality and cleanup |
| Slice<T>, String.as_bytes() | Read-only views with checked bounds and existing frontend borrow/escape rules; element references and field projections |
| Numeric collections, byte conversion | `zeros`, `repeat`, Vec<I64/F64> output and Vec<U8>.into_string() |
| std.string, std.iter, std.hashmap | Supported, including bb-scoped Ptr iteration |
| JIT and JIT reports | Rejected when explicitly requested |
| File, `read_text` | Owned move-only fd; open_read/open_write, read/write/close/is_open, aggregate transfer and recursive cleanup |
| Ptr, raw memory | Checked allocation/access/free for scalar and named POD elements; non-owning descriptors |
| std.io, std.fs, std.env, std.process | Target-selected Linux AArch64 services, recoverable I/O and normalized metadata |
| User raw syscalls | Supported in bb; numbers passed unchanged through x8 and x0..x5 |
| `read_ints`, `read_floats` | Checked decimal token parsing with exact binary64 rounding |

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

`heap_runtime.ml` emits shared ownership logic through required platform hooks;
`compiler/platform/linux/arm64/linux_runtime.ml` supplies Linux AArch64
`mmap`/`munmap` with RW private anonymous mappings. Size arithmetic and negative syscall errors are
checked before pointers are used. Allocation failure is fatal and exits without
unwinding, as in the existing runtime. `Ptr<T>` is a 16-byte non-owning address/count
descriptor. Raw allocation uses zeroed mappings and aligned POD element strides;
negative counts, multiplication overflow and out-of-bounds offsets are checked.
Zero count returns a null descriptor; explicit free unmaps exactly count times stride.
Descriptor copies alias storage: bb callers remain responsible for avoiding leaks,
double free and use after free. FP raw access preserves bits, including negative zero.

## Collections

Vec retains the 24-byte `(element pointer, length, capacity)` descriptor; capacity
is a count, unlike String's ownership marker. Elements use actual aligned sizes,
with one byte per Unit. A private 32-byte header precedes the element array.
Initial allocation and clones use exact length capacity; push grows a full array
to four elements or doubles capacity. Growth transfers initialized bytes and
unmaps the previous header plus capacity extent. Negative counts, multiplication,
header addition, capacity growth and syscall errors are checked before access.
Empty initial vectors and clones allocate nothing; a popped-empty Vec may retain
capacity and still releases that allocation when dropped or converted to String.

Get/index and Slice get independently clone owned elements. Pop/replace return
ownership; set drops the previous element; swap exchanges bytes without cloning
or dropping. Only the initialized prefix is visited during cleanup. References
to elements and their fields use the original element stride and bounds checks.
The frontend still rejects mutable element borrows, cloning move-only elements,
and mutation or escape while a borrowed view is live. `$vec_into_string` makes
an exact-length String mapping and releases the old Vec's capacity plus header.

Vec and Box cleanup share one intrusive worklist. Vec saves length and mapping
extent into its own header before clearing the descriptor. Type helpers release
String leaves and enqueue child Box/Vec allocations, then unmap the parent.
Vec clone also uses fresh destination headers as an iterative worklist; the
source's headers are never modified. Thus recursive `Node -> Vec<Node>` clones
and alternating Box/Vec drops do not consume a call frame per node. Helper
definitions are registered before traversing child types. Equality handles
scalar, String and nested-Vec elements, including NaN and signed-zero semantics.

## Files

`File` is the shared 8-byte, move-only descriptor. Every nonnegative fd, including
zero, is active; moved or closed storage contains `-1`. File leaves participate
in local drop flags, partial moves, aggregate reinitialization and iterative
Box/Vec cleanup. They are never cloned. `close()` first invalidates the cell,
then closes it once; closing an inactive File is a no-op. Explicit close reports
errors, while lexical drop ignores close errors as on x86-64.

`open_read` uses O_RDONLY; `open_write` creates/truncates with the existing
O_WRONLY|O_CREAT|O_TRUNC flags and mode 0644, subject to umask. Paths are checked
for embedded NUL before making a temporary terminated copy. That mapping is
released on successful or failed open. Shared `file_runtime.ml` receives explicit
open/read/write/close hooks from the selected OS; the Linux runtime supplies
AArch64 openat/read/write/close. The reader retries interrupted open/read/write and tracks partial
progress. A nonempty write that makes no progress reports failure. Close is never
retried, following Linux's [close error contract](https://raw.githubusercontent.com/mkerrisk/man-pages/master/man2/close.2).

`File.read()` reads from the current offset through EOF and leaves the fd open.
It handles regular files, proc files and FIFO streams without relying on fstat
or seek. A geometric temporary buffer starts at 4096 bytes; size doubling and
allocation errors are checked. The final String owns exactly its byte length
with marker 1, or has a zero descriptor when empty. Temporary capacity is never
stored in the String marker. All bytes, including NUL and non-UTF-8 data, survive
read/write, cloning and return. `read_text(path)` shares this reader and always
closes its own fd, including read/allocation failures. A read error takes priority
over a simultaneous close error; close failure after a successful read releases
the result before reporting the source-located diagnostic. Fatal diagnostics do
not unwind unrelated user resources, matching the other runtime operations.

```sh
compiler/dist/xen build examples/file_lifecycle.xen --target=aarch64-linux -o /tmp/xen-file
qemu-aarch64 /tmp/xen-file /tmp/xen-disposable-file
```

This example creates or overwrites the supplied path. `std.io`/`std.fs`/`std.env`/
`std.process` now use the selected `std.platform` service implementation, including
ARM-specific openat/newfstatat, stat mode layout and directory flags. Recoverable
I/O preserves binary bytes and releases temporary buffers/fds on returned errors.
`read_ints` and `read_floats` read through EOF, close their owned fd and parse
ASCII space/tab/CR/LF-separated tokens. Empty files produce empty vectors.
Integers accept an optional sign and decimal digits over the full I64 range.
Floats accept an optional sign, decimal digits with an optional point (at least
one digit overall), and an optional `e`/`E` exponent with optional sign and digits.
NaN, infinity, hexadecimal numbers, NUL and other whitespace bytes are rejected.
Nonzero values rounding to zero or infinity report a source-located range error.
Signed zero is preserved; zero's adjusted decimal exponent retains the legacy
[-10000,10000] limit. Nonzero long mantissas/exponents are normalized before range
classification, so cancelling decimal scales do not cause intermediate overflow.

`numeric_runtime.ml` converts decimal to binary64 using two bounded 4096-bit
integer buffers and rounds once, nearest with ties to even. It retains 800
significant digits plus sticky; every binary64 rounding midpoint has fewer than
800 significant decimal digits. The parser needs 1200 bytes of aligned stack,
no heap scratch, host parser or libc. Exact results are tested as raw F64 bytes
against independently constructed rounding boundaries, rather than printed text.
The legacy x86 reader uses x87 decimal accumulation and is not the rounding oracle
for boundary cases. Both readers retain the same token grammar and diagnostics.
Input String storage and partial result mappings are released before any returned
parse/range/allocation error. Numeric Vec results use the existing 32-byte private
header and exact element-count capacity, with normal clone/move/drop behavior.

## Running the compiler on ARM64

Xen's compiler is OCaml code, independently of the machine code it emits.
Install native OCaml and Dune on Linux ARM64, then use the ordinary source build:

```sh
make build
compiler/dist/xen version
compiler/dist/xen run examples/arm64_collections.xen
compiler/dist/xen test std.string
python3 scripts/test.py --suite host
python3 scripts/test.py --suite arm64
make package
```

The compiler uses OCaml's build configuration to select its host default, so
neither `uname` nor an external tool on PATH is required by compilation. Binary
package names use the compiler ELF architecture, regardless of its output target.
The full `make test` additionally executes x86-specific backend/JIT regressions;
`python3 scripts/test.py --suite host` and `--suite arm64` provide focused host validation.
`make package` builds both Linux compiler architectures by default. Configure the
x86_64 cross toolchain on an ARM64 host; see [compiler packaging](../../../scripts/PACKAGING.md).

An optional OCaml 5.5 cross-toolchain context is provided in
[`scripts/dune-workspace.arm64`](../../../scripts/dune-workspace.arm64). With a
matching native OCaml installation, adjust the two `/opt/ocaml-aarch64` paths
in that workspace to your OCaml cross compiler prefix, then:

```sh
test "$(/path/to/ocaml-aarch64/bin/ocamlc -config-var architecture)" = arm64
dune build --workspace=scripts/dune-workspace.arm64 _build/arm64/compiler/main.exe
aarch64-linux-gnu-readelf -h _build/arm64/compiler/main.exe
qemu-aarch64 -L /path/to/aarch64-sysroot _build/arm64/compiler/main.exe version
make package-one DUNE_WORKSPACE=scripts/dune-workspace.arm64 PACKAGE_CONTEXT=arm64 \
  PACKAGE_ARCH=aarch64 \
  PACKAGE_RUNNER='["/usr/bin/qemu-aarch64","-L","/path/to/aarch64-sysroot"]'
XEN_BIN="$PWD/_build/arm64/compiler/main.exe" \
  XEN_HOST_ARCHIVE="$PWD/dist/xen-$(cat VERSION)-linux-aarch64.tar.gz" \
  XEN_HOST_RUNNER='["/usr/bin/qemu-aarch64","-L","/path/to/aarch64-sysroot"]' \
  python3 tests/integration/host_test.py
```

The ELF header must report `Machine: AArch64` (machine number 183). Verify both
the prefix and the result: a missing prefix may otherwise fall back to a host
OCaml installation on PATH.

OCaml's cross compiler can be built from matching 5.5 sources with
`./configure --target=aarch64-linux-gnu --prefix=...`, `make crossopt`, and
`make installcross`; it needs an AArch64 C toolchain and target libc. These tools
build the **OCaml compiler executable**, while Xen program emission still needs
no assembler, linker or libc. See [OCaml's build instructions](https://github.com/ocaml/ocaml/blob/5.5/INSTALL.adoc)
and [Dune contexts](https://dune.readthedocs.io/en/stable/reference/dune-workspace/context.html).

The package command builds only `_build/arm64/compiler/main.exe`, preserving
the default `compiler/dist/xen`. The result is
`dist/xen-<version>-linux-aarch64.tar.gz`; the ordinary `make package` builds both
architecture archives through the configured toolchains. `PACKAGE_ARCH` is an optional ELF
check that catches a workspace accidentally falling back to x86_64. Linux is
the supported compiler package platform (`PACKAGE_PLATFORM=linux`), not an OS
inferred from ELF's `System V` ABI or the packaging machine. To package an
already-built ARM compiler without Dune, replace the workspace/context options
with `PACKAGE_BINARY=_build/arm64/compiler/main.exe`.

The host integration suite checks compiler version, source validation, default
ARM64 builds, explicit x86 cross-builds and relocated stdlib discovery. Set
`XEN_BIN`, `XEN_HOST_ARCHIVE` and `XEN_HOST_RUNNER` as shown above to exercise a
cross-built compiler and its extracted package through QEMU. A QEMU-user compiler process
does not itself supply binfmt for `run`/`test` children; those commands require a
native ARM64 host or a configured kernel handler. Compiler execution under QEMU
does not validate native host builds or kernel-mediated child execution.

`machine_ir.ml` owns A64 instructions, labels and checked relocations. Conditional
branches use an inverted short condition plus a checked 26-bit branch. Addresses
use fixed four-instruction MOVZ/MOVK sequences. The Linux runtime under
`compiler/platform/linux/arm64/` owns its write/exit/memory/file ABI. Formatting
and output progress logic use shared CPU routines with required hooks.
Its sibling `elf_writer.ml` emits
EM_AARCH64, separate RX/R/RW load segments with 64KiB alignment (for 4/16/64KiB
Linux page sizes), and a non-executable GNU stack. No RWX segment is created.
`Native_backend.Make(Runtime)` separates CPU lowering from startup, syscall,
file flags and executable construction. The internal Darwin prototype reuses this
lowering with PIE ADRP+ADD address fixups. Its runtime/backend live under
`compiler/platform/darwin/arm64/`, and the shared Mach-O writer/signing code under
`compiler/platform/darwin/`. The prototype is unregistered and does not provide
macOS execution support. macOS is unsupported and has no planned support;
these CPU and Mach-O implementations are retained for implementation testing.

The implementation was checked against [AAPCS64](https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst),
[AAELF64](https://github.com/ARM-software/abi-aa/blob/main/aaelf64/aaelf64.rst), and
the [Linux generic syscall table](https://github.com/torvalds/linux/blob/master/include/uapi/asm-generic/unistd.h).

## Validation and limitations

Linux numeric file readers and stdlib services are implemented; the
[platform boundary](../../platform/README.md) defines macOS as unsupported, with
no planned support. CPU encoders and internal Darwin/Mach-O prototypes are
retained for implementation testing. User raw syscall numbers remain untranslated.

`python3 scripts/test.py --suite arm64` checks integer and FP instruction words against independent
assembly, then runs both optimization levels under Linux ARM64 or QEMU.
Execution coverage includes mixed numeric calls, recursion, references,
aggregate returns, all NaN comparisons, checked conversion boundaries and
deterministic generated float output against Python and x86-64 oracles.
Ownership tests exercise deep String clones, partial moves and reinitialization,
mutable replacement, recursive Box graphs, and `return`/`break`/`continue`/`?`
cleanup. With QEMU, a guest syscall ledger matches every successful allocation's
address and length to exactly one unmap, a 64KiB stack tests 20,000-node cleanup,
10,000-level recursive Vec cloning and mixed Box/Vec cleanup, and a bounded
guest address space verifies actual allocation failures.
File tests cover binary bytes, exact/growing read buffers, repeated EOF, proc/FIFO
reads, explicit close errors and closed-use diagnostics. A guest open/close ledger
tracks fd reuse alongside mmap/munmap extents; tests also use fd 0, a low descriptor
limit, mixed File/Box/Vec cleanup and allocation failure before read_text returns.
A bounded fixture leaves one free guest page, proving EOF precedes final String
allocation failure and that its temporary mapping and owned fd are then released.

ARM64 JIT is unsupported. It requires separate instruction encoding, relocation,
executable permissions and instruction cache synchronization.
Future inline assembly follows the [common/CPU boundary](../../README.md): common
typed operands and effects; backend instructions, registers and constraints.
