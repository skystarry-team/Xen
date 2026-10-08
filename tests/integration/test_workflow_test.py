# SPDX-License-Identifier: MIT OR Apache-2.0
"""First-class Xen test CLI regressions, not a second test execution engine."""
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
XEN = REPO / "compiler/dist/xen"


class TestWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xen-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def source(self, text, name="app.xen"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def invoke(self, *args):
        return subprocess.run([str(XEN), "test", *map(str, args)], cwd=self.root,
                              capture_output=True, text=True, timeout=30)

    def test_no_main_and_filter(self):
        self.source('test fn vec_push(){let mut xs=[1,2];xs.push(3);assert(xs.len()==3);}'
                    'test fn plain(){assert(true);}')
        result = self.invoke("--filter", "vec")
        self.assertEqual((result.returncode, result.stdout), (0, "PASS app.vec_push\n1 passed; 0 failed\n"), result.stderr)
        result = self.invoke("--filter", "none")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no tests matched", result.stderr)

    def test_main_is_not_run_and_order_is_stable(self):
        path = self.source('fn main(){panic("main executed");}test fn z(){assert(true);}'
                           'test fn a(){println("captured");assert(true);}')
        for _ in range(2):
            result = self.invoke(path)
            self.assertEqual((result.returncode, result.stdout),
                             (0, "PASS app.a\nPASS app.z\n2 passed; 0 failed\n"), result.stderr)

    def test_failure_continues_and_preserves_runtime_location(self):
        path = self.source('test fn a_fails(){println("before");assert_msg(false,"expected failure");}\n'
                           'test fn b_passes(){assert(true);}\n'
                           'test fn c_panics(){panic("panic failure");}')
        result = self.invoke(path)
        self.assertEqual(result.returncode, 1)
        self.assertIn("before", result.stdout)
        self.assertIn("PASS app.b_passes", result.stdout)
        self.assertIn("1 passed; 2 failed", result.stdout)
        self.assertIn(f"{path}:1:", result.stderr)
        self.assertIn("expected failure", result.stderr)
        self.assertIn("panic failure", result.stderr)

    def test_compilation_diagnostics(self):
        path = self.source('test fn wrong(){let n:I8=1;let wide:I16=n;}')
        result = self.invoke(path)
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"{path}:1:", result.stderr)
        self.assertIn("convert explicitly with i16", result.stderr)
        self.assertIn("FAIL app.wrong (compilation)", result.stdout)

    def test_invalid_test_signatures_and_syntax(self):
        for declaration in ["test fn bad<T>(){}", "test fn bad(value:Int){}",
                            "test fn bad()->Int{return 1;}"]:
            path = self.source(declaration)
            result = self.invoke(path)
            self.assertEqual(result.returncode, 1, declaration)
            self.assertIn("test functions must be nongeneric, parameterless, and return Unit", result.stderr)
        path = self.source("test fn broken(")
        result = self.invoke(path)
        self.assertEqual(result.returncode, 1)
        self.assertIn(str(path) + ":1:", result.stderr)

    def test_modes_and_null_stdin(self):
        path = self.source('use std.io;\n#![bb]\ntest fn raw(){let p=raw_alloc<Int>(1);'
                           'raw_store(p,0,7);assert(raw_load(p,0)==7);raw_free(p);}\n'
                           'test fn stdin(){assert(match std.io.read_stdin(){Result.Ok(s)=>len(s)==0,_=>false});}')
        result = self.invoke(path)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2 passed; 0 failed", result.stdout)

    def test_recursive_discovery_keeps_project_root(self):
        self.source('module app;import lib.math;fn main(){panic("main");}'
                    'test fn entry(){assert(lib.math.value()==7);}')
        self.source('module lib.math;import common.model;fn value()->Int{return 7;}'
                    'test fn math(){let value=common.model.Box{value:7};assert(value.value==7);}', "lib/math.xen")
        self.source('module common.model;struct Box{value:Int}test fn model(){assert(true);}', "common/model.xen")
        (self.root / "loop").symlink_to(self.root, target_is_directory=True)
        for target in (".", "app.xen"):
            result = self.invoke(target)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "PASS app.entry\nPASS common.model.model\nPASS lib.math.math\n3 passed; 0 failed\n")

    def test_stdlib_selectors_and_arguments(self):
        for module in ("std.fs", "std.io", "std.path", "std.env", "std.process"):
            result = self.invoke(module)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("PASS " + module + ".", result.stdout)
        result = self.invoke("std.fs", "--filter", "null")
        self.assertEqual((result.returncode, result.stdout),
                         (0, "PASS std.fs.null_file\n1 passed; 0 failed\n"), result.stderr)
        self.assertEqual(self.invoke("--filter").returncode, 2)
        self.assertEqual(self.invoke("std.missing").returncode, 1)
        self.assertEqual(self.invoke("missing.xen").returncode, 1)

    def test_existing_paths_take_precedence_over_selectors(self):
        for name in ("std.xen", "core.xen", "std.tools/app.xen"):
            path = self.source("test fn ok(){assert(true);}", name)
            target = path.parent if name.startswith("std.tools/") else path
            result = self.invoke(target)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("1 passed; 0 failed", result.stdout)
        result = self.invoke(self.source("module std.fake;test fn wrong(){}", "reserved.xen"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("reserved for the toolchain", result.stderr)


if __name__ == "__main__":
    unittest.main()
