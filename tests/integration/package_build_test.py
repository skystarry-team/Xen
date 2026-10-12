# SPDX-License-Identifier: MIT OR Apache-2.0
"""Compiler matrix selection, toolchain validation and release failure checks."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))
import package_build as builder
import test as suite_runner


def config(architecture="amd64", version="5.5.0", system="linux"):
    return dict(architecture=architecture, version=version, system=system,
                word_size="64", native_compiler="true")


class PackageBuildTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="xen-package-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.prefix = self.root / "cross"
        (self.prefix / "bin").mkdir(parents=True)
        for name in ("ocamlc", "ocamlopt"):
            executable = self.prefix / "bin" / name
            executable.write_bytes(b"fixture")
            executable.chmod(0o755)
        self.toolchains = {arch: dict(prefix=str(self.prefix), runner=[])
                           for arch in builder.ARCHITECTURES}

    def make(self, *arguments, extra_env=None):
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith("PACKAGE") and key != "DUNE_WORKSPACE"}
        environment.update(extra_env or {})
        result = subprocess.run(["make", "-n", *arguments], cwd=REPO, env=environment,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_make_defaults_and_explicit_single_routes(self):
        for target in ("package", "package-build"):
            command = self.make(target)
            self.assertIn("scripts/package_build.py --architectures x86_64 aarch64", command)
            self.assertNotIn("scripts/package.py", command)
        self.assertIn("--build-only", self.make("package-build"))
        for selector in ("DUNE_WORKSPACE", "PACKAGE_ARCH", "PACKAGE_CONTEXT", "PACKAGE_BINARY"):
            for command in (self.make("package", selector+"="),
                            self.make("package", extra_env={selector: ""})):
                self.assertIn("scripts/package_build.py --architectures x86_64 aarch64", command)
        self.assertIn("_build/default/compiler/main.exe", self.make("package-one", "PACKAGE_CONTEXT="))
        command = self.make("package", "PACKAGE_BINARY=/existing/xen", "DUNE_WORKSPACE=/missing")
        self.assertIn('scripts/package.py --binary "/existing/xen"', command)
        self.assertNotIn("dune build", command)
        command = self.make("package", "PACKAGE_CONTEXT=arm64", "DUNE_WORKSPACE=/workspace")
        self.assertIn('_build/arm64/compiler/main.exe', command)
        self.assertNotIn("scripts/package_build.py", command)
        command = self.make("package", "PACKAGE_ARCHS=arm64")
        self.assertIn("scripts/package_build.py --architectures arm64", command)
        self.assertIn("scripts/package.py", self.make("package-one"))

    def test_make_delegates_test_suites(self):
        command = self.make("test", "QUICKCHECK_SEED=123")
        self.assertIn("scripts/test.py", command)
        self.assertIn('--seed "123"', command)
        self.assertNotIn("tests/integration/", command)

    def test_property_runner_preserves_explicit_compiler_settings(self):
        binary = str(self.root / "missing-xen")
        library = str(self.root / "custom-stdlib")
        environment = dict(os.environ, XEN_BIN=binary, XEN_STDLIB_ROOT=library)
        with patch.dict(os.environ, environment), patch.object(suite_runner, "run") as run, \
                patch.object(sys, "argv", ["test.py", "--suite", "quickcheck", "--mode", "mixed", "--depth", "smoke"]):
            suite_runner.main()
        self.assertEqual(run.call_args.kwargs["XEN_BIN"], binary)
        self.assertEqual(run.call_args.kwargs["XEN_STDLIB_ROOT"], library)
        result = subprocess.run([sys.executable, "tests/property/runner.py", "--mode", "mixed", "--depth", "smoke"],
                                cwd=REPO, env=environment, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(binary, result.stdout+result.stderr)

    def test_native_and_cross_selection_on_both_hosts(self):
        for host, cross, native_arch in (("x86_64", "aarch64", "amd64"),
                                        ("aarch64", "x86_64", "arm64")):
            cross_arch = "arm64" if cross == "aarch64" else "amd64"
            with self.subTest(host=host), patch.object(builder.shutil, "which", side_effect=lambda name: "/native/bin/"+name), \
                    patch.object(builder, "compiler_pair", side_effect=[config(native_arch), config(cross_arch)]):
                native_bin, builds = builder.plan(list(builder.ARCHITECTURES), self.toolchains)
            selected = {build.architecture: build for build in builds}
            self.assertEqual(selected[host].context, "default")
            self.assertIsNone(selected[host].prefix)
            self.assertEqual(selected[cross].prefix, self.prefix)
            workspace = builder.workspace(native_bin, builds)
            self.assertIn("(host default)", workspace)
            self.assertIn(str(self.prefix / "bin"), workspace)
            self.assertIn("OPAM_SWITCH_PREFIX", workspace)

    def test_bad_cross_toolchains_reject_before_building(self):
        with patch.object(builder.shutil, "which", side_effect=lambda name: "/native/bin/"+name), \
                patch.object(builder, "compiler_pair", return_value=config()), \
                patch.object(builder.subprocess, "run") as run:
            path = self.root / "toolchains.json"
            path.write_text(json.dumps({"aarch64": dict(prefix=str(self.root / "absent"))}))
            with self.assertRaisesRegex(ValueError, "missing aarch64 OCaml cross compiler"):
                builder.build_packages(list(builder.ARCHITECTURES), path, "test", self.root / "dist")
            run.assert_not_called()
            self.assertFalse((self.root / "dist").exists())
        for cross, message in ((config("amd64"), "target mismatch"),
                               (config("arm64", system="macosx"), "target mismatch"),
                               (config("arm64", version="5.4.0"), "version mismatch")):
            with self.subTest(cross=cross), \
                    patch.object(builder.shutil, "which", side_effect=lambda name: "/native/bin/"+name), \
                    patch.object(builder, "compiler_pair", side_effect=[config(), cross]), \
                    self.assertRaisesRegex(ValueError, message):
                builder.plan(list(builder.ARCHITECTURES), self.toolchains)

    def test_compiler_pair_must_match(self):
        with patch.object(builder, "configuration", side_effect=[config(), config("arm64")]), \
                self.assertRaisesRegex(ValueError, "configuration mismatch for architecture"):
            builder.compiler_pair(self.prefix / "bin")
        bad = dict(config(), native_compiler="false")
        with patch.object(builder, "configuration", return_value=bad), \
                self.assertRaisesRegex(ValueError, "native OCaml compiler is required"):
            builder.compiler_pair(self.prefix / "bin")

    def test_invalid_configuration_and_architecture_selection(self):
        path = self.root / "toolchains.json"
        with self.assertRaises(FileNotFoundError):
            builder.load_toolchains(path)
        for value in ([], {"macos": {}}, {"aarch64": {"prefix": "relative"}},
                      {"aarch64": {"prefix": str(self.prefix), "runner": [1]}},
                      {"aarch64": {"prefix": str(self.prefix), "typo": True}}):
            with self.subTest(value=value):
                path.write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    builder.load_toolchains(path)
        for architectures in ([], ["x86_64", "x86_64"], ["macos"]):
            with self.assertRaises(ValueError):
                builder.plan(architectures, {})

    def test_second_archive_failure_preserves_all_releases(self):
        output = self.root / "dist"
        output.mkdir()
        toolchains = self.root / "toolchains.json"
        toolchains.write_text("{}")
        builds = [builder.Build(arch, "default" if arch == "x86_64" else "package_aarch64", None, [])
                  for arch in builder.ARCHITECTURES]
        for arch in builder.ARCHITECTURES:
            (output / f"xen-test-linux-{arch}.tar.gz").write_bytes(b"previous release")

        def archive(*args, **kwargs):
            arch = kwargs["architecture"]
            if arch == "aarch64":
                raise ValueError("compiler version mismatch")
            (kwargs["output_dir"] / f"xen-test-linux-{arch}.tar.gz").write_bytes(b"new release")

        with patch.object(builder, "plan", return_value=(Path("/native/bin"), builds)), \
                patch.object(builder.shutil, "which", return_value="/dune"), \
                patch.object(builder.subprocess, "run") as run, \
                patch.object(builder, "binary_architecture", side_effect=list(builder.ARCHITECTURES)), \
                patch.object(builder, "package", side_effect=archive), \
                self.assertRaisesRegex(ValueError, "version mismatch"):
            builder.build_packages(list(builder.ARCHITECTURES), toolchains, "test", output)
        command = run.call_args.args[0]
        self.assertEqual(len([arg for arg in command if arg.endswith("compiler/main.exe")]), 2)
        self.assertNotIn("@release", command)
        for arch in builder.ARCHITECTURES:
            self.assertEqual((output / f"xen-test-linux-{arch}.tar.gz").read_bytes(), b"previous release")
        self.assertEqual(len(list(output.iterdir())), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
