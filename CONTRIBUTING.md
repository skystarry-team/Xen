# Contributing to the demo

Xen is an early demo for Linux x86-64 and ARM64, including platform stdlib services.
ARM64 supports checked numeric file readers and shared scoped AOT optimization.
macOS is unsupported and has no planned support. CPU encoders and internal
Mach-O/Darwin prototypes are retained for implementation testing.
Reproducible bug reports, documentation
corrections and small changes with a concrete use case are welcome at
[skystarry-team/Xen](https://github.com/skystarry-team/Xen).

See [compiler builds](docs/compiler-build/README.md) for prerequisites, native
OCaml installation, AArch64 cross toolchains and version configuration.
Test dependencies and focused suites are documented in [tests/README.md](tests/README.md).

```sh
make test
make test QUICKCHECK_MODE=sweep QUICKCHECK_SEED=20261008
python3 scripts/test.py --suite quickcheck --mode mixed --depth smoke
python3 scripts/test.py --suite semantic --seed 20261008
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
| `examples/` | User learning programs (regression inputs live in tests/fixtures/language/) |
| `tests/` | OCaml regression/verifier tests |
| `tests/integration/` | Python CLI, distribution, stdlib and scoped AOT tests |
| `tests/property/` | Generated programs, independent oracles and metamorphic checks |
| `benchmarks/` | Opt-in timing/size observations; no timing pass thresholds |
| `packaging/` | Archive and Debian packaging, toolchain examples and release asset checks |
| `scripts/` | General test runner |
| `assets/branding/` | AI-generated artwork and its attribution notices |
| `docs/` | User documentation in English and Korean |

See [tests/README.md](https://github.com/skystarry-team/Xen/blob/main/tests/README.md)
for focused checks and failure replay.
Benchmarks run separately from `make test`:

```sh
python3 benchmarks/optimization_benchmark.py
dune exec benchmarks/semantic_opt_benchmark.exe
```

Binary and source distribution commands are documented in the
[packaging guide](docs/compiler-build/en/packaging.md).

## Licensing contributions

Contributions use the existing license for the affected path. The default
is MIT OR Apache-2.0; `compiler/`, `tests/property/` and
`tests/semantic_ir_test.ml` are Apache-2.0 only. Branding is CC-BY-4.0.
The compiler's generated-runtime exception applies as described in
[LICENSE](LICENSE). Preserve SPDX notices and identify any third-party
material and its license. Do not add material you cannot license under
the applicable terms.
