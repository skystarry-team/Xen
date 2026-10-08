# SPDX-License-Identifier: MIT OR Apache-2.0
"""CLI loader/distribution regressions, deliberately without a stdlib override."""
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import tarfile
import unittest

REPO = Path(__file__).resolve().parents[2]
XEN = REPO / "compiler/dist/xen"


class ToolchainTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xen-toolchain-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cwd = self.root / "unrelated"
        self.cwd.mkdir()
        self.env = dict(os.environ)
        self.env.pop("XEN_STDLIB_ROOT", None)
        self.env["PATH"] = str(self.root / "no-external-tools")

    def source(self, text, name="app.xen"):
        path = self.cwd / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def invoke(self, *args, binary=XEN, env=None):
        return subprocess.run([str(binary), *map(str, args)], cwd=self.cwd,
                              env=self.env if env is None else env,
                              capture_output=True, text=True, timeout=20)

    def success(self, result, stdout=None):
        self.assertEqual(result.returncode, 0, result.stderr)
        if stdout is not None:
            self.assertEqual(result.stdout, stdout)

    def error(self, text, message, line=1, binary=XEN, env=None):
        path = self.source(text)
        result = self.invoke("check", path, binary=binary, env=env)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(message, result.stderr)
        self.assertIn(f"{path}:{line}:1:", result.stderr)

    def distribution(self, library="stdlib"):
        original = self.root / "original"
        (original / "bin").mkdir(parents=True)
        shutil.copy2(XEN, original / "bin/xen")
        shutil.copytree(REPO / "stdlib", original / library)
        moved = self.root / "relocated"
        original.rename(moved)
        return moved / "bin/xen"

    def test_module_aliases(self):
        self.source('module guide.model;struct Pair<T>{value:T}'
                    'enum Role{Admin,Guest}enum Maybe<T>{Some(T),None}fn identity<T>(x:T)->T{return x;}'
                    'fn double(x:Int)->Int{return x*2;}', 'guide/model.xen')
        self.source('module guide.view;use std.option as Helper;'
                    'fn show(x:Int)->String{return Helper.unwrap_or(Option<String>.Some(\"42\"),\"no\");}', 'guide/view.xen')
        source = self.source('module app;import guide.model as model;'
                             'import guide.view as view;use std.convert as Helper;'
                             'use core.box as owning;use core.intrinsics as layout;'
                             'use std.iter as iter;fn main(){'
                             'let p:model.Pair<Int>=model.Pair{value:7};'
                             'println(model.identity(p.value));println(guide.model.identity(p.value));'
                             'let q:model.Maybe<Int>=model.Maybe<Int>.Some(10);'
                             'println(match q{model.Maybe.Some(n)=>n,model.Maybe.None=>0});'
                             'let callback=model.double;println(callback(3));'
                             'let role=model.Role.Admin;println(match role{'
                             'model.Role.Admin=>view.show(42),model.Role.Guest=>"guest"});'
                             'let b:owning.Box<Int>=box(8);println(b.into_inner());'
                             'println(layout.size_of<Int>());println(core.intrinsics.size_of<Int>());'
                             'let v=[9];for (i,n) in v.iter().enumerate(){println(n+i);}'
                             'let as=4;println(Helper.format_int(as));}')
        self.success(self.invoke("check", source))
        self.success(self.invoke("run", source), "7\n7\n10\n6\n42\n8\n8\n8\n9\n4\n")
        output = self.cwd / "aliases"
        self.success(self.invoke("build", source, "-o", output))
        self.success(self.invoke(binary=output), "7\n7\n10\n6\n42\n8\n8\n8\n9\n4\n")
        # A known local enum keeps its old precedence over an unaliased import.
        self.source('module foo;fn unused(){}', 'foo.xen')
        source=self.source('module app;import foo;enum foo{Some(Int)}'
                           'fn main(){let value=foo.Some(5);println(match value{foo.Some(n)=>n});}')
        self.success(self.invoke("run",source),"5\n")

    def test_module_alias_errors(self):
        cases = [
            ('use std.io as helper;use std.fs as helper;', "duplicate module alias"),
            ('use std.io as helper;use std.io as other;', "duplicate module dependency"),
            ('use std.io as std;', "conflicts with a declaration or reserved name"),
            ('use std.io as helper;import helper.child;', "conflicts with a declaration or reserved name"),
            ('use std.io as Int;', "conflicts with a declaration or reserved name"),
            ('use std.io as helper;fn helper(){}', "conflicts with a declaration or reserved name"),
            ('use std.io as helper;struct helper{x:Int}', "conflicts with a declaration or reserved name"),
            ('use std.io as helper;fn unused<T>(helper:T){}', "conflicts with module alias"),
            ('use std.io as helper;fn unused<T>(x:T){let helper=x;}', "conflicts with module alias"),
            ('use std.io as helper;fn unused(){for helper in 0..2{}}', "conflicts with module alias"),
            ('use std.io as helper;fn unused(){let n=match true{helper=>helper};}', "conflicts with module alias"),
            ('use std.io as helper;fn unused(){let(helper,n)=(1,2);}', "conflicts with module alias"),
            ('import std.io as helper;', "requires use, not import"),
            ('use guide.model as helper;', "unknown use root"),
            ('use std.io as helper;fn unused(){let callback=std.fs.read;}', "unknown local or concrete function"),
        ]
        for text, message in cases:
            with self.subTest(text=text):
                source=self.source(text+'fn main(){}')
                result=self.invoke("check",source)
                self.assertEqual(result.returncode,1,result.stderr)
                self.assertIn(message,result.stderr)
                self.assertIn(str(source)+":",result.stderr)

    def test_development_and_dune_discovery(self):
        source = self.source('use std.io; use core.intrinsics; fn main(){'
                             'std.io.write_stdout("ok");println(core.intrinsics.size_of<Int>());}')
        self.success(self.invoke("run", source), "ok8\n")
        self.success(self.invoke("check", source, binary=REPO / "_build/default/compiler/main.exe"))

    def test_generic_inference_across_cli_paths(self):
        self.source('module helpers;fn identity<T>(x:T)->T{return x;}'
                    'fn first<A,B>(a:A,b:B)->A{return a;}', 'helpers.xen')
        source = self.source('module app;import helpers;fn main(){'
                             'let x:I64=42;let y:String="hello";'
                             'println(helpers.identity(x));'
                             'println(helpers.identity<I64>(x));'
                             'println(helpers.first(x,y));'
                             'println(helpers.identity(helpers.identity(i32(7))));}')
        self.success(self.invoke("check", source))
        output = self.cwd / "inferred"
        self.success(self.invoke("build", source, "-o", output))
        self.success(self.invoke(binary=output), "42\n42\n42\n7\n")
        self.success(self.invoke("run", source), "42\n42\n42\n7\n")

        source = self.source('#global[bb]\nstruct Pair<T>{value:T}'
                             'fn id<T>(x:T)->T{return x;}'
                             'fn descend<T>(x:T)->T{if false{return id(descend(x));}return x;}'
                             'fn main(){println(id(Pair{value:8}).value);println(descend(i32(9)));'
                             'let p=raw_alloc<I32>(1);raw_store(p,0,i32(10));let q=id(p);'
                             'println(id(raw_load(q,0)));raw_free(q);}')
        self.success(self.invoke("check", source))
        self.success(self.invoke("build", source, "-o", output))
        self.success(self.invoke(binary=output), "8\n9\n10\n")
        self.success(self.invoke("run", source), "8\n9\n10\n")

    def test_generic_inference_errors_across_cli_paths(self):
        for declaration, body, message, help_text in [
            ('fn create<T>()->T{panic("unused");}', 'let value=create();',
             "cannot infer type parameter 'T'", "create<I64>()"),
            ('fn create<T>()->T{panic("unused");}', 'let value:I64=create();',
             "cannot infer type parameter 'T'", "create<I64>()"),
            ('fn same<T>(a:T,b:T)->T{return a;}', 'same(i32(1),i64(2));',
             "conflicting inference for type parameter 'T': I32 and I64", None),
            ('fn first<A,B>(a:A,b:B)->A{return a;}', 'first<I64>(1,"x");',
             "expects 2 type arguments", None),
        ]:
            with self.subTest(body=body):
                source = self.source(declaration + 'fn main(){' + body + '}')
                diagnostics = []
                for command in ("check", "build", "run"):
                    output = self.cwd / "rejected"
                    args = ("-o", output) if command == "build" else ()
                    result = self.invoke(command, source, *args)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertIn(message, result.stderr)
                    self.assertIn(f"{source}:1:", result.stderr)
                    if help_text:
                        self.assertIn("help: specify all type arguments explicitly", result.stderr)
                        self.assertIn(help_text, result.stderr)
                    self.assertFalse(output.exists())
                    diagnostics.append(result.stderr)
                self.assertEqual(len(set(diagnostics)), 1)

        self.source('module factory;fn create<T>()->T{panic("unused");}', 'factory.xen')
        source = self.source('module app;import factory;fn main(){factory.create();}')
        result = self.invoke("check", source)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("cannot infer type parameter 'T'", result.stderr)
        self.assertIn("factory.create<I64>()", result.stderr)

        source = self.source('use std.env;fn create<T>()->T{panic("unused");}'
                             'fn main(){create();}')
        result = self.invoke("check", source)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("create<I64>()", result.stderr)
        self.assertNotIn("$entry", result.stderr)

    def test_relocated_distribution_and_native_elf(self):
        for library in ("stdlib", "lib/xen"):
            with self.subTest(layout=library):
                binary = self.distribution(library)
                source = self.source('use std.fs;use std.io;fn main(){'
                                     'println(match std.fs.read("/dev/null"){'
                                     'Result.Ok(text)=>len(text),Result.Err(_)=>-1});}')
                output = self.cwd / "program"
                self.success(self.invoke("build", source, "-o", output, binary=binary))
                data = output.read_bytes()
                self.assertEqual(data[:7], b"\x7fELF\x02\x01\x01")
                self.assertEqual(struct.unpack_from("<HH", data, 16), (2, 62))
                phoff = struct.unpack_from("<Q", data, 32)[0]
                entsize, count = struct.unpack_from("<HH", data, 54)
                kinds = [struct.unpack_from("<I", data, phoff + i * entsize)[0] for i in range(count)]
                self.assertNotIn(2, kinds)  # PT_DYNAMIC
                self.assertNotIn(3, kinds)  # PT_INTERP
                self.success(self.invoke(binary=output), "0\n")
                shutil.rmtree(binary.parent.parent)

    def test_path_and_symlink_launch(self):
        binary = self.distribution()
        link = self.root / "xen-link"
        link.symlink_to(binary)
        source = self.source("use std.env;fn main(){println(std.env.args().len());}")
        self.success(self.invoke("run", source, binary=link), "0\n")
        env = dict(self.env, PATH=str(binary.parent))
        self.success(self.invoke("check", source, binary="xen", env=env))

    def test_actual_package_archive(self):
        previous_version = self.invoke("version").stdout.strip().removeprefix("xen ")
        def restore_version():
            restored = subprocess.run(["make", "build", f"VERSION={previous_version}"],
                                      cwd=REPO, capture_output=True, text=True, timeout=30)
            self.assertEqual(restored.returncode, 0, restored.stderr)
        self.addCleanup(restore_version)
        packages = self.root / "packages"
        result = subprocess.run(["make", "package", "VERSION=loader-test", f"DIST_DIR={packages}"],
                                cwd=REPO, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        with tarfile.open(next(packages.glob("*.tar.gz"))) as archive:
            names = archive.getnames()
            prefix = names[0].split("/")[0]
            for relative in ("LICENSE", "LICENSE-MIT", "LICENSE-APACHE", "NOTICE", "VERSION",
                             "THIRD_PARTY.md", "licenses/OCaml.txt", "licenses/CC-BY-4.0.txt",
                             "assets/branding/README.md", "assets/branding/full_logo.png",
                             "assets/branding/full_logo.png.license", "docs/en/jit.md",
                             "docs/ko/jit.md", "examples/demo.xen"):
                self.assertIn(f"{prefix}/{relative}", names)
            for image in set(re.findall(r'assets/branding/[^"\s]+\.png', (REPO / "README.md").read_text())):
                self.assertIn(f"{prefix}/{image}", names)
                self.assertIn(f"{prefix}/{image}.license", names)
            self.assertFalse(any("reference" in Path(name).parts or
                                 Path(name).name in ("AGENTS.md", "CLAUDE.md")
                                 for name in names))
            for image in (REPO / "assets/branding").glob("*.png"):
                relative = image.relative_to(REPO).as_posix()
                self.assertEqual(archive.extractfile(f"{prefix}/{relative}").read(), image.read_bytes())
            self.assertEqual(archive.extractfile(f"{prefix}/licenses/OCaml.txt").read(),
                             (REPO / "licenses/OCaml.txt").read_bytes())
            self.assertEqual(archive.extractfile(f"{prefix}/VERSION").read(), b"loader-test\n")
            archive.extractall(self.root / "unpacked", filter="data")
        package = next((self.root / "unpacked").iterdir())
        moved = self.root / "moved-archive"
        package.rename(moved)
        self.success(self.invoke("version", binary=moved / "bin/xen"), "xen loader-test\n")
        source = self.source('use std.io;fn main(){std.io.write_stdout("archive");}')
        self.success(self.invoke("run", source, binary=moved / "bin/xen"), "archive")
        self.success(self.invoke("test", "std.fs", "--filter", "null", binary=moved / "bin/xen"),
                     "PASS std.fs.null_file\n1 passed; 0 failed\n")
        self.success(self.invoke("run", moved / "examples/demo.xen", binary=moved / "bin/xen"),
                     "Hello\nfrom\nXen\n")

        exported = subprocess.run(["make", "source-package", "VERSION=loader-test", f"DIST_DIR={packages}"],
                                  cwd=REPO, capture_output=True, text=True, timeout=30)
        self.assertEqual(exported.returncode, 0, exported.stderr)
        source_archive = packages / "xen-loader-test-source.tar.gz"
        with tarfile.open(source_archive) as archive:
            names = archive.getnames()
            prefix = "xen-loader-test-source"
            for relative in ("Makefile", "dune-project", ".gitignore", "compiler/checker.ml",
                             "tests/property/runner.py", "scripts/package.py", "LICENSE"):
                self.assertIn(f"{prefix}/{relative}", names)
            banned = {".git", ".idea", "reference", "test", "__pycache__", "found_bugs", "dist"}
            self.assertFalse(any(banned.intersection(Path(name).parts) or
                                 Path(name).name in ("AGENTS.md", "CLAUDE.md") for name in names))
            self.assertEqual(archive.extractfile(f"{prefix}/compiler/checker.ml").read(),
                             (REPO / "compiler/checker.ml").read_bytes())
            self.assertEqual(archive.extractfile(f"{prefix}/VERSION").read(), b"loader-test\n")

    def test_cli_version(self):
        expected = os.environ.get("XEN_BUILD_VERSION") or (REPO / "VERSION").read_text().strip()
        for command in ("version", "--version"):
            with self.subTest(command=command):
                result = self.invoke(command, env=dict(self.env, XEN_STDLIB_ROOT="/missing"))
                self.success(result, f"xen {expected}\n")
                self.assertEqual(result.stderr, "")
                invalid = self.invoke(command, "extra")
                self.assertEqual(invalid.returncode, 2)
                self.assertEqual(invalid.stdout, "")
                self.assertIn("Usage:", invalid.stderr)

    def test_namespace_errors_and_spans(self):
        for declaration, message in [
            ("import std.fs;", "requires use, not import"),
            ("import core.intrinsics;", "requires use, not import"),
            ("import std;", "requires use, not import"),
            ("import core;", "requires use, not import"),
            ("use mylib.foo;", "unknown use root"),
            ("use core.missing;", "unknown core module"),
            ("use std.missing;", "std module not found"),
        ]:
            with self.subTest(declaration=declaration):
                self.error("\n" + declaration + "\nfn main(){}", message, line=2)
        self.error("module std.fake;fn main(){}", "reserved for the toolchain")
        self.error("module core.fake;fn main(){}", "reserved for the toolchain")

    def test_authoritative_override_and_missing_bundle(self):
        env = dict(self.env, XEN_STDLIB_ROOT=str(self.root / "missing"))
        self.error("use std.io;fn main(){}", "invalid XEN_STDLIB_ROOT", env=env)
        bare = self.root / "bare/bin/xen"
        bare.parent.mkdir(parents=True)
        shutil.copy2(XEN, bare)
        shutil.copytree(REPO / "stdlib", self.cwd / "stdlib")
        self.error("use std.io;fn main(){}", "bundled stdlib not found", binary=bare)
        shutil.copytree(REPO / "stdlib", self.root / "stdlib")
        self.error("use std.io;fn main(){}", "bundled stdlib not found", binary=bare)
        source = self.source("use core.intrinsics;fn main(){println(core.intrinsics.size_of<U8>());}")
        self.success(self.invoke("run", source, binary=bare, env=env), "1\n")

    def test_mixed_graph_shadowing_and_direct_use(self):
        self.source("module helper;use std.iter;fn value()->Int{return 7;}", "helper.xen")
        self.source("module std.fs;fn read()->Int{return 99;}", "std/fs.xen")
        source = self.source('module app;import helper;use std.fs;fn main(){'
                             'println(helper.value());println(match std.fs.read("/dev/null"){'
                             'Result.Ok(x)=>len(x),Result.Err(_)=>-1});}')
        self.success(self.invoke("run", source), "7\n0\n")
        result = self.invoke("check", self.source("module app;import helper;fn main(){let xs=[1];xs.iter();}"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("explicit 'use std.iter;'", result.stderr)
        result = self.invoke("check", self.source("module app;use core.intrinsics;fn main(){helper.value();}"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("unknown local or concrete function 'helper'", result.stderr)

    def test_nested_loader_diagnostic(self):
        override = self.root / "override"
        (override / "std").mkdir(parents=True)
        path = override / "std/bad.xen"
        path.write_text("module std.bad;\nimport core.intrinsics;\nfn helper(){}")
        env = dict(self.env, XEN_STDLIB_ROOT=str(override))
        result = self.invoke("check", self.source("use std.bad;fn main(){}"), env=env)
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"{path}:2:1:", result.stderr)
        self.assertIn("requires use, not import", result.stderr)

    def test_std_iter_can_test_its_own_factories(self):
        override = self.root / "override"
        path = override / "std/iter.xen"
        path.parent.mkdir(parents=True)
        path.write_text((REPO / "stdlib/std/iter.xen").read_text() +
                        'test fn own_factories(){let values:Vec<Int>=[2,4];let mut sum=0;'
                        'for value in values.iter(){sum=sum+value;}assert(sum==6);'
                        'let mut indexed=0;for (index,value) in values.iter().enumerate(){'
                        'indexed=indexed+index+value;}assert(indexed==7);}')
        env = dict(self.env, XEN_STDLIB_ROOT=str(override))
        self.success(self.invoke("test", "std.iter", env=env),
                     "PASS std.iter.own_factories\n1 passed; 0 failed\n")


if __name__ == "__main__":
    unittest.main()
