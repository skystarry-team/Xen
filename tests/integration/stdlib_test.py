# SPDX-License-Identifier: MIT OR Apache-2.0
"""Small Linux stdlib integration tests through the unchanged native pipeline."""
import json
import os
from pathlib import Path
import resource
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
XEN = REPO / "compiler/dist/xen"


class StdlibTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xen-stdlib-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def run_source(self, source, data=b"", limit=None, memory_limit=None):
        path = self.root / "app.xen"
        path.write_text(source)
        def restrict():
            if limit:
                _, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
                resource.setrlimit(resource.RLIMIT_NOFILE, (limit, hard))
            if memory_limit:
                _, hard = resource.getrlimit(resource.RLIMIT_AS)
                resource.setrlimit(resource.RLIMIT_AS, (memory_limit, hard))
        command = [str(XEN), "run", str(path)]
        if memory_limit:
            executable = self.root / "app"
            built = subprocess.run([str(XEN), "build", str(path), "-o", str(executable)],
                                   cwd=self.root, capture_output=True, timeout=30)
            self.assertEqual(built.returncode, 0, built.stderr.decode(errors="replace"))
            command = [str(executable)]
        result = subprocess.run(command, cwd=self.root,
                                input=data, capture_output=True, timeout=30,
                                preexec_fn=restrict if limit or memory_limit else None)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        return result.stdout

    def test_string_byte_contracts(self):
        def literal(data):
            return "[" + ",".join(map(str, data)) + "]"

        texts = [b"", b"a", b"ababa", b"=a==", b"\0\xff\0", "é".encode(), bytes([0, 127, 128, 254, 255])]
        needles = [b"", b"a", b"aba", b"ba", b"abcdef", b"\0\xff", b"\xff", b"\xa9"]
        for index, text in enumerate(texts):
            body = []
            body.append(f"let bytes{index}:Vec<U8>={literal(text)};let text{index}=bytes{index}.into_string();")
            for needle in needles:
                body.append(f"{{let n:Vec<U8>={literal(needle)};let needle=n.into_string();")
                position = text.find(needle)
                pattern = f"Option.Some({position})" if position >= 0 else "Option.None"
                body.append(f"assert(match std.string.find(text{index},needle){{{pattern}=>true,_=>false}});")
                body.append(f"assert(std.string.contains(text{index},needle)=={'true' if position >= 0 else 'false'});}}")
            ranges = [(0, 0), (0, len(text)), (len(text), len(text)), (-1, 0),
                      (0, -1), (2, 1), (0, len(text) + 1), (0, 9223372036854775807)]
            if text:
                ranges.append((len(text) - 1, len(text)))
            for start, end in ranges:
                body.append(f"{{let result=std.string.slice_bytes(text{index},{start},{end});")
                if 0 <= start <= end <= len(text):
                    body.append(f"let expected:Vec<U8>={literal(text[start:end])};")
                    body.append("assert(match result{Result.Ok(value)=>value==expected.into_string(),_=>false});}")
                else:
                    body.append("assert(match result{Result.Err(std.string.BoundsError.InvalidRange((a,b,n)))=>"
                                f"a=={start} && b=={end} && n=={len(text)},_=>false}});}}")
            for separator in [0, 61, 195, 255]:
                expected = text.split(bytes([separator]))
                body.append(f"{{let parts=std.string.split_byte(text{index},u8({separator}));assert(parts.len()=={len(expected)});")
                for part, value in enumerate(expected):
                    body.append(f"{{let expected:Vec<U8>={literal(value)};assert(parts.get({part})==expected.into_string());}}")
                body.append("}")
            self.assertEqual(self.run_source("use std.string;fn main(){" + "".join(body) + "}"), b"")

    def test_string_repeated_cleanup(self):
        source = ('use std.string;fn main(){for pass in 0..12000{'
                  'let bytes:Vec<U8>=[97,0,255,61,98,61];let text=bytes.into_string();'
                  'let parts=std.string.split_byte(text,u8(61));assert(parts.len()==3);'
                  'let piece=match std.string.slice_bytes(text,1,3){Result.Ok(value)=>value,_=>"bad"};'
                  'assert(piece.len()==2);assert(std.string.contains(text,piece));'
                  'assert(match std.string.slice_bytes(text,-1,0){Result.Err(_)=>true,_=>false});}}')
        self.assertEqual(self.run_source(source, memory_limit=32 * 1024 * 1024), b"")

    def test_key_values_cli(self):
        example = REPO / "examples/key_values.xen"
        def run(data=b"", arguments=()):
            return subprocess.run([str(XEN), "run", str(example), "--", *arguments],
                                  cwd=self.root, input=data, capture_output=True, timeout=30)
        for data, expected in [(b"", b""), (b"\n", b""), (b"a=1\nb=\n", b"a: 1\nb: \n"),
                               (b"a=b=c", b"a: b=c\n"), (b"\nk=\0\xff\r\n\n", b"k: \0\xff\r\n")]:
            result = run(data)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, expected, b""))
        path = self.root / "entries"
        path.write_bytes(b"name=xen\n")
        result = run(arguments=(str(path),))
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"name: xen\n", b""))
        for data, message in [(b"good=1\nbad\n", b"missing '=' at line 2"), (b"=value", b"empty key at line 1")]:
            result = run(data)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b"")
            self.assertIn(message, result.stderr)
        result = run(arguments=(str(self.root / "missing"),))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"open", result.stderr.lower())

    def test_option_result_helpers(self):
        source = r'''
use std.option;
use std.result;

enum TinyError { Failed }
enum AppError { Wrapped(TinyError) }
struct Holder<U> { field: Option<U> }

fn eager_fallback() -> Int {
    print("f");
    return 9;
}

fn convert_error(error: TinyError) -> AppError {
    print("c");
    return AppError.Wrapped(error);
}

fn keep_box(error: Box<Int>) -> Box<Int> {
    return error;
}

fn from_int(error: Int) -> Int {
    return error;
}

fn map_ok<T>(value: T) -> Result<T, Int> {
    return std.result.map_err(Result<T, Int>.Ok(value), from_int);
}

fn map_ok_stored<T>(value: T) -> Result<T, Int> {
    let wrapped = Result<T, Int>.Ok(value);
    return std.result.map_err(wrapped, from_int);
}

fn identity<U>(value: U) -> U {
    return value;
}

fn wrap_identity<T>(value: T) -> Option<T> {
    return identity(Option<T>.Some(value));
}

fn map_conditional<T>(value: T, failed: Bool) -> Result<T, Int> {
    return std.result.map_err(
        if failed { Result<T, Int>.Err(1) } else { Result<T, Int>.Ok(value) },
        from_int
    );
}

fn wrap_holder<T>(value: T) -> Holder<T> {
    return Holder { field: Option<T>.Some(value) };
}

fn wrap_holder_explicit<T>(value: T) -> Holder<T> {
    return Holder<T> { field: Option<T>.Some(value) };
}

fn wrap_nested<T>(value: T) -> Option<Option<T>> {
    let nested = Option.Some(Option<T>.Some(value));
    return nested;
}

fn wrap_nested_explicit<T>(value: T) -> Option<Option<T>> {
    return Option<Option<T>>.Some(Option<T>.Some(value));
}

fn main() {
    let some = std.option.unwrap_or(Option<Int>.Some(7), eager_fallback());
    let none = std.option.unwrap_or(Option<Int>.None, eager_fallback());
    assert(some == 7 && none == 9);

    let ok = std.result.map_err(Result<Int, TinyError>.Ok(5), convert_error);
    assert(match ok { Result.Ok(value) => value == 5, _ => false });
    let stored = Result<I32, TinyError>.Ok(6);
    let mapped_stored = std.result.map_err(stored, convert_error);
    assert(match mapped_stored { Result.Ok(value) => value == i32(6), _ => false });
    let err = std.result.map_err(
        Result<String, TinyError>.Err(TinyError.Failed), convert_error
    );
    assert(match err { Result.Err(AppError.Wrapped(TinyError.Failed)) => true, _ => false });

    let int_direct = map_ok(8);
    assert(match int_direct { Result.Ok(value) => value == 8, _ => false });
    let int_stored = map_ok_stored(9);
    assert(match int_stored { Result.Ok(value) => value == 9, _ => false });
    let string_direct = map_ok("direct");
    assert(match string_direct { Result.Ok(value) => value == "direct", _ => false });
    let string_stored = map_ok_stored("stored");
    assert(match string_stored { Result.Ok(value) => value == "stored", _ => false });
    let box_direct = map_ok(box(10));
    assert(match box_direct { Result.Ok(value) => value.into_inner() == 10, _ => false });
    let box_stored = map_ok_stored(box(11));
    assert(match box_stored { Result.Ok(value) => value.into_inner() == 11, _ => false });

    let identity_int = wrap_identity(12);
    assert(match identity_int { Option.Some(value) => value == 12, _ => false });
    let identity_string = wrap_identity("generic");
    assert(match identity_string { Option.Some(value) => value == "generic", _ => false });
    let identity_box = wrap_identity(box(13));
    assert(match identity_box { Option.Some(value) => value.into_inner() == 13, _ => false });

    let conditional_int = map_conditional(14, false);
    assert(match conditional_int { Result.Ok(value) => value == 14, _ => false });
    let conditional_string = map_conditional("if", false);
    assert(match conditional_string { Result.Ok(value) => value == "if", _ => false });
    let conditional_box = map_conditional(box(15), false);
    assert(match conditional_box { Result.Ok(value) => value.into_inner() == 15, _ => false });
    assert(match map_conditional(box(16), true) {
        Result.Err(error) => error == 1,
        _ => false,
    });

    let holder_int = wrap_holder(17);
    assert(match holder_int.field { Option.Some(value) => value == 17, _ => false });
    let holder_int_explicit = wrap_holder_explicit(18);
    assert(match holder_int_explicit.field { Option.Some(value) => value == 18, _ => false });
    let holder_string = wrap_holder("holder");
    assert(match holder_string.field { Option.Some(value) => value == "holder", _ => false });
    let holder_string_explicit = wrap_holder_explicit("explicit");
    assert(match holder_string_explicit.field { Option.Some(value) => value == "explicit", _ => false });
    let holder_box = wrap_holder(box(19));
    assert(match holder_box.field { Option.Some(value) => value.into_inner() == 19, _ => false });
    let holder_box_explicit = wrap_holder_explicit(box(20));
    assert(match holder_box_explicit.field { Option.Some(value) => value.into_inner() == 20, _ => false });

    assert(match wrap_nested(21) {
        Option.Some(Option.Some(value)) => value == 21,
        _ => false,
    });
    assert(match wrap_nested_explicit(22) {
        Option.Some(Option.Some(value)) => value == 22,
        _ => false,
    });
    assert(match wrap_nested("nested") {
        Option.Some(Option.Some(value)) => value == "nested",
        _ => false,
    });
    assert(match wrap_nested_explicit("nested explicit") {
        Option.Some(Option.Some(value)) => value == "nested explicit",
        _ => false,
    });
    assert(match wrap_nested(box(23)) {
        Option.Some(Option.Some(value)) => value.into_inner() == 23,
        _ => false,
    });
    assert(match wrap_nested_explicit(box(24)) {
        Option.Some(Option.Some(value)) => value.into_inner() == 24,
        _ => false,
    });

    for pass in 0..20000 {
        let some_box = std.option.unwrap_or(
            Option<Box<Int>>.Some(box(3)), box(4)
        );
        assert(some_box.into_inner() == 3);
        let none_box = std.option.unwrap_or(Option<Box<Int>>.None, box(5));
        assert(none_box.into_inner() == 5);
        let boxed = std.result.map_err(
            Result<Int, Box<Int>>.Err(box(6)), keep_box
        );
        assert(match boxed { Result.Err(value) => value.into_inner() == 6, _ => false });
        let boxed_ok = std.result.map_err(
            Result<Box<Int>, Box<Int>>.Ok(box(7)), keep_box
        );
        assert(match boxed_ok { Result.Ok(value) => value.into_inner() == 7, _ => false });
    }
    print("ok");
}
'''
        self.assertEqual(self.run_source(source, memory_limit=32 * 1024 * 1024), b"ffcok")

    def test_path_contracts(self):
        cases = [("basename", "", ""), ("dirname", "", "."),
                 ("basename", "/", "/"), ("dirname", "///", "/"),
                 ("basename", "a/b///", "b"), ("dirname", "a/b///", "a"),
                 ("dirname", "leaf", "."), ("basename", "///", "/"),
                 ("dirname", "/leaf", "/"), ("dirname", "a//b", "a"),
                 ("basename", "a/\ud55c\uae00", "\ud55c\uae00")]
        body = "".join(f"assert(std.path.{fn}({json.dumps(path, ensure_ascii=False)})=="
                       f"{json.dumps(expected, ensure_ascii=False)});" for fn, path, expected in cases)
        for left, right, expected in [("", "a", "a"), ("a", "", "a"),
                                      ("a", "/b", "/b"), ("a/", "b", "a/b"),
                                      ("a", "../b", "a/../b"), ("a", "b", "a/b")]:
            body += f"assert(std.path.join({json.dumps(left)},{json.dumps(right)})=={json.dumps(expected)});"
        body += 'assert(std.path.is_absolute("/a"));assert(!std.path.is_absolute(""));assert(!std.path.is_absolute("a"));'
        body += 'assert(std.path.byte_part("abc",4,4)=="");assert(std.path.byte_part("abc",3,1)=="");'
        self.assertEqual(self.run_source("use std.path;fn main(){" + body + "}"), b"")

    def test_io_binary_and_errors(self):
        source = ('use std.io;fn main(){let text=match std.io.read_stdin(){'
                  'Result.Ok(value)=>value,Result.Err(_)=>"bad"};std.io.write_stdout(text);'
                  'assert(match std.io.read_fd(-1){Result.Err(std.io.IoError.Read(9))=>true,_=>false});'
                  'assert(match std.io.write_fd(-1,"x"){Result.Err(std.io.IoError.Write(9))=>true,_=>false});}')
        self.assertEqual(self.run_source(source, b"a\0\xff\n"), b"a\0\xff\n")
        self.assertEqual(self.run_source(source, b""), b"")

    def test_append_metadata_and_errors(self):
        path = self.root / "bytes"
        path.write_bytes(b"a\0")
        (self.root / "link").symlink_to(path)
        source = ('use std.fs;use std.io;fn main(){'
                  'let bytes:Vec<U8>=[255,10];assert(match std.fs.append("bytes",bytes.into_string()){Result.Ok(2)=>true,_=>false});'
                  'assert(match std.fs.append("bytes",""){Result.Ok(0)=>true,_=>false});'
                  'assert(match std.fs.append("created","new"){Result.Ok(3)=>true,_=>false});'
                  'let info=match std.fs.metadata("link"){Result.Ok(value)=>value,Result.Err(_)=>std.fs.Metadata{size:-1,modified_seconds:0,is_file:false,is_directory:false}};'
                  'assert(info.is_file && !info.is_directory && info.size==4);'
                  'assert(match std.fs.metadata("."){Result.Ok(m)=>m.is_directory && !m.is_file,_=>false});'
                  'assert(match std.fs.metadata("missing"){Result.Err(std.io.IoError.Metadata(2))=>true,_=>false});'
                  'assert(match std.fs.append("missing/child","x"){Result.Err(std.io.IoError.Open(2))=>true,_=>false});'
                  'let nul:Vec<U8>=[97,0,98];assert(match std.fs.metadata(nul.into_string()){Result.Err(std.io.IoError.InvalidPath)=>true,_=>false});'
                  'println(info.modified_seconds);}')
        output = self.run_source(source)
        self.assertEqual(path.read_bytes(), b"a\0\xff\n")
        self.assertEqual((self.root / "created").read_bytes(), b"new")
        self.assertEqual(int(output), int(path.stat().st_mtime))

    def test_directory_batches_and_cleanup(self):
        directory = self.root / "entries"
        directory.mkdir()
        expected = {f"entry-{i:04}-abcdefghijklmnop" for i in range(400)}
        for name in expected:
            (directory / name).touch()
        source = ('use std.fs;use std.io;fn main(){'
                  'for pass in 0..48{assert(match std.fs.read_dir("entries"){Result.Ok(names)=>names.len()==400,_=>false});'
                  'assert(match std.fs.read_dir("missing"){Result.Err(std.io.IoError.Open(2))=>true,_=>false});'
                  'let fd=match std.fs.open_path("app.xen",0,0){Result.Ok(value)=>value,_=>-1};'
                  'assert(match std.fs.read_directory_fd(fd){Result.Err(std.io.IoError.Directory(20))=>true,_=>false});'
                  'std.fs.close_fd(fd);assert(match std.fs.read_dir("app.xen"){Result.Err(_)=>true,_=>false});}'
                  'let names=match std.fs.read_dir("entries"){Result.Ok(value)=>value,_=>[]};'
                  'for index in 0..names.len(){println(names.get(index));}}')
        self.assertEqual(set(self.run_source(source, limit=32).decode().splitlines()), expected)

    def test_directory_decoder_boundaries(self):
        good = [0] * 24
        good[16], good[19] = 24, 97
        bad = [[0] * 19, [0] * 20, [0] * 24, [1] * 20]
        bad[2][16] = 25
        bad[3][16], bad[3][17] = 20, 0
        body = ""
        for index, data in enumerate(bad):
            body += f"let b{index}:Vec<U8>=[{','.join(map(str,data))}];"
            body += f"assert(match std.fs.decode_directory(b{index}.as_slice()){{Result.Err(std.io.IoError.InvalidDirectoryEntry)=>true,_=>false}});"
        body += f"let good:Vec<U8>=[{','.join(map(str,good))}];"
        body += 'assert(match std.fs.decode_directory(good.as_slice()){Result.Ok(names)=>names.len()==1 && names.get(0)=="a",_=>false});'
        self.run_source("use std.fs;use std.io;fn main(){" + body + "}")

    def test_cwd_and_process_identity(self):
        source = ('use std.env;use std.process;fn main(){assert(std.process.id()>0);'
                  'assert(std.process.parent_id()>0);println(match std.env.cwd(){Result.Ok(path)=>path,_=>"bad"});}')
        self.assertEqual(self.run_source(source), str(self.root).encode() + b"\n")

    def test_deleted_cwd_error(self):
        source = self.root / "cwd.xen"
        source.write_text('use std.env;use std.io;fn main(){println(match std.env.cwd(){'
                          'Result.Err(std.io.IoError.Cwd(code))=>code,_=>0});}')
        output = self.root / "cwd-test"
        built = subprocess.run([str(XEN), "build", str(source), "-o", str(output)],
                               capture_output=True, timeout=30)
        self.assertEqual(built.returncode, 0, built.stderr)
        vanished = self.root / "vanished"
        vanished.mkdir()
        result = subprocess.run([str(output)], cwd=vanished,
                                preexec_fn=lambda: os.rmdir(vanished),
                                capture_output=True, timeout=10)
        self.assertEqual((result.returncode, result.stdout), (0, b"2\n"))


if __name__ == "__main__":
    unittest.main()
