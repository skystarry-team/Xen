# File APIs

New code should generally use `std.fs` and `std.io`. These APIs return `Result` values,
keep file descriptors private, and clean up resources before returning. The older
`File` built-ins remain available for compatibility when a program needs an owned open
handle.

## Recoverable one-shot API

| API | Result and behavior |
| --- | --- |
| `std.fs.read(path)` | `Result<String, IoError>`; reads the whole file as bytes |
| `std.fs.write(path, contents)` | `Result<Int, IoError>`; truncates or creates, returns bytes written |
| `std.fs.copy(source, destination)` | `Result<Int, IoError>`; reads then writes the entire file |
| `std.fs.append(path, contents)` | `Result<Int, IoError>`; creates if absent and appends |
| `std.io.write_stdout(text)` | `Result<Int, IoError>`; writes all bytes to stdout |
| `std.io.write_stderr(text)` | `Result<Int, IoError>`; writes all bytes to stderr |

The `IoError` variants include `InvalidPath`, `Open(Int)`, `Read(Int)`, `Write(Int)`,
`WriteZero`, `Close(Int)`, and variants for metadata, directory, and cwd operations.
Errno payloads are positive Linux errno values. Use `std.io.describe_error(error)` to
make a message. Paths containing NUL are rejected before the syscall. The APIs retry
`EINTR` and complete partial writes. An operation error takes precedence over a close
error; if the operation succeeded but closing failed, the result reports the close
error.

`std.fs.write` truncates an existing file. New files use mode `0644` subject to the
process umask. These are blocking Linux x86-64 byte I/O APIs. Strings are not
UTF-8-validated. `std.fs.copy` holds the source contents in memory before writing.

The following program reads and prints a file, handling ordinary I/O failures as
values. Save it as `show_file.xen`:

```xen
module show_file;
use std.env;
use std.fs;
use std.io;

fn main() {
    let args = std.env.args();
    if args.len() != 1 { panic("usage: show_file <path>"); }
    let contents = match std.fs.read(args.get(0)) {
        Result.Ok(text) => text,
        Result.Err(error) => {
            assert_msg(false, std.io.describe_error(error));
            ""
        },
    };
    match std.io.write_stdout(contents) {
        Result.Ok(_) => (),
        Result.Err(error) => assert_msg(false, std.io.describe_error(error)),
    };
}
```

```console
$ printf 'hello from a file\n' > input.txt
$ compiler/dist/xen run show_file.xen -- input.txt
hello from a file
```

If `input.txt` cannot be opened, `std.fs.read` returns `Err`; the example converts it to
a runtime error with `assert_msg`. A program can instead report the error and return a
chosen status. See the [standard library reference](stdlib.md) for the remaining I/O
functions.

## Owned `File` compatibility API

`File` is an eight-byte, move-only owned resource for blocking byte I/O. Raw file
descriptors are not exposed. `open_read(path)` opens an existing file read-only;
`open_write(path)` truncates or creates a file with mode `0644` subject to umask.
`read()` consumes bytes from the current offset through EOF. `write(text)` writes the
string at the current offset. `close()` is idempotent, and an open file is closed when
its owner leaves scope.

`read`, `write`, and `close` need a mutable `File` receiver. `is_open` accepts a shared
receiver. Passing a File by value moves it; it cannot be printed, compared, placed in a
cloneable vector, or converted to an integer. Append mode and seek are not available.

Legacy open/read/write/close failures and operations on a closed handle terminate with
a runtime error and status 1. Recoverable new code should use `std.fs` and `std.io`.
