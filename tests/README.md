# Compiler tests

Run these commands from the repository root after `make build`. The Python
scripts use the standard library only (Python 3.10 or later). The decoded
machine-code check requires binutils `objdump`. JIT permission/failure
checks use Linux x86-64 `/proc`, resource limits and seccomp.

```sh
make test
make test QUICKCHECK_MODE=sweep QUICKCHECK_DEPTH=standard QUICKCHECK_SEED=20261008
```

`make test` runs the OCaml tests through `dune runtest`, repeats native core
execution with `--opt=basic`, runs the Python integration scripts and runs
the generated/metamorphic checks. It does not run benchmarks.

| Location | Purpose |
| --- | --- |
| `native_core_test.ml` | Language execution, ownership, cleanup and diagnostics |
| `semantic_ir_test.ml` | Verifier mutations and CFG metamorphic checks |
| `semantic_opt_test.ml` | Scalar optimization and bounded fusion |
| `jit_ir_test.ml` | Shared regions and structural operand patches |
| `integration/` | CLI, relocation/archive, stdlib, native test, optimization and JIT regressions |
| `property/` | Whole-program generation, independent oracles and source metamorphisms |

Focused commands:

```sh
dune exec tests/native_core_test.exe
dune exec tests/semantic_ir_test.exe
python3 tests/integration/toolchain_test.py
python3 tests/integration/jit_test.py
make quickcheck QUICKCHECK_MODE=mixed QUICKCHECK_DEPTH=smoke QUICKCHECK_SEED=20261008
make semantic-test QUICKCHECK_SEED=20261008
```

Integration scripts use `compiler/dist/xen`. Property tests accept an
explicit `XEN_BIN`, otherwise use the repository build or `xen` on `PATH`.
An invalid explicit override is an error; old `/tmp` binaries are never
selected. See [property/README.md](property/README.md) for all modes and
failure replay. Initial files are restored before every AOT/JIT comparison.

Timing/size observations live in [benchmarks/](../benchmarks/README.md).
The generator's structural shrinker remains part of `property/semantic.py`;
the unused statement-deletion shrinker was removed because it did not
preserve the expected-output oracle.

`make test-arm64` requires Linux ARM64 or `qemu-aarch64` (Ubuntu package
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

`make test-host` checks compiler version, import/check, default-target build/run/test,
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
`make package ... PACKAGE_CONTEXT=arm64 PACKAGE_ARCH=aarch64` command in the
ARM64 guide; the normal `make package` builds the default context independently.
Set `XEN_HOST_ARCHIVE` to that context-built archive to verify its actual contents
and relocated execution in the same host tests.
The platform host test uses the extracted compiler to build and execute stdlib I/O,
metadata/directory/cwd/process calls for both CPU targets, independently of the
compiler's own architecture.
See [ARM64 compiler validation](../compiler/cpu/arm64/README.md).
