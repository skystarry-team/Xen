# Contributing to the demo

Xen is an early demo for Linux x86-64. Reproducible bug reports, documentation
corrections and small changes with a concrete use case are welcome at
[skystarry-team/Xen](https://github.com/skystarry-team/Xen).

Build with OCaml and Dune 3.18 or later (`make build`). Compiler tests require Python
3.10 or later and binutils (`objdump`), with no third-party Python packages.
The demo build was verified with OCaml 5.5.0 and Dune 3.24.2.
`VERSION` declares the default compiler version. Make's `VERSION=...` override
is embedded in the compiler and carried into both archive formats. Direct
Dune builds use `VERSION`, or an explicit `XEN_BUILD_VERSION` override.

```sh
make test
make test QUICKCHECK_MODE=sweep QUICKCHECK_SEED=20261008
make quickcheck QUICKCHECK_MODE=mixed QUICKCHECK_DEPTH=smoke
make semantic-test QUICKCHECK_SEED=20261008
```

Use English for source comments, diagnostics and test scripts. Keep Unicode
test data through escapes when the characters themselves are part of a
test. English and Korean documentation are maintained in `docs/en/` and
`docs/ko/`; update the public support contract when behavior changes.

## Repository layout

| Directory | Contents |
| --- | --- |
| `compiler/` | OCaml compiler, Semantic IR, optimizer and native encoder |
| `stdlib/` | Xen standard library |
| `examples/` | Runnable programs and intentional diagnostic examples |
| `tests/` | OCaml regression/verifier tests |
| `tests/integration/` | Python CLI, distribution, stdlib, optimizer and JIT tests |
| `tests/property/` | Generated programs, independent oracles and metamorphic checks |
| `benchmarks/` | Opt-in timing/size observations; no timing pass thresholds |
| `assets/branding/` | AI-generated artwork and its attribution notices |
| `docs/` | User documentation in English and Korean |

See [tests/README.md](https://github.com/skystarry-team/Xen/blob/main/tests/README.md)
for focused checks and failure replay.
Benchmarks run separately from `make test`:

```sh
python3 benchmarks/optimization_benchmark.py
python3 benchmarks/jit_benchmark.py
```

`make package VERSION=0.1.0-demo` creates the binary bundle;
`make source-package VERSION=0.1.0-demo` exports the public source tree
without Git history or local artifacts. Both include the license notices.

## Licensing contributions

Contributions use the existing license for the affected path. The default
is MIT OR Apache-2.0; `compiler/`, `tests/property/` and
`tests/semantic_ir_test.ml` are Apache-2.0 only. Branding is CC-BY-4.0.
The compiler's generated-runtime exception applies as described in
[LICENSE](LICENSE). Preserve SPDX notices and identify any third-party
material and its license. Do not add material you cannot license under
the applicable terms.
