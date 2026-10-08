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
