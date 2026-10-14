# Compiler optimization benchmarks

```sh
python3 benchmarks/optimization_benchmark.py
python3 benchmarks/aot_fusion_benchmark.py
dune exec benchmarks/semantic_opt_benchmark.exe
```

The native benchmark marks its workload with `#scope[opt]` and compares
`--opt=off` with `--opt=basic`. It reports compile/run medians, executable/code
sizes and independent output equality. Times are observations, never regression
pass criteria. The shared-region benchmark measures scaling around effect
boundaries inside a marked scope.

For loop-invariant work, build `tests/fixtures/language/opt_loops.xen` in both modes and inspect
`--opt-report` before comparing runtime. Measure short and long loops, zero-trip
calls and changing inputs separately; scalar safety does not guarantee a speedup.
The compiler uses AOT on both Linux targets and does not generate executable
code at runtime.

`tests/fixtures/language/opt_fusion.xen` exercises independent counted-loop fusion. Inspect
`--opt-report` to confirm the pair was fused before measuring. Compare cold and
warm `--opt-cache=<directory>` invocations separately: only scalar forward
rewrites are cached, while source checking, loop planning, backward DCE and
backend generation still run. A cache hit is not a compile-time speedup guarantee.

The historical JIT implementation is no longer available. Use the scoped AOT
commands above for current measurements.
