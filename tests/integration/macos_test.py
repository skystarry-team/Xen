# SPDX-License-Identifier: MIT OR Apache-2.0
"""Native Apple Silicon loader, runtime, stdlib and relocated package gate."""
import os
from pathlib import Path
import platform
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from packaging.common import validate_macos_image
XEN = ROOT / "compiler/dist/xen"
VERSION = (ROOT / "VERSION").read_text().strip()


def run(*args, cwd=ROOT, env=None, input=None):
    result = subprocess.run(args, cwd=cwd, env=env, input=input,
                            capture_output=True, timeout=120)
    if result.returncode:
        raise AssertionError(f"{args!r} exited {result.returncode}\n"
                             f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}")
    return result.stdout


def inspect(image):
    _, dependencies = validate_macos_image(image)
    return run("file", str(image)), "\n".join(dependencies).encode()


def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        sys.exit("macOS suite requires a native Apple Silicon host")
    assert run(str(XEN), "version") == f"xen {VERSION}\n".encode()
    inspect(XEN)
    with tempfile.TemporaryDirectory(prefix="xen-macos-native-") as temporary:
        workspace = Path(temporary) / "space 한글"
        workspace.mkdir()
        canonical_cwd = str(workspace.resolve())
        target_file = workspace / "metadata-target"
        target_file.write_bytes(b"target")
        os.utime(target_file, (1700000000, 1700000000))
        (workspace / "metadata-link").symlink_to(target_file)
        source = workspace / "app.xen"
        source.write_text('''
use std.io;
use std.fs;
use std.env;
use std.process;
test fn selected() { assert(std.process.id() > 0 && std.process.parent_id() > 0); }
fn main() {
    assert(std.process.id() > 0 && std.process.parent_id() > 0);
    assert(match std.env.cwd() { Result.Ok(path) => path == arg(1), _ => false });
    let input = match std.io.read_stdin() { Result.Ok(text) => text, _ => "bad" };
    let path = arg(0);
    assert(match std.fs.write(path, input) { Result.Ok(5) => true, _ => false });
    assert(match std.fs.append(path, "!") { Result.Ok(1) => true, _ => false });
    assert(match std.fs.metadata(path) { Result.Ok(m) => m.is_file && m.size == 6, _ => false });
    assert(match std.fs.metadata("metadata-link") {
        Result.Ok(m) => m.is_file && m.size == 6 && m.modified_seconds == 1700000000,
        _ => false,
    });
    assert(match std.fs.read_dir(".") { Result.Ok(names) => names.len() > 0, _ => false });
    assert(match std.fs.read("missing") { Result.Err(std.io.IoError.Open(2)) => true, _ => false });
    let mut file = open_write("builtin.txt"); file.write("ok"); file.close();
    assert(read_text("builtin.txt") == "ok");
    println(match std.fs.read(path) { Result.Ok(text) => text, _ => "bad" });
}
''')
        target = "--target=aarch64-macos"
        run(str(XEN), "check", str(source), target, cwd=workspace)
        assert b"2 passed; 0 failed" in run(str(XEN), "test", "std.platform", target,
                                              cwd=workspace)
        for optimization in ("off", "basic"):
            output = workspace / ("app-" + optimization)
            run(str(XEN), "build", str(source), target, f"--opt={optimization}",
                "-o", str(output), cwd=workspace)
            image_info, dependencies = inspect(output)
            print(image_info.decode().strip())
            print(dependencies.decode().strip())
            actual = run(str(output), "data 한글.txt", canonical_cwd,
                         cwd=workspace, input=b"hello")
            assert actual == b"hello!\n", actual
            assert (workspace / "data 한글.txt").read_bytes() == b"hello!"
        assert run(str(XEN), "run", str(source), target, "--", "run.txt", canonical_cwd,
                   cwd=workspace, input=b"hello") == b"hello!\n"
        assert b"1 passed; 0 failed" in run(str(XEN), "test", str(source), target,
                                              cwd=workspace)

        # A native compiler must choose Darwin when --target is omitted.
        run(str(XEN), "check", str(source), cwd=workspace)
        assert run(str(XEN), "run", str(source), "--", "default.txt", canonical_cwd,
                   cwd=workspace, input=b"hello") == b"hello!\n"

        entries = workspace / "entries"
        entries.mkdir()
        expected_names = {f"entry-{index:04d}-abcdefghij" for index in range(320)}
        for name in expected_names:
            (entries / name).write_bytes(b"")
        directory_source = workspace / "directory.xen"
        directory_source.write_text('''
use std.fs;
fn main() {
    let names = match std.fs.read_dir("entries") { Result.Ok(value) => value, _ => [] };
    for index in 0..names.len() { println(names.get(index)); }
}
''')
        directory_output = workspace / "directory-app"
        run(str(XEN), "build", str(directory_source), target, "-o", str(directory_output),
            cwd=workspace)
        inspect(directory_output)
        actual_names = run(str(directory_output), cwd=workspace).decode().splitlines()
        assert len(actual_names) == len(expected_names) and set(actual_names) == expected_names

        fixture_source = workspace / "runtime-fixture.xen"
        fixture_source.write_text('''
struct Boxed { value: Int }
#![bb]
fn main() {
    let value = box(Boxed { value: 42 });
    println(value.as_ref().value);
    let pointer = raw_alloc<Int>(1);
    raw_store(pointer, 0, 17);
    println(raw_load(pointer, 0));
    raw_free(pointer);
    let mut file = open_write("fixture.txt"); file.write("data"); file.close();
    println(read_text("fixture.txt"));
    let ints = read_ints("integers");
    assert(ints.len() == 2 && ints[0] == 1 && ints[1] == -2);
    let floats = read_floats("floats");
    assert(floats.len() == 2 && floats[0] == 1.5 && floats[1] == -0.25);
    println("fixture-ok");
}
''')
        (workspace / "integers").write_text("1 -2")
        (workspace / "floats").write_text("1.5 -0.25")
        fixture_image = workspace / "runtime-fixture"
        run(str(ROOT / "_build/default/tests/darwin_fixture.exe"),
            str(fixture_source), str(fixture_image), cwd=workspace)
        inspect(fixture_image)
        assert run(str(fixture_image), cwd=workspace) == b"42\n17\ndata\nfixture-ok\n"

        run(sys.executable, "-m", "packaging.cli", "--platform", "macos",
            "--architecture", "aarch64", "--formats", "tar.gz", cwd=ROOT)
        archive = ROOT / "dist" / f"xen-{VERSION}-macos-aarch64.tar.gz"
        with tarfile.open(archive) as bundle:
            bundle.extractall(workspace / "unpacked", filter="data")
        relocated = workspace / "relocated 배포 space"
        (workspace / "unpacked" / archive.name[:-7]).rename(relocated)
        installed = relocated / "bin/xen"
        inspect(installed)
        environment = dict(os.environ, PATH=f"{relocated / 'bin'}:/usr/bin:/bin")
        environment.pop("XEN_STDLIB_ROOT", None)
        assert run(str(installed), "version", cwd=workspace, env=environment) == f"xen {VERSION}\n".encode()
        assert run("xen", "version", cwd=workspace, env=environment) == f"xen {VERSION}\n".encode()
        run("xen", "check", str(source), cwd=workspace, env=environment)
        assert b"2 passed; 0 failed" in run("xen", "test", "std.platform",
                                              cwd=workspace, env=environment)
        output = workspace / "relocated-app"
        run(str(installed), "build", str(source), "-o", str(output),
            cwd=workspace, env=environment)
        inspect(output)
        assert run(str(output), "relocated.txt", canonical_cwd,
                   cwd=workspace, input=b"hello") == b"hello!\n"
        assert run("xen", "run", str(source), "--", "installed.txt", canonical_cwd,
                   cwd=workspace, env=environment, input=b"hello") == b"hello!\n"
        assert b"1 passed; 0 failed" in run("xen", "test", str(source),
                                              cwd=workspace, env=environment)
        assert (relocated / "stdlib/platform/aarch64-macos/std/platform.xen").is_file()
        bundled = relocated / "stdlib"
        hidden = relocated / "stdlib-hidden"
        bundled.rename(hidden)
        try:
            missing = subprocess.run(["xen", "check", str(source)], cwd=workspace,
                                     env=environment, capture_output=True, timeout=30)
            assert missing.returncode != 0 and b"stdlib" in missing.stderr.lower(), missing.stderr
        finally:
            hidden.rename(bundled)
        print(f"Apple Silicon native and relocated package validation passed: {archive}")


if __name__ == "__main__":
    main()
