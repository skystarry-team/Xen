# SPDX-License-Identifier: MIT OR Apache-2.0
"""Run Xen test suites from the repository root."""
import argparse
import os
import platform
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


MACOS_ARM64_CASES = (
    "test_integer_widths_control_flow_and_calls",
    "test_references_aggregates_generics_and_indirect_calls",
    "test_string_lifetimes_and_program_arguments",
    "test_recursive_function_field_types_and_label_names",
    "test_generated_integer_programs",
    "test_float_arithmetic_calls_storage_and_comparisons",
    "test_float_checked_conversions",
    "test_generated_float_arithmetic",
    "test_heap_strings_clone_move_fields_and_reference_replacement",
    "test_box_functions_borrows_extraction_and_recursive_types",
    "test_collection_storage_operations_and_byte_views",
    "test_collection_owned_elements_and_cleanup",
    "test_collection_stdlib",
    "test_collection_runtime_failures",
    "test_ownership_flags_cleanup_on_branch_loop_return_and_try",
    "test_raw_memory_pod_and_descriptor_contract",
    "test_raw_memory_errors",
)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", choices=("all", "arm64", "host", "windows", "macos", "macos-prototype", "quickcheck", "semantic", "packaging"), default="all")
    parser.add_argument("--mode", default="all")
    parser.add_argument("--depth", default="standard")
    parser.add_argument("--seed")
    args = parser.parse_args()
    if args.suite == "all" and platform.system() == "Darwin" and platform.machine() == "arm64":
        args.suite = "macos"
    if args.suite != "macos-prototype":
        run("dune", "build", "@release")
    if args.suite == "macos-prototype":
        prototype()
    elif args.suite == "macos":
        run("dune", "runtest")
        run("dune", "exec", "tests/backend_contract_test.exe")
        run("dune", "exec", "tests/mach_o_test.exe")
        run("dune", "build", "tests/mach_o_fixture.exe", "tests/darwin_fixture.exe")
        integration("mach_o")
        integration("macos")
        integration("arm64", *("Arm64Tests." + case for case in MACOS_ARM64_CASES),
                    XEN_ARM64_TARGET="aarch64-macos", XEN_REQUIRE_ARM64="1")
        for optimization in ("off", "basic"):
            integration("stdlib", XEN_STDLIB_TARGET="aarch64-macos",
                        XEN_STDLIB_OPT=optimization)
    elif args.suite == "windows":
        run("dune", "exec", "tests/version_gen_test.exe")
        run("dune", "build", "tests/windows_fixture.exe", "tests/windows_runner_fixture.exe", "tests/windows_abi_fixture.exe", "tests/windows_runtime_fixture.exe")
        run("dune", "exec", "tests/pe_writer_test.exe")
        run("dune", "exec", "tests/win64_test.exe")
        run("dune", "exec", "tests/backend_contract_test.exe")
        run("dune", "exec", "tests/platform_service_test.exe")
        integration("windows", *(["--require-native"] if os.name == "nt" else []))
        integration("windows_abi", *(["--require-native"] if os.name == "nt" else []))
        integration("windows_runtime", *(["--require-native"] if os.name == "nt" else []))
        integration("windows_package")
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
        integration("windows_package")
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
            for name in ("optimization", "operators", "power_remainder", "scoped_opt", "aot_fusion", "low_level", "low_level_extended", "x86_64_runtime", "toolchain", "package_build", "package_distribution", "windows_package", "arm64", "host", "stdlib"):
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
