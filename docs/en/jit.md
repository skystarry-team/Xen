# Experimental scalar runtime JIT

This is an experimental demo feature. Its interface and implementation may
change. It has not demonstrated a performance advantage over optimized AOT;
the measured sample was about 5.8% slower after compilation. Use
`--jit=off` for the AOT baseline.

`#scope[jit] { ... }` enables a small runtime compiler for fixed-width integer
and Bool calculations. The ordinary checker validates the complete source first.
Calls, branches, ownership and cleanup use the existing native path.

```xen
fn calculate(x: Int) -> Int {
    #scope[jit] {
        let a = x * x;
        let b = x * x;
        return a + b;
    }
}
fn main() { println(calculate(3)); println(calculate(7)); }
```

```sh
xen run calculation.xen --opt=basic
xen run calculation.xen --opt=basic --jit=off
xen run calculation.xen --opt=basic --jit-report
```

`build`, `run`, and `test` accept `--jit=on|off` (default `on`) and `--jit-report`.
Only explicitly marked scopes produce JIT regions. Unmarked source uses AOT.
`off` runs the same marked source and checked IR through the AOT emitter, providing
a reference for comparisons. `--opt=off|basic` independently controls the shared
optimization passes before encoding; its default remains `off`. `check` validates
source, accepts no JIT flags and executes no runtime compiler.

Eligible operations are scalar constants, copies/stores, integer wrapping
arithmetic, signed/unsigned comparisons and Bool operations. Address-taken locals,
references/projections, memory effects, allocation, managed clone/drop, calls,
syscalls, Float, division/remainder and checked conversions divide regions.
Regions do not cross lexical scopes or CFG blocks. The fusion mode contract
remains exact: an ordinary leaf called from a jit scope stays an AOT call boundary.
`#global[jit]` and function-level `#![jit]` remain reserved and rejected.

Each compiled region has at most 32 encoding operations and fits in one 4096-byte
page, including entry/exit instructions. A process has at most 64 region cache
entries (256 KiB of JIT code mappings). Larger calculations split into bounded
regions; regions beyond the process budget use AOT as decided at build time.
Runtime mmap/mprotect failure reports `JIT compilation failed` at the original
region location and exits 1. Runtime failure does not silently switch to AOT.

The generated ELF contains immutable operation records and type-specific encoding
recipes produced by the existing native emitter. On first execution its runtime
compiler emits each operation, relocates frame operands and literals, changes the
mapping from RW to RX, and publishes the code pointer. It reuses that code with the
current caller frame on later executions, including recursion and indirect calls.
The cache retains no frame address or input values. Infrastructure calls do not
consume source frames; the 4096 source-frame limit and error locations are preserved.
JIT mappings remain until process exit. No external compiler or runtime process is
required, and no RWX code mapping is created.

`--jit-report` embeds optional runtime counters. On normal entry-function return,
three lines go to stderr: compilations, cache hits and total compile nanoseconds.
The timer covers runtime allocation, encoding/relocation and RX protection, and
its measurement includes timer overhead. `build` embeds reporting in the executable;
`run` and successful `test` cases display the runtime output. Error/panic exits do
not print the final report. Reporting adds overhead to cache-hit measurements.

The experimental JIT establishes real runtime generation and reuse. It does not specialize on runtime
values or promise an improvement over optimized AOT. Loop fusion, SIMD, closures,
background compilation, eviction, cross-process caches and other targets remain
outside its scope. Run [benchmarks/jit_benchmark.py](https://github.com/skystarry-team/Xen/blob/main/benchmarks/jit_benchmark.py)
to record first-compile and warm execution costs on your machine.
