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
| Vec<T> | Supported elements: scalars, Unit, String, supported aggregates, Box and nested Vec; construction, growth, get/index, set, pop, swap, replace, deep clone, equality and cleanup |
| Slice<T>, String.as_bytes() | Read-only views with checked bounds and existing frontend borrow/escape rules; element references and field projections |
| Numeric collections, byte conversion | `zeros`, `repeat`, Vec<I64/F64> output and Vec<U8>.into_string() |
| std.string, std.iter, std.hashmap | Collection paths supported; Ptr iteration and platform-dependent imports remain unsupported |
| JIT and JIT reports | Rejected when explicitly requested |
| Ptr, raw memory, files, `read_text` | Rejected |
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
unwinding, as in the existing runtime. Ptr, raw access and files remain rejected
until their own lifetime and platform contracts are implemented.

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

## Running the compiler on ARM64

Xen's compiler is OCaml code, independently of the machine code it emits.
Install native OCaml and Dune on Linux ARM64, then use the ordinary source build:

```sh
make build
compiler/dist/xen version
compiler/dist/xen run examples/arm64_collections.xen
compiler/dist/xen test std.string
make test-host
make test-arm64
make package
```

The compiler uses OCaml's build configuration to select its host default, so
neither `uname` nor an external tool on PATH is required by compilation. Binary
package names use the compiler ELF architecture, regardless of its output target.
The full `make test` additionally executes x86-specific backend/JIT regressions;
`make test-host` and `make test-arm64` are the ARM64 host validation commands.

An optional OCaml 5.5 cross-toolchain context is provided in
[`scripts/dune-workspace.arm64`](../../../scripts/dune-workspace.arm64). With a
matching native OCaml installation, adjust the two `/opt/ocaml-aarch64` paths
in that workspace to your OCaml cross compiler prefix, then:

```sh
test "$(/path/to/ocaml-aarch64/bin/ocamlc -config-var architecture)" = arm64
dune build --workspace=scripts/dune-workspace.arm64 _build/arm64/compiler/main.exe
aarch64-linux-gnu-readelf -h _build/arm64/compiler/main.exe
qemu-aarch64 -L /path/to/aarch64-sysroot _build/arm64/compiler/main.exe version
make package DUNE_WORKSPACE=scripts/dune-workspace.arm64 PACKAGE_CONTEXT=arm64 \
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
`dist/xen-<version>-linux-aarch64.tar.gz`; the ordinary `make package` produces
the default context's architecture archive. `PACKAGE_ARCH` is an optional ELF
check that catches a workspace accidentally falling back to x86_64. Linux is
the supported compiler package platform (`PACKAGE_PLATFORM=linux`), not an OS
inferred from ELF's `System V` ABI or the packaging machine. To package an
already-built ARM compiler without Dune, replace the workspace/context options
with `PACKAGE_BINARY=_build/arm64/compiler/main.exe`.

Verified here: an actual ARM64 Xen ELF built with OCaml 5.5's cross compiler,
executed through QEMU, performing version/check, default ARM64 builds at both
optimization levels, explicit x86 cross-builds and relocated stdlib discovery.
Both x86_64 and ARM64 archives are built with `make package`; the ARM archive
is extracted and relocated, and its compiler checks stdlib imports and builds
programs at both optimization levels through QEMU. The generated programs also
execute under QEMU. A QEMU-user compiler process
does not itself supply binfmt for `run`/`test` children; those commands require a
native ARM64 host or a configured kernel handler. Native ARM64 `make build`,
`run`, and `test` have not been executed on a physical ARM64 host in this session.

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

Add file operations with differential execution tests. Full stdlib
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
10,000-level recursive Vec cloning and mixed Box/Vec cleanup, and a bounded
guest address space verifies actual allocation failures.

Implement ARM64 JIT encoding, relocation, executable permissions and instruction
cache synchronization as a separate stage. Keep explicit JIT rejection until then.
Future inline assembly follows the [common/CPU boundary](../../README.md): common
typed operands and effects; backend instructions, registers and constraints.
