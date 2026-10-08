# Generated and metamorphic checks

This suite combines supported Xen features in complete programs and compares
execution against independent Python oracles. It uses only the Python standard
library. All files in this directory are licensed under Apache-2.0.

Run from the repository root after `make build`:

```sh
make quickcheck QUICKCHECK_MODE=mixed QUICKCHECK_DEPTH=smoke QUICKCHECK_SEED=20261008
make quickcheck QUICKCHECK_MODE=sweep QUICKCHECK_DEPTH=standard QUICKCHECK_SEED=20261008
make semantic-test QUICKCHECK_SEED=20261008
```

For a custom compiler, set `XEN_BIN` to an executable path and optionally set
`XEN_STDLIB_ROOT` to its library bundle. An invalid explicit binary path fails
immediately. Old temporary or version-specific binaries are never selected.

## Modes

| Mode | Checks |
| --- | --- |
| `regress` | Fixed diagnostics, runtime regressions and known inference limitations |
| `mixed` | Random combinations of supported features |
| `pairs` | Every emitter pair, two rounds by default |
| `kitchen` | Almost all features in one program |
| `illtyped` | Invalid source with expected diagnostics |
| `nocrash` | Frontend token/noise inputs with no internal crash |
| `semantic` | Typed ownership/borrow/cleanup models and source metamorphisms |
| `explore` | Manual contextual-literal probe reports; observations, not pass/fail checks |
| `all` | Regressions, mixed, illtyped, nocrash and semantic checks |
| `sweep` | `all` plus pairs and kitchen programs |

Depth selects 40 (`smoke`), 200 (`standard`), 1,000 (`deep`) or 5,000 (`massive`)
mixed/semantic scenarios. `--trials`, `--pair-rounds` and `--max-features` override
individual budgets. The runner prints its seed and actual emitter count; a
current sweep has 32 emitters, so two rounds cover 992 pair programs.

```sh
python3 tests/property/runner.py --mode pairs --pair-rounds 3 --seed 42
python3 tests/property/runner.py --mode explore --trials 100 --seed 42
python3 tests/property/runner.py --mode semantic --seed 20261008 --case 0
```

A failed execution returns a nonzero status and stores reproducing sources and
notes in ignored `tests/property/found_bugs/` when applicable. Semantic failures
also retain classification, original/transformed sources, oracle expectations,
a replay command and a structurally minimized scenario.

## Coverage and comparisons

The feature emitters cover integer/float arithmetic, Bool, byte strings, vectors,
slices, structs, tuples, enum/match, generics, named function values, references,
loops, ranges, iterators, owning recursive boxes, checked conversion, stdlib
strings/environment/files, assertions, raw memory/syscalls and multi-file imports.
Unsupported language features are not generated as expected-success inputs.

For every execution, restore the same initial files and use the same source path:

1. Original source, `--opt=off --jit=off`.
2. Original source, `--opt=basic --jit=off`.
3. Main wrapped in `#scope[jit]`, `--opt=basic --jit=off`.
4. The identical marked source, `--opt=basic --jit=on`.

Compare stdout, stderr and exit status exactly before checking the Python oracle.
This distinguishes the effect of adding a scope from the experimental runtime
encoder. Reports stay disabled. Invalid/no-crash inputs use the original `check`
path. Three known literal-left inference limitations remain explicit regression
pins rather than being silently filtered out.

## Files

| File | Role |
| --- | --- |
| `gen.py` | Feature emitters and mixed/pair/kitchen/invalid/noise generators |
| `grammar.py` | Program records and source rendering helpers |
| `oracle.py` | Integer wrapping, truncating division and float models |
| `props.py` | Compiler execution, file restoration and behavioral assertions |
| `regressions.py` | Fixed diagnostic/runtime cases and inference pins |
| `runner.py` | CLI, budgets, seeds and failure persistence |
| `semantic.py` | Typed ownership model, metamorphisms and structural shrinking |
| `semantic_generator_test.py` | Independent generator/oracle/shrinker controls |

See [Semantic IR testing](../../docs/ko/semantic-testing.md) for model boundaries,
failure classification and raw CFG metamorphisms in `tests/semantic_ir_test.ml`.
Opt-in measurements live in [benchmarks/](../../benchmarks/README.md).
