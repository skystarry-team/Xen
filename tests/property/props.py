# SPDX-License-Identifier: Apache-2.0
"""Properties evaluated against a live xen binary."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import resource
from dataclasses import dataclass
from pathlib import Path
from shutil import which

from grammar import Program


@dataclass
class RunResult:
    status: int
    stdout: str
    stderr: str


def resolve_xen() -> Path:
    env = os.environ.get("XEN_BIN")
    if env:
        candidate = Path(env).expanduser().resolve()
        if not candidate.is_file() or not os.access(candidate, os.X_OK):
            raise FileNotFoundError(f"invalid XEN_BIN: {env}")
        return candidate
    for candidate in [
        Path(__file__).resolve().parents[2] / "compiler" / "dist" / "xen",
    ]:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    found = which("xen")
    if found:
        return Path(found)
    raise FileNotFoundError("xen binary not found; run make build or set XEN_BIN")


XEN = resolve_xen()
TIMEOUT = 8


def _run_cmd(args: list[str], cwd: Path, fd_limit: int | None = None) -> RunResult:
    def limit_descriptors():
        _, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        limit = fd_limit if hard == resource.RLIM_INFINITY else min(fd_limit, hard)
        resource.setrlimit(resource.RLIMIT_NOFILE, (limit, hard))
    try:
        proc = subprocess.run(
            args,
            cwd=cwd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=TIMEOUT,
            check=False,
            preexec_fn=limit_descriptors if fd_limit is not None else None,
        )
    except subprocess.TimeoutExpired as err:
        raise AssertionError(f"xen timed out: {args}") from err
    return RunResult(proc.returncode, proc.stdout, proc.stderr)


def run_program(prog: Program, fd_limit: int | None = None) -> RunResult:
    with tempfile.TemporaryDirectory(prefix="xen-whole-") as directory:
        root = Path(directory)

        def restore(files):
            for child in root.iterdir():
                if child.is_dir() and not child.is_symlink():
                    shutil.rmtree(child)
                else:
                    child.unlink()
            for rel, source in files.items():
                path = root / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(source, encoding='utf-8')

        def execute(files, *flags):
            restore(files)
            return _run_cmd([str(XEN), 'run', str(root / prog.entry), *flags], cwd=root, fd_limit=fd_limit)

        off = execute(prog.files, '--opt=off', '--jit=off')
        basic = execute(prog.files, '--opt=basic', '--jit=off')
        assert off == basic, (prog.notes, prog.files, 'off/basic mismatch', off, basic)
        # Generated main is last; compare scope insertion independently of the
        # runtime encoder, then compare the exact annotated source/IR both ways.
        source = prog.files[prog.entry]
        marker = 'fn main(){'
        if marker in source and source.rstrip().endswith('}'):
            annotated = source.replace(marker, marker + '#scope[jit]{', 1)
            annotated = annotated.rstrip()[:-1] + '}}'
            files = dict(prog.files, **{prog.entry: annotated})
            reference = execute(files, '--opt=basic', '--jit=off')
            jit = execute(files, '--opt=basic', '--jit=on')
            assert off == reference, (prog.notes, annotated, 'scope insertion mismatch', off, reference)
            assert reference == jit, (prog.notes, annotated, 'AOT/JIT mismatch', reference, jit)
        return off


def check_program(prog: Program) -> RunResult:
    with tempfile.TemporaryDirectory(prefix="xen-whole-check-") as directory:
        root = Path(directory)
        for rel, source in prog.files.items():
            path = root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source, encoding="utf-8")
        return _run_cmd([str(XEN), "check", str(root / prog.entry)], cwd=root)


def _stdout_matches(actual: str, expected: str, features: frozenset[str]) -> bool:
    if "float" not in features:
        return actual == expected
    # line-wise float-tolerant compare
    a_lines = actual.splitlines()
    e_lines = expected.splitlines()
    if len(a_lines) != len(e_lines):
        return False
    for a, e in zip(a_lines, e_lines):
        try:
            if float(a) == float(e):
                continue
        except ValueError:
            pass
        if a != e:
            return False
    return True


def prop_mixed_runs(prog: Program) -> None:
    assert prog.expect_check_fail is None
    result = run_program(prog)
    assert result.status == 0, (prog.notes, prog.files, result)
    assert result.stderr == "", (prog.notes, result)
    assert _stdout_matches(result.stdout, prog.expected_stdout, prog.features), (
        prog.notes,
        prog.files,
        f"expected={prog.expected_stdout!r}",
        f"actual={result.stdout!r}",
    )


def prop_illtyped_diagnostics(prog: Program) -> None:
    assert prog.expect_check_fail is not None
    result = check_program(prog)
    assert result.status == 1, (prog.files, result)
    assert prog.expect_check_fail in result.stderr, (prog.expect_check_fail, result)


def prop_nocrash(prog: Program) -> None:
    result = check_program(prog)
    assert result.status in (0, 1), result
    lowered = result.stderr.lower()
    for bad in ("fatal error", "assertion failed", "internal error", "segmentation"):
        assert bad not in lowered, result


def prop_contextual_probe(prog: Program) -> dict:
    """Does not assert success/failure — reports for explore mode."""
    result = check_program(prog)
    return {
        "ok": result.status == 0,
        "stderr": result.stderr.strip(),
        "source": next(iter(prog.files.values())),
        "notes": prog.notes,
    }
