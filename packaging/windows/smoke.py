# SPDX-License-Identifier: MIT OR Apache-2.0
"""Exercise an extracted, relocated Windows ZIP without build tools on PATH."""
import argparse
import os
from pathlib import Path, PurePosixPath
import platform
import struct
import subprocess
import tempfile
import zipfile

from packaging.common import binary_architecture, validate_version
from packaging.windows.pe import inspect


def verify(archive_path: Path, version: str) -> None:
    if os.name != "nt" or platform.machine().lower() not in ("amd64", "x86_64"):
        raise ValueError("Windows ZIP execution requires a native Windows x86_64 host")
    validate_version(version)
    with tempfile.TemporaryDirectory(prefix="xen-installed-공백 ") as directory:
        root = Path(directory)
        extracted = root / "extracted"
        with zipfile.ZipFile(archive_path) as archive:
            names = archive.namelist()
            prefix = f"xen-{version}-windows-x86_64"
            if len(names) != len(set(names)):
                raise ValueError("duplicate ZIP entries")
            for name in names:
                parts = PurePosixPath(name).parts
                if (not parts or parts[0] != prefix or any(p in ("..", ".") or ":" in p for p in parts)
                        or "\\" in name or name.startswith("/")):
                    raise ValueError("invalid Windows ZIP path")
            archive.extractall(extracted)
        installed = root / "옮긴 설치 😀"
        (extracted / prefix).rename(installed)
        extracted.rmdir()  # Original extraction path must no longer work.
        binary = installed / "bin/xen.exe"
        print("Packaged compiler DLLs:", sorted(inspect(binary)))
        if (installed / "VERSION").read_text(encoding="utf-8") != version+"\n":
            raise ValueError("ZIP VERSION mismatch")
        work = root / "작업 디렉터리"
        work.mkdir()
        temporary = root / "temporary"
        temporary.mkdir()
        system = Path(os.environ["SystemRoot"])
        # Explicitly exclude opam, OCaml, Cygwin, MinGW, Python and inherited
        # stdlib/DLL overrides. Python only orchestrates child processes here.
        environment = dict(SystemRoot=str(system), WINDIR=str(system),
                           ComSpec=str(system / "System32/cmd.exe"),
                           PATH=os.pathsep.join((str(binary.parent), str(system / "System32"))),
                           PATHEXT=".COM;.EXE;.BAT;.CMD", TEMP=str(temporary), TMP=str(temporary))

        def invoke(*args, executable=binary, success=True):
            result = subprocess.run([str(executable), *map(str, args)], cwd=work,
                                    env=environment, capture_output=True, timeout=90)
            if success and result.returncode:
                raise ValueError(f"installed command failed: {args}: {result.returncode}\n"
                                 f"{result.stdout!r}\n{result.stderr!r}")
            return result

        if invoke("version").stdout.splitlines() != [f"xen {version}".encode()]:
            raise ValueError("installed compiler version mismatch")
        # CreateProcess searches the parent's PATH; constrain it for this launch.
        previous_path = os.environ.get("PATH")
        try:
            os.environ["PATH"] = environment["PATH"]
            invoke("version", executable="xen.exe")
        finally:
            if previous_path is None:
                os.environ.pop("PATH", None)
            else:
                os.environ["PATH"] = previous_path
        source = work / "hello 한글.xen"
        source.write_text(
            'use std.fs;use std.io;use std.env;use std.process;fn main(){'
            'assert(std.env.args().len()==1);assert(std.process.id()>0);'
            'assert(match std.env.cwd(){Result.Ok(p)=>len(p)>0,_=>false});'
            'assert(match std.fs.write(arg(0),"한글😀"){Result.Ok(10)=>true,_=>false});'
            'assert(match std.fs.read(arg(0)){Result.Ok(s)=>s=="한글😀",_=>false});'
            'assert(match std.fs.metadata(arg(0)){Result.Ok(m)=>m.is_file && m.size==10,_=>false});'
            'assert(match std.fs.read_dir("."){Result.Ok(v)=>v.len()>0,_=>false});'
            'std.io.write_stdout("zip-ok 😀\\n");}', encoding="utf-8")
        payload = work / "내용 😀.txt"
        invoke("check", source)
        for opt in ("off", "basic"):
            invoke("build", source, f"--opt={opt}")
            executable = work / "a.exe"
            inspect(executable)
            if invoke(payload, executable=executable).stdout != "zip-ok 😀\n".encode():
                raise ValueError("installed compiler output execution mismatch")
            if invoke("run", source, f"--opt={opt}", "--", payload).stdout != "zip-ok 😀\n".encode():
                raise ValueError("installed compiler run mismatch")
            if payload.read_bytes() != "한글😀".encode():
                raise ValueError("installed compiler file I/O mismatch")
            result = invoke("test", "std.fs", "--filter", "null", f"--opt={opt}")
            if b"1 passed; 0 failed" not in result.stdout:
                raise ValueError("installed compiler test mismatch")
        for target in ("x86_64", "aarch64"):
            output = work / target
            invoke("build", source, f"--target={target}-linux", "-o", output)
            if binary_architecture(output) != target:
                raise ValueError("installed compiler cross target mismatch")
        # Missing the bundle must fail even though the source repository exists.
        library = installed / "stdlib"
        hidden = root / "hidden-library"
        library.rename(hidden)
        try:
            rejected = invoke("check", source, success=False)
            if rejected.returncode == 0 or b"bundled stdlib not found" not in rejected.stderr:
                raise ValueError("installed compiler unexpectedly found another stdlib")
        finally:
            hidden.rename(library)
    print("Windows ZIP relocation, isolated PATH and check/build/run/test passed")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    try:
        verify(args.archive, args.version)
    except (OSError, ValueError, struct.error, zipfile.BadZipFile, subprocess.SubprocessError) as error:
        parser.exit(1, f"windows-package: {error}\n")


if __name__ == "__main__":
    main()
