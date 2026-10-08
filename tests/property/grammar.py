# SPDX-License-Identifier: Apache-2.0
"""Program-level AST fragments and rendering for Xen whole-language QC."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


# ---- low-level expression / statement builders (stringly, but structured) ----

@dataclass
class Program:
    """A complete Xen compilation unit (single file) or multi-file project."""

    files: dict[str, str]  # relative path -> source
    entry: str  # entry file relative path
    expected_stdout: str
    features: frozenset[str]
    notes: str = ""
    # If expect_check_fail is set, we only run `check` and require failure + needle.
    expect_check_fail: Optional[str] = None


def xen_string(value: str) -> str:
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )
    return f'"{escaped}"'


def wrap_main(body: str, preamble: str = "", capabilities: str = "") -> str:
    """capabilities e.g. '#![bb]\\n' or '#global[explc]\\n'."""
    return f"{capabilities}{preamble}fn main(){{{body}}}"
