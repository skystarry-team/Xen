# Compiler tests

Run these commands from the repository root after `make build`. The Python
scripts use the standard library only (Python 3.10 or later). The decoded
machine-code check requires binutils `objdump`. Scoped AOT checks compare original
and optimized IR, native output and loop storage lifetimes.

```sh
make test
make test QUICKCHECK_MODE=sweep QUICKCHECK_DEPTH=standard QUICKCHECK_SEED=20261008
```

`make test` delegates to `scripts/test.py`, which runs the OCaml tests through `dune runtest`, repeats native core
execution with `--opt=basic`, runs the Python integration scripts and runs
the generated/metamorphic checks. It does not run benchmarks.

| Location | Purpose |
| --- | --- |
| `native_core_test.ml` | Language execution, ownership, cleanup and diagnostics |
| `x86_64_runtime_test.ml` | CPU-only lowering with an injected runtime, service routing, static/C entry, relocation and compilation-state isolation |
| `operators_test.ml`, `integration/operators_test.py` | Operator precedence and nested generic closers, IR contracts, integer-width bitwise folding, checked shifts, arithmetic, evaluation order and logical short circuit on both CPUs and optimizer levels |
| `integration/power_remainder_test.py` | Real power and exact floating remainder, independent ULP/bit oracles, subnormal/overflow/IEEE cases, static linking and preserved user recursion depth on both CPUs and optimizer levels |
| `integration/x86_64_runtime_test.py`, `x86_64_runtime_fixture.ml` | Relocatable float formatting/numeric parsing, long inline services, deterministic failures and complete mapping/fd cleanup |
| `semantic_ir_test.ml` | Verifier mutations and CFG metamorphic checks |
| `semantic_opt_test.ml` | Scalar optimization and bounded fusion |
| `scoped_opt_test.ml` | Scoped AOT, LICM, effects and storage lifetimes |
| `aot_fusion_test.ml` | Counted scalar loop fusion, prefix invalidation and fresh backward liveness |
| `integration/` | CLI, relocation/archive, stdlib, native test, scoped optimization regressions |
| `inline_asm_test.ml`, `integration/low_level_test.py`, `asm_abi_fixture.ml` | bb pointer/volatile/asm/hint/fence contracts, independent encodings, stack balance, preserved GP registers, CPU information, widths, immediate and displacement limits, effect order, both targets and optimizer levels |
| `integration/low_level_extended_test.py`, `fixtures/ffi/` | asm aliases/partial initialization/multiple outputs/flags, integer atomic widths/order/bounds/wrap, C ABI and ELF loading/lifecycle, actual thread contention and release/acquire in both targets and optimizer levels |
| `property/` | Whole-program generation, independent oracles and source metamorphisms |

Focused commands:

The extended low-level suite builds a native C fixture with gcc and an AArch64
fixture with GNU cross binutils. Cross dynamic execution uses qemu-aarch64 and
the installed AArch64 glibc loader/libraries (`/usr/lib/aarch64-linux-gnu`).
Missing fixture/execution prerequisites are reported as skips; Xen compilation
itself has no dependency on these tools or target libraries.
The x86-64 runtime suite uses qemu-x86_64 for mapping/fd traces and native
x86-64 or QEMU for execution. Fault injection leaves allocation-error rdi
nonzero and lengthens inline services to check the CPU's service ABI and
relocations independently of Linux's incidental instruction layout.

```sh
dune exec tests/native_core_test.exe
dune exec tests/x86_64_runtime_test.exe
python3 tests/integration/x86_64_runtime_test.py
dune exec tests/semantic_ir_test.exe
python3 tests/integration/toolchain_test.py
python3 tests/integration/scoped_opt_test.py
python3 tests/integration/aot_fusion_test.py
python3 scripts/test.py --suite quickcheck --mode mixed --depth smoke --seed 20261008
python3 scripts/test.py --suite semantic --seed 20261008
python3 scripts/test.py --suite packaging
```

Integration scripts use `compiler/dist/xen`. Property tests accept an
explicit `XEN_BIN`, otherwise use the repository build or `xen` on `PATH`.
An invalid explicit override is an error; old `/tmp` binaries are never
selected. See [property/README.md](property/README.md) for all modes and
failure replay. Initial files are restored before every scoped AOT comparison.

Timing/size observations live in [benchmarks/](../benchmarks/README.md).
The generator's structural shrinker remains part of `property/semantic.py`;
the unused statement-deletion shrinker was removed because it did not
preserve the expected-output oracle.

`python3 scripts/test.py --suite arm64` requires Linux ARM64 or `qemu-aarch64` (Ubuntu package
`qemu-user`). It runs instruction encoding/relocation checks and both-optimizer
execution tests for the ARM64 subset, including FP encoding, conversion boundaries,
17-digit decimal rounding and generated float output, with x86 differential checks
on x86 hosts. `make test` includes these tests but skips ARM64 execution when no
runner is installed; ELF and unsupported-feature checks still run.
Heap ownership tests cover String clones, field reinitialization and recursive
Box/Vec cleanup, deep recursive Vec cloning, aligned element storage, bounds,
String byte bridges and std.string/iter/hashmap paths. When QEMU is installed, guest mmap/munmap ledgers verify exact
allocation lifetimes, a 64KiB guest stack checks deep cleanup, and a bounded
guest address space injects allocation failures without limiting the emulator.
File tests add byte-preserving read/write, growth boundaries, proc/FIFO reads,
aggregate and recursive Box/Vec ownership, source diagnostics, fd 0 and a low fd
limit. QEMU open/close ledgers pair reused descriptors exactly; mmap/munmap ledgers
also cover read_text's temporary cleanup after a read or allocation failure.
Runtime fixtures check path-size overflow before access, failed-close cell
invalidation and inactive-close/empty-write no-ops.
A bounded guest-page filler distinguishes ENOMEM at the final exact-size String
allocation, after EOF, from geometric buffer growth failure.
Numeric reader tests check I64 limits, decimal grammar, EOF and ownership transfer,
and compare raw F64 bits at independently constructed exact midpoints and adjacent
decimal values. They include signed zero, subnormal/normal and overflow boundaries,
long mantissa/exponent cancellation, sticky tails and deterministic random values.
Error ledgers cover token/range failures after valid prefixes and actual ENOMEM
at the numeric result allocation, verifying input cleanup before status returns.
Raw memory tests add descriptor aliases, padded generic POD structs, FP bits,
zero counts, signed/unsigned widths, negative/boundary indices, size overflow and
allocation failure. Raw syscall tests cover all arities and argument order without
number translation. Platform stdlib success/error tests check normalized metadata,
directory flags, cwd and exact buffer/fd cleanup.

`python3 tests/integration/stdlib_test.py --arm64` runs the common contract suite
with both optimizers using native ARM64 or QEMU. It includes binary stdin/append,
symlink metadata, malformed and multi-batch directory records, removed cwd, low fd
limits and bounded guest VA. For a custom compiler/runner, use `XEN_BIN`, JSON
`XEN_HOST_RUNNER`, `XEN_STDLIB_TARGET`, JSON `XEN_STDLIB_RUNNER` and `XEN_STDLIB_OPT`.
Toolchain tests prove missing platform profiles cannot fall back to common/project
files, and macOS Intel/Apple Silicon targets fail before source/output access.

`python3 scripts/test.py --suite host` checks compiler version, import/check, default-target build/run/test,
both cross-build targets, relocated stdlib discovery and binary packaging. It
runs natively on Linux x86-64 or ARM64. The optional `XEN_BIN` and JSON
`XEN_HOST_RUNNER` variables run an actual emulated compiler binary explicitly;
in that mode native run/test checks are skipped because QEMU user does not
provide binfmt for children. ARM64 program execution is checked separately.
Packaging uses the selected compiler even in QEMU mode: the tests run
`make package PACKAGE_BINARY=...`, inspect the archive name and ELF bytes,
then extract and move it before checking stdlib imports, both optimization
levels and generated-program execution. Invalid runner JSON, architecture
mismatch, unsupported platform, version mismatch and runner failure must not
create an archive. To test context builds too, use the cross-workspace
`make package-one ... PACKAGE_CONTEXT=arm64 PACKAGE_ARCH=aarch64` command in the
[packaging guide](../docs/compiler-build/en/packaging.md); the normal `make package` builds both Linux compiler architectures.
Set `XEN_HOST_ARCHIVE` to that context-built archive to verify its actual contents
and relocated execution in the same host tests.
The platform host test uses the extracted compiler to build and execute stdlib I/O,
metadata/directory/cwd/process calls for both CPU targets, independently of the
compiler's own architecture.
See [AArch64 compiler builds and validation](../docs/compiler-build/en/aarch64.md).

`python3 scripts/test.py --suite macos-prototype` validates the internal Mach-O writer for both CPUs,
independent SHA-256 page signatures and ARM64 PIE relocations. It also generates
Darwin prototype images from checked Xen IR and confirms Darwin traps rather than
Linux traps. It does not boot macOS or certify runtime/loader/packaging support;
The Darwin syscall adapter also executes under Linux ARM64/QEMU with simulated
kernel returns, checking carry/errno normalization, x1 restoration, stack balance
and leaf LR preservation. This does not certify Darwin kernel behavior.
macOS is unsupported and has no planned support. These tests
preserve the CPU/Mach-O prototypes without enabling macOS support.
See [Darwin/Mach-O validation scope](../compiler/platform/darwin/MACOS_VALIDATION.md).

`python3 scripts/test.py --suite packaging` checks the default two-architecture
Make routes, native/cross selection on both host CPUs, toolchain configuration
validation, Debian version ordering, real .deb metadata/payload and relocated
execution, exact release assets/checksums, and preservation of existing files on
archive or Debian packaging failure. Debian checks require `dpkg-dev`. Full archive
relocation and compiler execution checks use `integration/host_test.py`.

`python3 tests/integration/windows_package_test.py` checks PE architecture and
system DLL policy (including rejection of delay imports), ZIP payloads, versions,
format selection and preservation of existing output on failure. It also runs
under `--suite packaging` and `--suite windows`. On native Windows x86_64 it builds
the actual ZIP, extracts and relocates it, then runs version/check/build/run/test
with an isolated PATH outside the repository, including stdlib file I/O, generated
PE execution, Linux cross output and missing-bundle failure. Release CI repeats
this on the ZIP uploaded for assembly using `python -m packaging.windows.smoke`.
This checks a Windows Server 2022 CI host, not a clean Windows installation.
Windows desktop validation on physical hardware is still required.
