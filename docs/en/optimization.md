# Basic native optimization

`build`, `run`, and `test` accept `--opt=off|basic`. The default is `off`.
`check` always checks the original source and accepts no optimization flags.

```sh
xen run calculation.xen --opt=basic
xen build calculation.xen --opt=basic --opt-report -o calculation
xen test std.string --opt=basic
```

`--opt-report` requires `--opt=basic`. It writes typed region inputs/outputs,
source locations, scope/block boundaries, split reasons, transformation counts,
and the number of fused calls to stderr. Put compiler options before `run`'s
`--`; everything after that delimiter is a program argument.

Basic optimization uses the existing Semantic IR and native backend. Source
checking and cleanup happen first. It then expands eligible leaves, optimizes
calculation regions, and checks types, initialization, storage lifetime and
borrows again without inserting cleanup a second time. Optimization errors are
diagnostics; there is no automatic fallback that hides them.

Calculation regions support fixed-width integers and Bool: constant folding,
scalar copy propagation, repeated computation elimination and unused safe
temporary removal. Runtime inputs can participate. Wrapping and signed/unsigned
comparisons retain their usual meaning. Named local stores, address-taken locals
and scalar lifetime/drop bookkeeping remain. Definition versions prevent reuse
across reassignment or storage termination. Regions stop at CFG and lexical scope
boundaries, calls, references/projections, memory access, allocation, managed
clone/drop, syscalls and potentially failing operations. Float arithmetic,
division, remainder and checked conversions retain their original operations.
Ownership call summaries do not establish optimization purity.

Fusion expands direct calls to straight-line leaves with concrete integer/Bool
parameters and results, one block and one scope, and at most 32 calculation,
acquisition or store operations. Calls, references, aggregates, memory effects
and fallible operations disqualify a leaf. The effective call-site mode must
match. Each caller has limits of 256 additional IR operations and 256 additional
scalar slot bytes, including backend slot padding (each scalar slot is at least
8 bytes). Candidate decisions and expansion happen once, before calculation
optimization. Exceeding a limit leaves the ordinary call in place.

Arguments are already evaluated and copied into fresh parameter storage;
source spans and existing IDs survive. Return storage ends after copying the
result. Original functions remain available as function values and for indirect
calls. Fused calls preserve logical entry/exit markers, including unused results.
Entry checks the 4096 active function frame limit at the original call location,
and exit decrements the depth after transferring the result.

This AOT groundwork is reused by the experimental [scalar scope runtime JIT](jit.md),
which adds execution memory, operand relocation, caller-frame ABI and a bounded
process cache. Loop fusion, SIMD, closures and runtime specialization are unsupported.
