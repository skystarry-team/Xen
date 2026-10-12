# Compiler architecture

The frontend produces checked Semantic IR. The driver selects a backend for an
explicit CPU/OS pair; that backend owns machine lowering, its calling convention,
runtime emission and executable construction. `x86_64-linux` retains full existing support.
`aarch64-linux` (alias `arm64-linux`) now has an initial static backend for the
core language, requiring `--jit=off`. See its [support matrix](cpu/arm64/README.md).

```text
compiler/
  common/          xen_common: AST, parser, checking, Semantic IR, optimization,
                   project loading, Target and Backend_intf
  cpu/
    x86_64/        xen_x86_64: existing emitter, Linux runtime, JIT and ELF writer
    arm64/         xen_arm64: A64 encoder, core/ownership emitter, Linux runtime and ELF writer
  platform/        reserved OS boundary; see its README
  backend.ml       implementation registry in the xen_compiler driver library
  test_runner.ml   discovery and execution through Backend_intf.S
  main.ml          CLI, compilation pipeline and target selection
```

Dune enforces the dependency direction: `xen_compiler -> {xen_x86_64, xen_arm64} -> xen_common`.
The common library cannot import the driver or any concrete backend. The x86-64
library is wrapped, so its machine modules are named `Xen_x86_64.Native_backend`,
`Xen_x86_64.Machine_ir`, etc. Semantic IR tests and optimizer benchmarks can build
against `xen_common` alone. The compiler executable remains `compiler/main.exe`,
and the release executable remains `compiler/dist/xen`.

## Backend contract

`common/backend_intf.ml` defines `Backend_intf.S`: a target description, an opaque
executable type, `generate` from `Semantic_ir.checked_program`, and `write`.
Generation includes runtime/JIT emission and executable construction. Errors carry
an optional source span and a message. Drivers do not access machine bytes or
choose the executable format. A backend must reject unsupported requested features
explicitly. The x86-64 adapter translates existing emitter errors into this contract.

`Target.t` separates architecture from operating system. ABI, syscall conventions
and executable formats belong to a concrete combination: Linux ELF/syscalls are
not properties of every x86-64 target. A future Windows implementation needs its
own adapter and platform implementation, even if it reuses instruction encoding.
The existing ELF writer stays in `cpu/x86_64/` because its relocations and ELF machine
identifier are x86-64 specific. Runtime blobs and the scalar JIT stay there too. See [platform boundaries](platform/README.md).

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
- Bundled `stdlib/` code currently contains Linux x86-64 syscall numbers and kernel
  record layouts. It is **not portable merely because the frontend is shared**.
  Examples include `std.io`, `std.fs`, `std.env`, and `std.process`. The ARM64 backend rejects raw syscalls and unsupported storage/operations,
  so these modules cannot accidentally execute x86 syscall numbers. Full ARM64 support
  must introduce platform runtime entry points or select a target-specific stdlib
  root in the driver/project-loading pipeline before checking source. Do not change
  executable-relative stdlib discovery based on the compiler's CPU.
- User `bb` `syscall0`–`syscall6` numbers remain raw values for the selected target's
  OS ABI. Backends must not silently translate x86-64 syscall numbers into ARM64
  numbers. Capability checking and arity/type checks stay in common; the syscall
  instruction and register assignment stay in the backend.

`build` selects an output target, independently of the host. `run` and `test`
execute locally through the host kernel, requiring a compatible CPU/OS or a
user-configured binary handler. Process launch failures identify the requested
target. Cross-build on x86-64 and invoke `qemu-aarch64 ./program` explicitly for
ARM64 execution; the compiler does not start an emulator. The default remains `x86_64-linux` on every
host for compatibility. Host filesystem/process utilities are distinct from target
runtime operations.

## Future bb-scoped inline assembly

No syntax or assembly IR is introduced here. When it is added, common checking
should enforce the `bb` capability and represent typed inputs/outputs, volatility
and memory effects in Semantic IR. Optimization must preserve those effects,
including barriers and unknown memory writes. The selected backend should validate
instruction text, registers, operand constraints and clobbers, and perform register
allocation and encoding. CPU intrinsics need the same division between common
type/effect contracts and target-specific validation/lowering. The current opaque
backend contract does not expose x86-64 registers to the frontend.

## Validation

`make test` runs native/IR/JIT, CLI, packaging, stdlib and property tests. Backend
contract tests check selection, CPU/OS separation and injection into `Test_runner`.
CLI tests cover explicit/default x86-64 equivalence, unavailable targets, option
ordering and literal program arguments after `--`. During this refactor, all 16
top-level examples were compared byte-for-byte with the original emitter across
both optimization levels and both JIT settings.

`make test-arm64` requires native Linux ARM64 or QEMU, checks integer and FP encodings against
independently assembled instruction words, verifies ELF segments and diagnostics,
and executes the supported language subset with both optimizer levels. On x86-64
it also compares execution to the original backend. `make test` includes these
tests but skips ARM64 execution if no runner is installed.
