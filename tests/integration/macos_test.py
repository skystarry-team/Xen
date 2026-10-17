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
    import struct
    data = image.read_bytes()[:16]
    assert len(data) == 16 and data[:4] == b"\xcf\xfa\xed\xfe", image
    assert struct.unpack_from("<I", data, 4)[0] == 0x0100000c, image
    assert struct.unpack_from("<I", data, 12)[0] == 2, image
    run("codesign", "--verify", "--strict", str(image))
    dependencies = run("otool", "-L", str(image))
    for line in dependencies.decode().splitlines()[1:]:
        dependency = line.strip().split(" (", 1)[0]
        assert dependency.startswith(("/usr/lib/", "/System/Library/Frameworks/")), dependency
    return run("file", str(image)), dependencies


def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        sys.exit("macOS suite requires a native Apple Silicon host")
    assert run(str(XEN), "version") == f"xen {VERSION}\n".encode()
    inspect(XEN)
    with tempfile.TemporaryDirectory(prefix="xen-macos-native-") as temporary:
        workspace = Path(temporary) / "space 한글"
        workspace.mkdir()
        source = workspace / "app.xen"
        source.write_text('''
use std.io;
use std.fs;
use std.env;
use std.process;
test fn selected() { assert(std.process.id() > 0 && std.process.parent_id() > 0); }
fn main() {
    assert(std.process.id() > 0 && std.process.parent_id() > 0);
    assert(match std.env.cwd() { Result.Ok(path) => path.len() > 0, _ => false });
    let input = match std.io.read_stdin() { Result.Ok(text) => text, _ => "bad" };
    let path = arg(0);
    assert(match std.fs.write(path, input) { Result.Ok(5) => true, _ => false });
    assert(match std.fs.append(path, "!") { Result.Ok(1) => true, _ => false });
    assert(match std.fs.metadata(path) { Result.Ok(m) => m.is_file && m.size == 6, _ => false });
    assert(match std.fs.read_dir(".") { Result.Ok(names) => names.len() > 0, _ => false });
    assert(match std.fs.read("missing") { Result.Err(std.io.IoError.Open(2)) => true, _ => false });
    let mut file = open_write("builtin.txt"); file.write("ok"); file.close();
    assert(read_text("builtin.txt") == "ok");
    println(match std.fs.read(path) { Result.Ok(text) => text, _ => "bad" });
}
''')
        target = "--target=aarch64-macos"
        run(str(XEN), "check", str(source), target, cwd=workspace)
        for optimization in ("off", "basic"):
            output = workspace / ("app-" + optimization)
            run(str(XEN), "build", str(source), target, f"--opt={optimization}",
                "-o", str(output), cwd=workspace)
            image_info, dependencies = inspect(output)
            print(image_info.decode().strip())
            print(dependencies.decode().strip())
            actual = run(str(output), "data 한글.txt", cwd=workspace, input=b"hello")
            assert actual == b"hello!\n", actual
            assert (workspace / "data 한글.txt").read_bytes() == b"hello!"
        assert run(str(XEN), "run", str(source), target, "--", "run.txt",
                   cwd=workspace, input=b"hello") == b"hello!\n"
        assert b"1 passed; 0 failed" in run(str(XEN), "test", str(source), target,
                                              cwd=workspace)

        # A native compiler must choose Darwin when --target is omitted.
        run(str(XEN), "check", str(source), cwd=workspace)
        assert run(str(XEN), "run", str(source), "--", "default.txt",
                   cwd=workspace, input=b"hello") == b"hello!\n"

        run(sys.executable, "-m", "packaging.cli", "--platform", "macos",
            "--architecture", "aarch64", "--formats", "tar.gz", cwd=ROOT)
        archive = ROOT / "dist" / f"xen-{VERSION}-macos-aarch64.tar.gz"
        with tarfile.open(archive) as bundle:
            bundle.extractall(workspace / "unpacked", filter="data")
        relocated = workspace / "relocated 배포 space"
        (workspace / "unpacked" / archive.name[:-7]).rename(relocated)
        installed = relocated / "bin/xen"
        inspect(installed)
        environment = dict(os.environ, PATH="/usr/bin:/bin")
        environment.pop("XEN_STDLIB_ROOT", None)
        assert run(str(installed), "version", cwd=workspace, env=environment) == f"xen {VERSION}\n".encode()
        run(str(installed), "check", str(source), cwd=workspace, env=environment)
        output = workspace / "relocated-app"
        run(str(installed), "build", str(source), "-o", str(output),
            cwd=workspace, env=environment)
        inspect(output)
        assert run(str(output), "relocated.txt", cwd=workspace, input=b"hello") == b"hello!\n"
        assert run(str(installed), "run", str(source), "--", "installed.txt",
                   cwd=workspace, env=environment, input=b"hello") == b"hello!\n"
        assert b"1 passed; 0 failed" in run(str(installed), "test", str(source),
                                              cwd=workspace, env=environment)
        assert (relocated / "stdlib/platform/aarch64-macos/std/platform.xen").is_file()
        print(f"Apple Silicon native and relocated package validation passed: {archive}")


if __name__ == "__main__":
    main()
