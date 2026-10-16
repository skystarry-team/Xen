# Compiler architecture

The frontend produces checked Semantic IR. The driver selects a backend for an
explicit CPU/OS pair; that backend owns machine lowering, its calling convention,
runtime emission and executable construction. `x86_64-linux` retains full existing support.
`aarch64-linux` (alias `arm64-linux`) supports the core language and collections,
including bb atomics and scalar C interop. Both Linux targets emit static ELF by
default and dynamic ELF for external calls. See its [support matrix](cpu/arm64/README.md).

```text
compiler/
  common/          xen_common: AST, parser, checking, Semantic IR, scoped AOT optimization,
                   project loading, Target and Backend_intf
  cpu/
    x86_64/        xen_x86_64: x86 encoding, Make(Runtime) lowering and shared
                   output/heap/collection/file/numeric routines with required OS hooks
    arm64/         xen_arm64: A64 encoding, Make(Runtime) lowering and shared
                   formatting/numeric/ownership routines with required OS hooks
  platform/
    linux/
                   xen_linux_elf: shared Linux dynamic ELF metadata writer
      x86_64/      xen_linux_x86_64: Linux runtime, ELF, backend composition
      arm64/       xen_linux_arm64: Linux runtime, ELF, backend composition
    darwin/        xen_darwin: shared Mach-O writer, SHA-256, validation notes
      arm64/       xen_darwin_arm64: internal Darwin runtime/backend prototype
  backend.ml       implementation registry in the xen_compiler driver library
  test_runner.ml   discovery and execution through Backend_intf.S
  main.ml          CLI, compilation pipeline and target selection
```

Dune enforces `driver -> OS backend -> CPU/common`. CPU libraries do not depend
on Linux/Darwin libraries or re-export their implementations. Darwin ARM64 depends
on the shared Darwin writer and ARM64 CPU library; it remains unregistered.
The common library cannot import the driver or any concrete backend. Wrapped module
names identify the boundary: `Xen_x86_64.Machine_ir` is CPU-specific,
`Xen_x86_64.Native_backend.Make` and `Xen_arm64.Native_backend.Make` accept explicit
platform implementations. Both Linux `Native_backend` modules only instantiate
their CPU functor with `Linux_runtime`.
Semantic IR tests and optimizer benchmarks can build
against `xen_common` alone. The compiler executable remains `compiler/main.exe`,
and the release executable remains `compiler/dist/xen`.

## Backend contract

`common/backend_intf.ml` defines `Backend_intf.S`: a target description, an opaque
executable type, `generate` from `Semantic_ir.checked_program`, and `write`.
Generation includes runtime emission and executable construction. Errors carry
an optional source span and a message. Drivers do not access machine bytes or
choose the executable format. A backend must reject unsupported requested features
explicitly. Both CPU lowerings return the common backend error type directly.

`Target.t` separates architecture from operating system. ABI, syscall conventions
and executable formats belong to a concrete combination: Linux ELF/syscalls are
not properties of every x86-64 target. Other OS implementations need their
own adapter and platform implementation, even if it reuses instruction encoding.
CPU-specific ELF writers live under `platform/linux/<cpu>/`, using the corresponding
CPU encoder. x86-64 lowering and generated ownership routines use the service ABI
in `cpu/x86_64/runtime_intf.ml`. Linux owns syscall numbers, mmap/open flags,
register assignment for raw syscalls, process/glibc startup and executable selection.
Float formatting, file read builtins and numeric token parsing live in CPU
runtime modules. Their branches/calls and floating constants use machine-IR
relocations; file allocation/I/O and the final output write use platform services.
See the [x86-64 CPU boundary](cpu/x86_64/README.md).
The shared Mach-O writer and signing code live under `platform/darwin/`, with
architecture-specific Darwin services in its CPU subdirectories.
See [platform boundaries](platform/README.md).

`Backend.available` is the single registration point. Add a library implementing
`Backend_intf.S`, reference it from the driver Dune library, and register its module.
Neither the parser nor the common IR needs to import that backend. There is no
placeholder backend that accidentally emits x86-64 code for another target.

## Current shared constraints

- Xen's value layout is currently fixed at 64 bits: references, function pointers
  and boxes use 8 bytes, strings/vectors use 24-byte descriptors, and pointer/slice
  pairs use 16 bytes. The frontend computes aggregate offsets and folds `size_of`
  and `align_of` using this layout. This is a Xen layout contract, not the host's
  layout or a C ABI. A backend with a different value model would require a future
  layout input to checking, monomorphization and optimization.
- The current language limits functions/calls to six arguments. Keep this existing
  behavior; it does not specify how a new backend assigns machine registers.
- Fusion uses a conservative 8-byte-slot storage budget. This is an optimization
  heuristic, not a backend stack-frame allocation API.
- `std.io`, `std.fs`, `std.env`, and `std.process` use target-selected `std.platform`
  services. Profiles in `stdlib/platform/<target>/std/platform.xen` own syscall
  numbers, flags and kernel layouts; missing profiles fail without fallback.
  Both Linux profiles ship with every compiler. Executable-relative stdlib discovery
  remains independent of the target. Checking and test discovery receive the same
  target as generation; discovered test ASTs cannot be reused with another backend.
- User `bb` `syscall0`–`syscall6` numbers remain raw values for the selected target's
  OS ABI. Backends must not silently translate x86-64 syscall numbers into ARM64
  numbers. Capability checking and arity/type checks stay in common; the syscall
  instruction and register assignment stay in the backend.

`build` selects an output target, independently of the host. `run` and `test`
execute locally through the host kernel, requiring a compatible CPU/OS or a
user-configured binary handler. Process launch failures identify the requested
target. Cross-build on x86-64 and invoke `qemu-aarch64 ./program` explicitly for
ARM64 execution; the compiler does not start an emulator. The CLI default follows
the compiler's OCaml build architecture on Linux. Explicit targets override it;
Host filesystem/process utilities are distinct from target
runtime operations.

Intel/Apple Silicon macOS targets are recognized as x86_64-macos/aarch64-macos;
arm64 and darwin aliases normalize to these names. macOS is unsupported and has
no planned support. CPU encoders, the Mach-O writer and internal Darwin
prototypes are retained for implementation testing. Recognition of
an unsupported host cannot crash module initialization or prevent `version` from
running. See the [platform support policy](platform/README.md).

## bb-scoped low-level operations

`asm<T...>(template, in(...), out(...), inout(...), clobber(...))` has a dedicated
AST node. Common checking enforces `bb`, integer inputs/outputs, tuple layout for
multiple outputs, and constraint consistency. CPU checking tracks physical
register aliases and valid low bits, including 32-bit zero extension and partial
8/16-bit writes. Semantic IR retains constraints, typed operands,
volatility and unknown memory read/write effects. All asm, volatile accesses,
`cpu_relax()` and `memory_fence()` are effect boundaries excluded from scalar
optimization, loop motion and fusion. The latter two have dedicated Unit-valued
IR nodes: x86-64 emits `pause`/`mfence`, AArch64 emits `yield`/`dmb ish`.
CPU-local `inline_asm.ml` modules validate a closed instruction/register subset,
check reads and writes (including implicit clobbers), and encode without external
tools. Stack/frame and callee-saved registers and control flow are rejected.
Operands live in Semantic IR storage before backend register staging; ARM64's
x15/x16 address scratch registers cannot be used by assembly.

`volatile_load/store` support numeric scalars with one access at the element's
width, including ARM64 where ordinary raw POD access uses byte copying.
`ptr_from_addr<T>` constructs a bounded descriptor with count, alignment and
address-overflow checks; mapping validity and allocation lifetime remain the
bb caller's responsibility. See the [low-level reference](../docs/en/low-level.md)
for syntax, guarantees and the per-target instruction subset, including immediate
arithmetic, shifts, unary operations and checked byte-displacement encoding.

`atomic_*` uses dedicated IR nodes with validated integer widths, arity, natural
alignment and memory orders. All atomics are effect boundaries. The initial
lowering conservatively strengthens ordering: x86 uses scalar/locked operations
with mfence; ARM uses LDAR/STLR and LDAXR/STLXR retry loops with dmb ish. Strong
compare-exchange returns the observed old value, and clears a failed ARM reservation.

`extern_call<Result>(library,symbol,args...)` retains library/symbol metadata and
typed operands in IR. It supports six fixed numeric/Ptr arguments and numeric/Unit
results, with independent GP/FP ABI banks. Pointer arguments pass addresses only.
Common checks reject conflicting declarations of a symbol. CPU lowerings own
scalar C argument/result registers, GOT calls and the C ABI main thunk. Linux
runtimes own glibc startup and dynamic executable selection; the shared
Linux writer emits PT_INTERP, PT_DYNAMIC, DT_NEEDED, dynsym/hash/RELA and eager
GLOB_DAT relocations. A C ABI main wrapper preserves callee-saved registers and
returns through libc for initialization/termination and stdio cleanup. Plain Xen
programs retain the existing static executable path. No host assembler or linker
is invoked; target shared libraries are resolved by the runtime loader.

## Validation

`make test` runs native/IR/scoped-AOT, CLI, packaging, stdlib and property tests. Backend
contract tests check selection, CPU/OS separation and injection into `Test_runner`.
CLI tests cover explicit/default x86-64 equivalence, unavailable targets, option
ordering and literal program arguments after `--`.

`python3 scripts/test.py --suite arm64` requires native Linux ARM64 or QEMU, checks integer and FP encodings against
independently assembled instruction words, verifies ELF segments and diagnostics,
and executes the supported language subset with both optimizer levels. On x86-64
it also compares execution to the original backend. `make test` includes these
tests but skips ARM64 execution if no runner is installed.
