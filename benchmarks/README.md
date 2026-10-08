# Cost observations

Build the compiler first, then run from the repository root:

```sh
python3 benchmarks/optimization_benchmark.py
python3 benchmarks/jit_benchmark.py
dune exec benchmarks/semantic_opt_benchmark.exe
```

These scripts record executable size, compilation time, runtime and
optimization scaling. They are separate from the regression suite and
have no timing pass/fail thresholds. JIT timings compare the same marked
source with `--opt=basic --jit=off/on`; timed runs disable reporting.

Each script prints JSON observations for the current machine. Keep the
platform, repetition count and comparison modes with any published results.
The experimental JIT currently establishes runtime generation and cache
reuse; these measurements do not promise a speedup over AOT.
