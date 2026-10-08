#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Whole-language QuickCheck runner for Xen — full feature combinatorial sweep."""
from __future__ import annotations

import argparse
import random
import sys
import traceback
import unittest
from collections import Counter
from pathlib import Path

from gen import (
    EMITTERS,
    RNG,
    all_feature_pairs,
    generate_contextual_probe,
    generate_illtyped,
    generate_kitchen_sink,
    generate_mixed,
    generate_noise,
    generate_pair_sweep,
)
from grammar import Program
from props import (
    XEN,
    check_program,
    prop_contextual_probe,
    prop_illtyped_diagnostics,
    prop_mixed_runs,
    prop_nocrash,
    run_program,
)
from regressions import KNOWN_ASYMMETRY, KNOWN_ERRORS, KNOWN_RUNTIME_REGRESSIONS
from semantic import run_semantic


DEPTHS = {
    "smoke": 40,
    "standard": 200,
    "deep": 1000,
    "massive": 5000,
}


def run_regress() -> int:
    print(f"(xen={XEN})")
    print("=== fixed diagnostic regressions ===")
    failed = 0
    for case in KNOWN_ERRORS:
        prog = Program(
            files={"case.xen": case.source},
            entry="case.xen",
            expected_stdout="",
            features=frozenset(),
            expect_check_fail=case.expected_substring,
        )
        try:
            prop_illtyped_diagnostics(prog)
            print(f"  OK  {case.id}")
        except AssertionError as err:
            failed += 1
            print(f"  FAIL {case.id}: {err}")
    print("=== asymmetry pins (currently expected to FAIL check) ===")
    for case in KNOWN_ASYMMETRY:
        result = check_program(
            Program(
                files={"case.xen": case.source},
                entry="case.xen",
                expected_stdout="",
                features=frozenset(),
            )
        )
        if result.status == 1 and case.expected_substring in result.stderr:
            print(f"  still broken (pinned)  {case.id}")
        elif result.status == 0:
            print(f"  FIXED! now typechecks  {case.id}")
        else:
            failed += 1
            print(f"  unexpected diagnostic  {case.id}: {result.stderr!r}")
    print("=== fixed runtime regressions ===")
    for case in KNOWN_RUNTIME_REGRESSIONS:
        prog = Program(
            files={"case.xen": case.source},
            entry="case.xen",
            expected_stdout="",
            features=frozenset(),
        )
        result = run_program(prog)
        if result.status == 0 and result.stdout == case.expected_stdout and result.stderr == "":
            print(f"  OK  {case.id}")
        else:
            failed += 1
            print(
                f"  FAIL {case.id}: status={result.status} "
                f"stdout={result.stdout!r} stderr={result.stderr!r}"
            )
    return failed


def _save_bug(prog: Program, i: int, result_note: str = "") -> None:
    bug_dir = Path(__file__).resolve().parent / "found_bugs"
    bug_dir.mkdir(exist_ok=True)
    for name, src in prog.files.items():
        (bug_dir / f"case{i}_{name.replace('/', '_')}").write_text(src)
    (bug_dir / f"case{i}_expected.txt").write_text(prog.expected_stdout)
    if result_note:
        (bug_dir / f"case{i}_note.txt").write_text(result_note)


def run_mixed(n: int, seed: int | None, max_features: int) -> int:
    print(f"(xen={XEN})")
    print(
        f"=== mixed whole-program runs: {n} programs, max_features={max_features} ==="
    )
    print(f"    emitter pool ({len(EMITTERS)}): {sorted(EMITTERS)}")
    rng = RNG(seed)
    failed = 0
    feature_hits: Counter[str] = Counter()
    for i in range(n):
        prog = generate_mixed(rng, max_features=max_features)
        for f in prog.features:
            feature_hits[f] += 1
        try:
            prop_mixed_runs(prog)
        except AssertionError as err:
            failed += 1
            print(f"  FAIL case#{i} features={sorted(prog.features)} notes={prog.notes}")
            for name, src in prog.files.items():
                print(f"  --- {name}\n{src}")
            _save_bug(prog, i, str(err))
            traceback.print_exc()
            if failed >= 15:
                print("  (stopping after 15 failures)")
                break
    done = n if failed < 15 else i + 1
    print(f"  -> passed {done - failed}/{done}")
    print("  feature hits:", dict(sorted(feature_hits.items())))
    missing = sorted(set(EMITTERS) - set(feature_hits))
    if missing:
        print("  WARNING never emitted:", missing)
    return failed


def run_pairs(seed: int | None, rounds_per_pair: int = 2) -> int:
    """Systematic pairwise feature coverage — every emitter pair at least once."""
    print(f"(xen={XEN})")
    pairs = all_feature_pairs()
    print(
        f"=== pairwise feature sweep: {len(pairs)} pairs × {rounds_per_pair} ==="
    )
    rng = RNG(seed)
    failed = 0
    tested = 0
    for a, b in pairs:
        for r in range(rounds_per_pair):
            prog = generate_pair_sweep(rng, a, b)
            tested += 1
            try:
                prop_mixed_runs(prog)
            except AssertionError as err:
                failed += 1
                print(f"  FAIL pair ({a},{b}) round {r}")
                for name, src in prog.files.items():
                    print(f"  --- {name}\n{src}")
                _save_bug(prog, tested, f"pair {a}+{b}: {err}")
                traceback.print_exc()
                if failed >= 20:
                    print("  (stopping after 20 pair failures)")
                    print(f"  -> passed {tested - failed}/{tested}")
                    return failed
    print(f"  -> passed {tested - failed}/{tested}")
    return failed


def run_kitchen(n: int, seed: int | None) -> int:
    print(f"(xen={XEN})")
    print(f"=== kitchen-sink (almost all features per program): {n} ===")
    rng = RNG(seed)
    failed = 0
    for i in range(n):
        prog = generate_kitchen_sink(rng)
        try:
            prop_mixed_runs(prog)
        except AssertionError as err:
            failed += 1
            print(f"  FAIL kitchen#{i} features={sorted(prog.features)}")
            for name, src in prog.files.items():
                print(f"  --- {name}\n{src}")
            _save_bug(prog, 10_000 + i, str(err))
            traceback.print_exc()
            if failed >= 10:
                break
    print(f"  -> passed {n - failed}/{n if failed < 10 else 'partial'}")
    return failed


def run_illtyped(n: int, seed: int | None) -> int:
    print(f"=== ill-typed diagnostics: {n} draws ===")
    rng = RNG(seed)
    failed = 0
    for i in range(n):
        prog = generate_illtyped(rng)
        try:
            prop_illtyped_diagnostics(prog)
        except AssertionError as err:
            failed += 1
            print(f"  FAIL case#{i}: {err}")
            print(next(iter(prog.files.values())))
    print(f"  -> passed {n - failed}/{n}")
    return failed


def run_nocrash(n: int, seed: int | None) -> int:
    print(f"=== frontend no-crash noise: {n} draws ===")
    rng = RNG(seed)
    failed = 0
    for i in range(n):
        prog = generate_noise(rng)
        try:
            prop_nocrash(prog)
        except AssertionError as err:
            failed += 1
            print(f"  FAIL case#{i}: {err}")
            print(repr(next(iter(prog.files.values()))[:200]))
    print(f"  -> passed {n - failed}/{n}")
    return failed


def run_explore(trials: int, seed: int | None) -> int:
    print(f"=== contextual probe explore: {trials} trials ===")
    rng = RNG(seed)
    fails = []
    for _ in range(trials):
        prog = generate_contextual_probe(rng)
        info = prop_contextual_probe(prog)
        if not info["ok"]:
            fails.append(info)
    print(f"  typecheck failures: {len(fails)}/{trials}")
    notes = sorted({f["notes"] for f in fails})
    print(f"  unique note tags: {len(notes)}")
    for n in notes[:30]:
        print(f"    {n}")
    if fails:
        print("  sample failure:")
        print(fails[0]["source"])
        print(fails[0]["stderr"])
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--mode",
        choices=[
            "regress",
            "mixed",
            "pairs",
            "kitchen",
            "illtyped",
            "nocrash",
            "explore",
            "semantic",
            "sweep",  # regress + pairs + mixed + kitchen
            "all",
        ],
        default="all",
    )
    parser.add_argument("--depth", choices=list(DEPTHS), default="smoke")
    parser.add_argument("--seed", type=int, default=None)
    parser.add_argument("--trials", type=int, default=None, help="override program count")
    parser.add_argument("--case", type=int, default=None, help="replay one semantic scenario index")
    parser.add_argument("--max-features", type=int, default=10)
    parser.add_argument("--pair-rounds", type=int, default=2)
    args = parser.parse_args(argv)
    if args.case is not None and args.case < 0:
        parser.error("--case must be nonnegative")

    n = args.trials or DEPTHS[args.depth]
    seed = args.seed if args.seed is not None else random.randrange(1 << 30)
    print(f"seed={seed} depth={args.depth} n={n}")
    print(f"language features in generator: {len(EMITTERS)} emitters")
    print(f"  {sorted(EMITTERS)}")

    failed = 0
    if args.mode in ("regress", "all", "sweep"):
        failed += run_regress()
    if args.mode in ("pairs", "sweep"):
        failed += run_pairs(seed, rounds_per_pair=args.pair_rounds)
    if args.mode in ("mixed", "all", "sweep"):
        failed += run_mixed(n, seed, args.max_features)
    if args.mode in ("kitchen", "sweep"):
        k = max(5, n // 20)
        failed += run_kitchen(k, seed + 99)
    if args.mode in ("illtyped", "all", "sweep"):
        failed += run_illtyped(max(30, n // 2), seed + 1)
    if args.mode in ("nocrash", "all", "sweep"):
        failed += run_nocrash(max(30, n // 2), seed + 2)
    if args.mode == "explore":
        failed += run_explore(args.trials or 300, seed)
    if args.mode in ("semantic", "all", "sweep"):
        sys.stdout.flush()
        suite = unittest.defaultTestLoader.loadTestsFromName("semantic_generator_test")
        if not unittest.TextTestRunner(verbosity=1).run(suite).wasSuccessful():
            return 1
        failed += run_semantic(n, seed, args.case)

    if failed:
        print(f"\nTOTAL FAILURES: {failed}")
        print("Failing sources saved under found_bugs/ when applicable.")
        return 1
    print("\nwhole-language quickcheck passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
