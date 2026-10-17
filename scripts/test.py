# SPDX-License-Identifier: MIT OR Apache-2.0
"""Run Xen test suites from the repository root."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def run(*command: str, **environment: str) -> None:
    subprocess.run(command, cwd=ROOT, env=dict(os.environ, **environment), check=True)


def integration(name: str, *arguments: str, **environment: str) -> None:
    run(sys.executable, f"tests/integration/{name}_test.py", *arguments, **environment)


def prototype() -> None:
    run("dune", "exec", "tests/mach_o_test.exe")
    run("dune", "exec", "tests/arm64_machine_test.exe")
    run("dune", "build", "tests/mach_o_fixture.exe", "tests/darwin_fixture.exe", "tests/darwin_abi_fixture.exe")
    integration("mach_o")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", choices=("all", "arm64", "host", "windows", "macos-prototype", "quickcheck", "semantic", "packaging"), default="all")
    parser.add_argument("--mode", default="all")
    parser.add_argument("--depth", default="standard")
    parser.add_argument("--seed")
    args = parser.parse_args()
    if args.suite != "macos-prototype":
        run("dune", "build", "@release")
    if args.suite == "macos-prototype":
        prototype()
    elif args.suite == "windows":
        run("dune", "build", "tests/windows_fixture.exe", "tests/windows_runner_fixture.exe", "tests/windows_abi_fixture.exe", "tests/windows_runtime_fixture.exe")
        run("dune", "exec", "tests/pe_writer_test.exe")
        run("dune", "exec", "tests/win64_test.exe")
        run("dune", "exec", "tests/backend_contract_test.exe")
        integration("windows", *(["--require-native"] if os.name == "nt" else []))
        integration("windows_abi", *(["--require-native"] if os.name == "nt" else []))
        integration("windows_runtime", *(["--require-native"] if os.name == "nt" else []))
    elif args.suite == "arm64":
        run("dune", "exec", "tests/arm64_machine_test.exe")
        integration("arm64", XEN_REQUIRE_ARM64="1")
        integration("stdlib", "--arm64", XEN_REQUIRE_ARM64="1")
    elif args.suite == "host":
        run("dune", "exec", "tests/backend_contract_test.exe")
        integration("host")
    elif args.suite == "packaging":
        integration("package_build")
        integration("package_distribution")
    elif args.suite in ("all", "quickcheck", "semantic"):
        if args.suite == "all":
            run("dune", "runtest")
            run("dune", "build", "tests/windows_fixture.exe", "tests/windows_runner_fixture.exe", "tests/windows_abi_fixture.exe", "tests/windows_runtime_fixture.exe")
            integration("windows")
            integration("windows_abi")
            integration("windows_runtime")
            run("dune", "build", "tests/mach_o_fixture.exe", "tests/darwin_fixture.exe", "tests/darwin_abi_fixture.exe")
            integration("mach_o")
            run("dune", "exec", "tests/native_core_test.exe", XEN_TEST_OPT="basic")
            for name in ("optimization", "operators", "power_remainder", "scoped_opt", "aot_fusion", "low_level", "low_level_extended", "x86_64_runtime", "toolchain", "package_build", "package_distribution", "arm64", "host", "stdlib"):
                integration(name)
            integration("stdlib", "--arm64")
            integration("test_workflow")
        elif args.suite == "semantic":
            run("dune", "exec", "tests/semantic_ir_test.exe")
        command = [sys.executable, "tests/property/runner.py", "--mode",
                   "semantic" if args.suite == "semantic" else args.mode, "--depth", args.depth]
        if args.seed:
            command += ["--seed", args.seed]
        run(*command, XEN_BIN=os.getenv("XEN_BIN", str(ROOT / "compiler/dist/xen")),
            XEN_STDLIB_ROOT=os.getenv("XEN_STDLIB_ROOT", str(ROOT / "stdlib")))


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
