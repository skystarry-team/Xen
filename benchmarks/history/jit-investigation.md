# Historical JIT investigation

The experimental runtime JIT and its CLI/syntax were removed in favor of scoped
AOT optimization. The measurements below describe the previous implementation;
its commands, defaults and artifact paths are historical.

# JIT performance investigation — 2026-10-13

Large scalar calculations exposed instruction-cache conflicts because every
JIT region started at the same offset in its own page. Distributing entry offsets
reduced the measured 64-stage sample's hardware cycles from 4.79 billion to
1.64 billion, compared with 1.55 billion for AOT. This change also removes
redundant frame setup and expands the benchmark to distinguish small-call,
large-calculation and loop costs. A consistent advantage over AOT is still
unproven, and compiling a complete loop remains further work.

Issue [#2](https://github.com/skystarry-team/Xen/issues/2) established runtime
encoding and caching. It did not introduce runtime specialization or loop
compilation. Scalar JIT regions encode the same operations as AOT, so dispatch
cost must be recovered by a future optimization to deliver a consistent gain.
The previously documented 5.8% slowdown was one observation, not a universal
ratio. Re-running the old benchmark even produced a small apparent speedup.

## Evidence and first change

The baseline compiler was built from `29ede6b3e5dda3e8bba4ff08458639924f28a25e`
on Linux x86-64, kernel `6.8.0-146-generic`, Intel i5-1135G7. The observations
below use Valgrind 3.22.0 Callgrind with branch simulation, 200,000 timed
iterations, a separate priming call and reporting disabled. Counts include
startup, compilation and output, not only the timed loop. All calculation checksums
match independent closed-form integer oracles. Use the benchmark's raw JSON
and compiler/source hashes when repeating the measurement.

| Workload, optimizer | AOT instructions | Original JIT | After frame removal | JIT entries per timed iteration (approximately) |
| --- | ---: | ---: | ---: | ---: |
| Short scalar call, off | 30,201,257 | 32,201,976 | 31,401,971 | 1 |
| Short scalar call, basic | 22,201,214 | 24,201,531 | 23,401,517 | 1 |
| Longer scalar calculation, off | 47,001,400 | 49,003,039 | 48,203,034 | 1 |
| Longer scalar calculation, basic | 34,201,315 | 36,202,221 | 35,402,207 | 1 |
| Loop in JIT scope, off | 19,801,997 | 23,803,290 | 22,203,215 | 2 |
| Loop in JIT scope, basic | 11,801,685 | 15,802,470 | 14,202,404 | 2 |

The change removes four instructions on each region entry:
`mov rdi,rbp` at the call site and `push rbp; mov rbp,rdi; pop rbp` in the
generated region. Scalar recipes already address the live caller frame through
`rbp`, leave that register unchanged and balance temporary pushes/pops. Generated
regions now need only a trailing `ret`. Page-size accounting changes from six
wrapper bytes to one. Runtime compilation still preserves callee-saved registers,
publishes code only after RX protection, and reports failures without runtime AOT
fallback. Existing cache, recursion, signedness, resource and permission tests
remain applicable; additional tests retain caller-local values through recursive
reuse and execute a 10,000-iteration scalar loop.

The short optimized sample's additional executed instructions fall from about
10 to 6 per region entry, a roughly 40% reduction in this dispatch overhead.
This is not a 40% runtime improvement: the whole JIT process executes about
3.3% fewer instructions, and still about 5.4% more than AOT in this sample.
Cache lookup, a conditional branch and an indirect call remain on every entry.

The user also supplied hardware `perf stat` results for the original short
200,000-iteration fixture: AOT executed 22,201,186 instructions and JIT about
24,201,400. Only tens of branch misses were observed. Hardware cycles were
6.59 million for AOT and 6.93/8.00 million in two JIT batches; elapsed times
varied substantially. Those separate batches confirm the instruction overhead,
but do not establish a stable runtime percentage. No post-change hardware
counter claim is made for this short fixture. Callgrind's branch simulation does not count the
same event set as hardware `branches:u`.

## Loop work indicated by the measurements

`#scope[jit] { while ... }` currently compiles the condition and body as separate
scalar regions. The optimized loop benchmark compiled two regions and reported
400,014 cache hits, plus two compilations. The priming call accounts for seven
iterations and its final condition, and the timed loop accounts for 200,000
iterations and its final condition: 400,016 entries in total. A JIT annotation
around a loop therefore does not make one compiled loop: region dispatch still
happens approximately twice per iteration.

After resolving code-placement costs described below, the next useful JIT step
is a bounded loop region containing its condition, body and backedge.
That requires branch recipes/relocations, CFG eligibility
and code-size budgets while retaining checked Semantic IR, lexical/effect/borrow
boundaries, cleanup and source-frame accounting. Initial candidates should be
scalar loops with known internal control flow and no effects or address-taken
storage, with differential tests for zero iterations, mutation, wrapping,
termination and budget rejection. This change does not implement that step.

Adjacent-loop fusion is a separate transformation: combining independent loops
requires dependency and iteration-domain analysis and preservation of effect
order. The current observations do not establish a need for adjacent-loop
fusion. Removing repeated region entry from a single loop is the directly
supported target; existing bounded leaf-function fusion does neither operation.

## Larger workload and code placement

The user's request to test substantial computation exposed another bottleneck.
The `scalar_large` workload performs 64 dependent `y=y*3+x+1` stages per call;
`loop_kernel` performs 16 stages in each loop iteration. Both use wrapping
integers and runtime inputs. Their oracles use an affine transform and fast
composition independently of Xen, so even large iteration counts can be
verified without mirroring the execution loop in the benchmark driver.

With the frame-only optimization, `scalar_large` compiled 17 regions with
`--opt=off`, or 13 with `basic`. At 2 million iterations, nine paired native
runs pinned to CPU 2 measured a JIT/AOT warm ratio near 3.3, even though the
executed instruction count was only about 3–4% higher. The 16-stage loop used
6/5 entries per iteration and was much closer to AOT. These are synthetic
scalar workloads, not representative claims about whole applications.

The host's L1 instruction cache has 32 KiB, 8 ways, 64-byte lines and 64 sets.
With all JIT entries at page offset zero, Callgrind's corresponding cache
model reported about 35.8 million L1 instruction misses for `scalar_large/basic`
at 200,000 iterations; AOT reported 207. That supports conflict misses as a
major additional cost. This is simulated evidence, not a hardware cache-miss
measurement, and Callgrind does not model instruction TLB costs.

The placement change keeps one 4096-byte mapping per region and chooses a
64-byte-aligned entry offset from positions where the complete code fits.
A stride coprime to the available position count walks those positions broadly.
Full-page regions remain valid at offset zero. The descriptor retains operation
count and code size, adding an entry-offset field before operation records.
The runtime keeps mapping base and executable entry separately: `mprotect` and
failure `munmap` receive the page base, and only a successful RX transition
publishes the executable entry. Mapping count, RW-to-RX policy and region budgets
are unchanged. No RX page is reopened or shared with another compiled region.

Placement tests cover alignment, bounds, full-page entries and position coverage.
Execution tests exercise long multi-region calculations at changing inputs and
indirect calls. The failure fixture skips the first emitted region, so a nonzero
entry is used; seccomp verifies that cleanup `munmap` receives a page-aligned
base rather than an interior executable address.

After placement, the same 200,000-iteration cache simulation measured:

| Workload, optimizer | AOT L1 instruction misses | JIT after placement | JIT entries per iteration (approximately) |
| --- | ---: | ---: | ---: |
| 64-stage scalar, off | 249 | 291 | 17 |
| 64-stage scalar, basic | 207 | 238 | 13 |
| 16-stage loop body, off | 101 | 118 | 6 |
| 16-stage loop body, basic | 89 | 103 | 5 |

Instruction counts and region counts remain effectively unchanged by placement;
small instruction-count differences come from first compilation and formatting
timer output. The cache geometry is stored in the profile JSON. Native timings
remain observations rather than regression thresholds.

The user supplied hardware measurements for the 2-million-iteration
`scalar_large/basic` binaries, pinned to CPU 2 with seven `perf stat` repetitions:

| Hardware metric | AOT | JIT after frame removal | JIT after placement |
| --- | ---: | ---: | ---: |
| User cycles | 1,547,310,286 | 4,788,736,158 | 1,644,822,286 |
| User instructions | 4,668,189,010 | 4,824,205,340 | 4,824,204,329 |
| `icache_64b.iftag_miss:u` | 359,413 | 357,752,887 | 558,706 |
| `icache_data.stalls:u` | 255,136 | 1,671,816 | 337,956 |
| Elapsed seconds | 0.5110 ± 0.0403 | 2.005 ± 0.287 | 0.54390 ± 0.00362 |

These hardware batches confirm the cache-placement improvement: JIT cycles fall
about 66% and cache misses about 640-fold, with the same calculation and almost
the same dynamic instruction count. They do not demonstrate a general JIT win
over AOT. Runs were separate batches on a shared machine; AOT and pre-placement
elapsed-time dispersion was substantial. The benchmark's native paired runs also
showed residual cost: the unoptimized 64-stage case remained roughly 1.5 times
the AOT time after placement. Some final native runs may have overlapped an
external hardware profiler, so that residual ratio is tentative and their
absolute times are not used to quantify the before/after improvement.
Eliminating the measured instruction-cache conflict
does not eliminate every JIT cost.

At that checkpoint, loop compilation remained the next step. Adjacent-loop
fusion would not address the code-placement conflict observed here.

## Bounded loop compilation

The subsequent change compiles a small loop's header condition, straight-line
scalar body and backedge into one cached region. The body has no external entry;
its Jump chain returns to the header, and the header's false target is the only
exit. Selection checks every operation's scope and existing calculation-chunk
safety, including address-taken locals. Child scopes with identical effective
modes are allowed. Internal branches, effects, mode changes and oversized loops
retain the ordinary CFG and scalar-region path. An eligible inner loop can compile
independently when its outer loop cannot.

The existing bounds remain: 32 encoding records including condition/backedge,
4096 bytes including RET, and 64 cached mappings process-wide. Selection does not
remove any block until encoding size and cache reservation succeed. Whole-loop
slots are reserved before scalar regions in the same function. New condition and
Jump recipes use structural Relative32 patches; only four bytes are copied from
the record's immediate field. Targets are record boundaries or the final RET,
with displacements computed from exact recipe lengths. Entry placement, caller
frame reuse, RW-to-RX protection and page-base failure cleanup are preserved.
This is bounded loop compilation; it does not fuse adjacent source loops.

The baseline compiler for this stage already includes the earlier frame and
cache-placement fixes. Its SHA-256 is
`113da312cd133cc2094e61647f880b44a71764db115d8ec86ac3394113bf0f41`.
Both compiler versions were measured on CPU 2 without concurrent tests or
profilers during native timing. Native runs used two million iterations, seven
baseline repetitions for the original cases, nine for the added bounded case,
and nine repetitions after the change. The table reports median *paired*
JIT/AOT warm-time ratios, not a ratio of medians or a universal speedup:

| Workload, optimizer | Before loop compilation | After loop compilation | After compilations / hits |
| --- | ---: | ---: | ---: |
| Small scalar loop, off | 1.119 | 0.993 | 1 / 1 |
| Small scalar loop, basic | 1.202 | 1.031 | 1 / 1 |
| One-stage bounded loop, off | 1.181 | 1.005 | 1 / 1 |
| One-stage bounded loop, basic | 1.170 | 1.038 | 1 / 1 |
| 16-stage loop, off | 1.048 | 1.056 | 6 / 12,000,038 |
| 16-stage loop, basic | 1.035 | 1.037 | 5 / 10,000,032 |

The two supported cases previously made 4,000,016 region entries including
priming. They now make two: one first call and one warm call, regardless of the
iterations inside each compiled loop. New benchmark JSON includes `region_entries`
to make this explicit. The saved `after-native` JSON predates that field; its
entry counts are the sum of compilations and cache hits. `after-profile` includes
the field. The retained 16-stage case exceeds the record budget
and keeps its previous region counts. Native timing remains sensitive to CPU
frequency and shared-machine activity, even with fixed affinity.

Separate Callgrind cache/branch simulations used 200,000 iterations and checked
the same independent checksums:

| Workload, optimizer | AOT instructions | JIT before | JIT after | JIT indirect branches before → after |
| --- | ---: | ---: | ---: | ---: |
| Small scalar loop, off | 19,802,009 | 22,203,231 | 19,803,263 | 400,016 → 2 |
| Small scalar loop, basic | 11,801,697 | 14,202,420 | 11,802,414 | 400,016 → 2 |
| One-stage bounded loop, off | 17,001,956 | 19,403,052 | 17,003,074 | 400,016 → 2 |
| One-stage bounded loop, basic | 13,001,784 | 15,402,615 | 13,002,617 | 400,016 → 2 |

Remaining instruction differences cover first compilation and process output;
the profiles are whole-process counts, not hardware counters or warm-only
measurements. They demonstrate removal of repeated JIT dispatch for supported
loops, not a general performance advantage over AOT.

Validation includes 42 AOT/JIT differential cases under both optimization
levels; 0/1/many iterations, changing Bool conditions, signed/unsigned wrapping,
recursive frames, indirect calls and nonzero entry offsets; unsupported effects,
mode changes and oversized bodies; and the 64-region cap. IR checks cover 32/33
record boundaries, external body predecessors, non-header cycles, addressed
conditions and body-before-header block numbering. A checked IR execution fixture
splits the body into two blocks, places both before the header, and compares AOT
and JIT output/counters under both optimizers with 0, 63 and 64 earlier cache
reservations. It exercises accepted nonzero-offset code and budget rejection
without consuming the fallback body's labels. Failed loop RX protection
is checked with seccomp, including page-base munmap. `dune runtest` and 40 mixed
generated programs also passed.

Local artifacts for this stage are under `/tmp/xen-jit-loops/`: the saved baseline
compiler, `before-native`, `bounded-before-native`, `after-native`,
`before-profile` and `after-profile`, each retaining sources, binaries and JSON.
For hardware verification of the supported loop, run these on the same idle CPU:

```sh
sudo perf stat -r 7 -e cycles:u,instructions:u,branches:u,branch-misses:u -- taskset -c 2 /tmp/xen-jit-loops/bounded-before-native/loop_bounded-basic-on
sudo perf stat -r 7 -e cycles:u,instructions:u,branches:u,branch-misses:u -- taskset -c 2 /tmp/xen-jit-loops/after-native/loop_bounded-basic-on
sudo perf stat -r 7 -e cycles:u,instructions:u,branches:u,branch-misses:u -- taskset -c 2 /tmp/xen-jit-loops/after-native/loop_bounded-basic-off
```

## Reproduction

Build and save the baseline compiler before modifying the backend, then use
separate output directories with the same benchmark version and arguments:

```sh
dune build @release
cp compiler/dist/xen /tmp/xen-before
# After changing and rebuilding the backend:
python3 benchmarks/jit_benchmark.py --xen /tmp/xen-before --jit-mode on --iterations 200000 --repetitions 3 --build-repetitions 1 --callgrind --output-dir /tmp/jit-before
python3 benchmarks/jit_benchmark.py --jit-mode on --iterations 200000 --repetitions 3 --build-repetitions 1 --callgrind --output-dir /tmp/jit-after
```

Use native longer runs and paired distributions to assess time; Valgrind's
execution times are not native-performance measurements. CPU affinity does
not fix frequency scaling, thermal throttling or competing system activity.
See [README.md](README.md) for native and hardware profiling commands.

## Execution-guided tier and loop-invariant motion (2026-10-13)

The earlier steps removed JIT overhead but produced essentially the same
operations as AOT. `--jit=adaptive` now starts with AOT, collects backedge
feedback only for candidates with movable invariant arithmetic, and promotes
when both aggregate work and the current invocation's trip count qualify.
The transformation is statically proven non-SSA LICM; runtime feedback selects
where to apply it. This is not runtime-value or branch specialization.
`on` remains the eager reference/default and `off` the same-source AOT baseline.

Only single-definition scalar temporary Eval/Acquire operations move. The
definition must precede every use, the destination cannot escape the loop, and
inputs must be loop invariant or already moved. User assignments and effects
remain in place. The prefix reads current-frame inputs on each JIT invocation,
and generated backedges skip it. The AOT CFG is retained for cold execution and
fallback. Provisional policy: current invocation >=256 completed iterations,
and aggregate backedges >=max(1024, ceil(8192 / moved arithmetic operations)).
Cached entries still require 256 iterations in each invocation. Invocations with at most 256 completed iterations finish without JIT dispatch,
even when aggregate heat is saturated; the thresholds are
work estimates, not measured profitability or autotuning.

Candidate metadata is distinct from the runtime budget: the first 64 successful
promotions consume code pages, regardless of source order. mmap/mprotect failure
or budget exhaustion disables the candidate and resumes AOT without retries;
failed protection releases the RW page. The 32-record/4 KiB region limits remain.
Adaptive mode uses AOT for unsupported/oversized loops and scalar scopes.

Native runs compared off/on/adaptive on CPU 2, two million iterations and nine
repetitions, reporting disabled. Every process measures three phases: a short
compute(7), a long transition including any promotion, and a repeated long run.
Seven iterations do not prime adaptive code. All phase checksums use independent
closed forms. No tests or profilers ran concurrently during native measurements.
The following are medians of paired repeated-execution ratios; the transition
column is a ratio of phase medians and includes compilation:

| Workload, optimizer | Eager / AOT repeated | Adaptive / AOT repeated | Adaptive / AOT transition | Adaptive compilations / hits |
| --- | ---: | ---: | ---: | ---: |
| scalar_large, off | 1.509 | 1.008 | 1.007 | 0 / 0 |
| scalar_large, basic | 1.272 | 0.990 | 0.997 | 0 / 0 |
| loop_bounded, off | 1.021 | 1.012 | 0.992 | 0 / 0 |
| loop_bounded, basic | 1.022 | 0.992 | 1.001 | 0 / 0 |
| loop_kernel, off | 1.036 | 0.986 | 1.023 | 0 / 0 |
| loop_kernel, basic | 1.044 | 0.997 | 0.974 | 0 / 0 |
| loop_invariant, off | 0.996 | 0.706 | 0.709 | 1 / 1 |
| loop_invariant, basic | 1.015 | 0.725 | 0.737 | 1 / 1 |

All six pre-existing workloads selected AOT with zero adaptive profiling,
compilation and mapping counters. Their adaptive/AOT paired medians range
0.986–1.020 across optimizer levels; those small time differences are layout/noise,
not evidence of an adaptive transformation. The new invariant workload computes
`weight=n*n+3` within every iteration. Adaptive moves seven encoding records
with opt=off and four with basic, including supporting copies/literals, and
saturates its aggregate counter at 4096. It compiles once during transition and
reuses once. Short-call results remain AOT.

Separate Callgrind cache/branch simulations at 200,000 iterations cover all three
phases, startup, compilation and output, not a warm-only hardware profile:

| Invariant workload, optimizer | AOT instructions | Eager instructions | Adaptive instructions |
| --- | ---: | ---: | ---: |
| off | 42,802,750 | 42,804,123 | 29,422,071 |
| basic | 30,002,478 | 30,003,395 | 21,369,171 |

This removes about 31%/29% of executed instructions, unlike the prior dispatch
fix alone. Simulated L1I misses remain small (AOT 67/63, adaptive 84/77).
Native repeated times fall about 29%/28% in this sample. These are supported
invariant-arithmetic observations, not a general JIT advantage. Profiling costs
remain for short invocations of eligible candidates; no measured version
competition, value guards, branch specialization, recompilation or eviction is
implemented yet.

Validation: release build and dune runtest; 42 three-way AOT/eager/adaptive
integration cases at both optimizer levels; boundary 0/1/255/256/4095/4096/4097
and long trips with independent checksum; repeated short calls and inner-loop
invocations; changing arguments, I8 wrapping, recursive frames; non-SSA
multiple writes, outside uses and read-before-definition rejection; checked
reordered two-block CFG execution; 64 unexecuted candidates preceding a hot
candidate; 65 hot candidates hitting the runtime mapping cap; seccomp-denied
mmap and mprotect followed by correct AOT output, permanent disable and page-base
cleanup. The CLI test runner passes adaptive options through the backend contract;
unsupported ARM64 requests and check flags remain rejected. The executable
example is `examples/jit_adaptive.xen`.

Initial all-seven-workload observations remain in
`/tmp/xen-jit-adaptive/native/results.json`. The final header replay guard and
runtime placement change affect two adaptive invariant binaries; those were
remeasured in `final-invariant-native` and `final-invariant-profile`, and their
final values are used above. The other 40 original timed binaries were rebuilt
and byte-compared unchanged. The final measured compiler is saved as
`/tmp/xen-jit-adaptive/xen-final-measured`, SHA-256
`902a83c5f8f1372c3ecb00513011642c9ba7b22710706f309d3d2c62e33dc629`.
Old stage artifacts retain their original two-phase protocol; new JSON nests
ratios/reports by JIT mode and records transition separately.

```sh
python3 benchmarks/jit_benchmark.py --cpu 2 --output-dir /tmp/xen-jit-adaptive/native
python3 benchmarks/jit_benchmark.py --case loop_invariant --iterations 200000 --repetitions 1 --build-repetitions 1 --cpu 2 --callgrind --output-dir /tmp/xen-jit-adaptive/profile
sudo perf stat -r 7 -e cycles:u,instructions:u,branches:u,branch-misses:u -- taskset -c 2 /tmp/xen-jit-adaptive/final-invariant-native/loop_invariant-basic-off
sudo perf stat -r 7 -e cycles:u,instructions:u,branches:u,branch-misses:u -- taskset -c 2 /tmp/xen-jit-adaptive/final-invariant-native/loop_invariant-basic-adaptive
```

### Final review corrections and short eligible calls

Adaptive dispatch executes the AOT header/condition before entering generated
code, which includes that header again. The selector now rejects stateful
headers: replay may only define private, uniquely-written temporaries in
forward dependency order. A checked CFG fixture moves the induction update
into the header; at n=20000 its independently checked output is
7,999,800,049,997. Both optimizers preserve that output with zero promotions.

Code placement now uses the successful runtime mapping ordinal modulo available
cache-line positions. Candidate IDs remain cache identities only. A live-child
integration test derives slots from the actual first RX page, promotes candidate
IDs 0/slots/2*slots (which collided under static placement), reads cached RX
pointers from the ELF data segment, and observes offsets 0/64/128 under both
optimizers. It also checks RX without RWX. A child-only seccomp filter installed
after one successful promotion denies the next protection operation, exercising
AOT completion, permanent disable and page-base cleanup for the second mapping's
nonzero entry offset. Release, dune runtest and 42 three-way integration cases
with these additional controls pass.

Repeated short *eligible* calls expose costs hidden by the six uninstrumented
legacy workloads. Native measurements used CPU 2, 2000 calls per long phase,
nine repetitions, reports disabled; independent Callgrind profiles used 100
calls per long phase. There are two long phases plus the short compute(7) call.
The instruction totals include startup/compilation/output and must not be scaled
as native warm-only event counts. Profiles and native runs ran separately.

| Trips per call, optimizer | Adaptive / AOT repeated (paired median) | AOT profile instructions | Adaptive profile instructions | Native compilations / hits |
| --- | ---: | ---: | ---: | ---: |
| 255, off | 1.059 | 5,486,536 | 5,950,097 | 0 / 0 |
| 255, basic | 1.095 | 3,851,072 | 4,314,633 | 0 / 0 |
| 257, off | 1.085 | 5,529,336 | 6,001,117 | 1 / 3984 |
| 257, basic | 1.057 | 3,881,072 | 4,351,657 | 1 / 3984 |
| 1000, off | 0.802 | 21,429,590 | 16,997,663 | 1 / 3995 |
| 1000, basic | 0.823 | 15,026,108 | 12,340,495 | 1 / 3995 |
| 4097, off | 0.756 | 87,705,408 | 62,256,989 | 1 / 3999 |
| 4097, basic | 0.744 | 61,481,144 | 45,201,473 | 1 / 3999 |

At 255 trips, JIT never activates but profiling still costs about 6–10% time.
At 257, aggregate heat eventually triggers JIT after 256 AOT iterations, leaving
one iteration for optimized code; profiling and dispatch cost about 6–9% time.
1000/4097-trip calls benefit in this sample. This disproves treating the current
threshold as a profitability decision. It is a provisional execution-work gate;
a future value/branch or sampled version-cost policy is needed for better choices.
The large-loop improvement is the effect of applying LICM currently absent from
shared AOT optimization, not evidence of runtime-value specialization or automatic
version selection. Even a statically safe transformation can be a poor execution
choice for a given call shape.

Short-call sources/binaries/results are under `short-TRIPS-native` and
`short-TRIPS-profile` in `/tmp/xen-jit-adaptive`.

```sh
python3 benchmarks/jit_benchmark.py --case loop_invariant --loop-trip-count 257 --iterations 2000 --repetitions 9 --build-repetitions 1 --cpu 2 --output-dir /tmp/xen-jit-short-257
python3 benchmarks/jit_benchmark.py --case loop_invariant --loop-trip-count 257 --iterations 100 --repetitions 1 --build-repetitions 1 --cpu 2 --callgrind --output-dir /tmp/xen-jit-short-257-profile
```

The final review corrected entry normalization without rerunning timers: scalar
compute(7) is one call, so its denominator is 2*iterations+1; loop cases count
2*iterations*trip_count+7 actual inner iterations. Retained results.json derived
fields were updated while raw counts/timings stayed unchanged; scalar_call/basic
eager now normalizes exactly to 1.0. Original stdout logs retain their initial
derived-field snapshots.
