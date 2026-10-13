# Scoped AOT optimization

`#scope[opt]` marks the code to optimize ahead of time. `build`, `run` and `test`
use `--opt=basic` by default; unmarked operations and original callees are left
unchanged. `--opt=off` disables the transformations. Global optimization is not
exposed by the CLI, and global/function `opt` modes are rejected.

```xen
fn calculate(n: Int, scale: Int) -> Int {
    let mut i = 0;
    let mut total = 0;
    #scope[opt] {
        while i < n {
            let weight = scale * scale + 3;
            total = total + weight + i;
            i = i + 1;
        }
    }
    return total;
}
fn main() { println(calculate(10000, 7)); }
```

```sh
xen run examples/opt_loops.xen
xen run examples/opt_loops.xen --opt-report
xen run examples/opt_loops.xen --opt=off
```

The original source is checked, lowered and cleaned up first. Eligible direct
leaf calls inside marked scopes are expanded, eligible adjacent loops are fused, loop-invariant code
motion runs, scalar regions are optimized, and the result is checked again for
types, initialization, storage lifetimes and borrows without inserting cleanup
again. Both Linux backends use this shared IR. Optimization errors are reported;
there is no fallback that hides invalid transformed IR.

Marked scalar regions support fixed-width integers and Bool: constant folding,
copy propagation, repeated-expression elimination and unused safe temporary
removal. Runtime inputs can participate. Integer wrapping and signed/unsigned
comparison semantics are preserved. Nested ordinary blocks inherit the hint.
Regions stop at CFG/lexical boundaries, calls, borrows, projections, memory,
allocation, managed clone/drop, syscalls and potentially failing operations.
Float, division, remainder and checked conversions are not transformed.
Ownership summaries are not proof of optimization purity.

Leaf expansion accepts one-block, one-scope integer/Bool leaves with at most 32
calculation/acquisition/store operations and no effects or fallible operations.
Only calls inside `opt` are expanded; the callee's original body is retained.
Reference/raw-memory capabilities must match, but `opt` is an optimization hint
and grants no capabilities. Expansion preserves source locations and logical
call-depth checks, including unused results. Each caller has budgets of 256 extra
IR operations and 256 extra scalar-slot bytes, including padding.

Loop-invariant code motion accepts a marked Bool header, a straight-line scalar
body (possibly several exclusively entered blocks), a backedge and one exit.
It rejects internal branches, nested loops in the selected body, effects,
address-taken locals and capability changes. An eligible inner loop can still
be optimized independently. Single-definition private temporary expressions
must precede every use and depend only on values unchanged by the loop or earlier
invariant definitions. Named stores and loop-carried definitions stay in place.

Invariant arithmetic and its dependencies are computed in a new preheader using
fresh scalar storage. Original definitions read those cached values, and scalar
copy propagation removes redundant temporary work. Original source storage and
cleanup remain; the new storage ends at the unique exit. Only pure, nontrapping
operations may run before an immediately false condition, preserving zero-trip
semantics. Extra invariant storage is limited to 32 scalar slots per function;
there is no runtime encoding-record or executable-page limit.

## Region analysis and loop fusion

An analysis overlay records CFG predecessors, loop headers/bodies/backedges/exits,
scalar reads/writes and addressed locals. Aliases identify the function, lexical
scope path and region ordinal. Block-array order is never used as execution order.
Fusion planning follows leaf expansion and precedes LICM and scalar optimization.
This first bounded implementation draws on MLIR's
[structure-preserving design](https://mlir.llvm.org/docs/Rationale/RationaleLinalgDialect/)
and TVM's [graph partitioning](https://github.com/apache/tvm/blob/main/docs/arch/fusion.rst);
it adds no external compiler dependency.

Two adjacent integer loops in the same lexical `opt` scope may fuse when they have
equal constant initial values, invariant upper bounds, `<` conditions and unit
increments. They must have separate induction locals of the same integer type,
straight-line scalar bodies, and no cross-loop read/write or write/write dependence.
Only scalar temporary cleanup may separate them.
The skipped condition block must contain only single-definition private temporary
computations, with no reads of their previous values or writes to named locals.
External entries into the second header or connecting blocks are rejected.
A function may fuse at most 32 pairs. Calls, borrows, projections, managed storage, potentially failing operations,
internal branches and capability changes remain barriers. Both final induction
values and original storage cleanup are preserved; the second loop's repeated
condition check is removed. This does not implement array producer-consumer fusion,
intermediate-buffer elimination or SIMD.

```sh
xen run examples/opt_fusion.xen --opt-report
xen run examples/opt_fusion.xen --opt=off
```

## Exact prefix cache

`--opt-cache=<directory>` persists scalar forward analysis/rewrites between compiler
processes. Default invocations create no disk cache. It is accepted by `build`,
`run` and `test` with `basic`; `check` and `off` reject it as invalid usage.

```sh
xen run examples/opt_fusion.xen --opt-cache=.xen-opt-cache --opt-report
# Repeat the command to observe cache=hit.
```

Aliases are tracing names, not validity proofs. Entries directly compare their
validated parent prefix, complete current input and alias. Digests locate files;
collisions allocate separate entries. A missing, broken or changed parent forces
the dependent suffix to rebuild. Equal type/effect contracts never establish a
hit. Lineage currently follows a conservative cumulative CFG traversal, so even
independent downstream branches may be invalidated. Changes to local/scope or CFG
metadata can invalidate the complete function context; input-value changes with
unchanged metadata can preserve earlier prefixes.

Context includes optimizer options, the compiler executable fingerprint, CLI target,
aggregate layouts and original callee contents/IDs. Source checking always runs.
Only safe scalar forward rewrites are cached. Backward liveness/DCE, loop analysis
and fusion planning, final IR revalidation and backend generation run every time.
A suffix that newly observes a prefix temporary therefore cannot reuse old DCE.
Cache records are published only after final revalidation succeeds.
Publication rechecks the parent record. If another writer occupies a reserved
file slot, its complete contents must match. A conflicting parent prevents
publication of its descendants and aliases.

Records use a checksummed text envelope with a 1 MiB read limit. No OCaml objects
are unmarshalled from disk. Malformed records, checksum failures and unknown scalar
rewrites cause misses. Unavailable cache I/O falls back to ordinary analysis.
Historical entries are retained; unused cache directories may be removed.

`--opt-report` writes typed region inputs/outputs, split reasons, counts, leaf
expansions, `opt loop ... hoisted=...`, `opt loop-fusion ... fused|split`, and
`opt prefix ... alias=... parent=... cache=hit|miss reason=...` to stderr.
Put options before `run`'s `--` delimiter.

Array/tiled fusion, guarded version generation and loop unswitching are future
work. They require loop-dependence/effect analysis and code-size/profitability
budgets; adding a branch cannot make an unknown effect safe. SIMD and runtime
specialization are not implemented. The experimental runtime JIT, `--jit` CLI
options and `jit` mode spelling have been removed; migrate marked source to
`#scope[opt]` and remove the old flags.
