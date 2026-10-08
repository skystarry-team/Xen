# Standard library reference

The `std.*` modules are Xen source shipped with the compiler and go through the normal
type, ownership, and native compilation pipeline. Import them with `use std.name;` and
call functions by their qualified names. These higher-level calls do not require the
caller's `bb` or `explc` capability. Strings and paths are byte sequences without
UTF-8 validation.

## `std.convert`

`parse_int(text) -> Result<Int, ParseIntError>` parses signed decimal integers across
the full `I64` range. It accepts an optional leading `+` or `-` and one or more ASCII
digits. It does not trim whitespace. Errors are `Empty`, `InvalidDigit((Int, U8))` with
the byte offset and byte value, and `Overflow`. `format_int(value)` returns canonical
decimal without a leading `+` or unnecessary zeroes.

```xen
use std.convert;

fn main() {
    let value = match std.convert.parse_int("-42") {
        Result.Ok(number) => number,
        Result.Err(_) => 0,
    };
    println(std.convert.format_int(value));
}
```

```console
$ compiler/dist/xen run convert.xen
-42
```

## `std.env` and `std.process`

`std.env.args() -> Vec<String>` returns program arguments in order and preserves empty
and non-UTF-8 byte strings. `std.env.cwd() -> Result<String, std.io.IoError>` returns
the absolute working directory or `IoError.Cwd(errno)`. `std.process.id() -> Int` and
`std.process.parent_id() -> Int` return the process and parent process IDs.

Environment-variable lookup, process spawning, waiting, and pipes are not available.

## `std.string` and `std.iter`

`std.string.is_ascii_whitespace(byte: U8) -> Bool` recognizes bytes `0x09` through
`0x0D` and `0x20`. `split_ascii_whitespace(text: String) -> Vec<String>` skips repeated,
leading, and trailing separators, so it does not produce empty tokens. NUL and other
bytes are preserved.

The following APIs use byte offsets and preserve NUL and invalid UTF-8:

| API | Contract |
| --- | --- |
| `slice_bytes(text: String, start: Int, end: Int) -> Result<String, BoundsError>` | Copies `[start,end)` into a new owned String; requires `0 <= start <= end <= len(text)` |
| `find(text: String, needle: String) -> Option<Int>` | First byte offset; empty needle returns `Some(0)`, missing needle returns `None` |
| `contains(text: String, needle: String) -> Bool` | Whether a match exists, including an empty needle |
| `split_byte(text: String, separator: U8) -> Vec<String>` | Splits on one byte and preserves leading, consecutive and trailing empty parts; empty input returns `[""]` |

Invalid extraction bounds return `BoundsError.InvalidRange((start, end, length))`;
an empty valid range returns `Ok("")`. Extraction may split a UTF-8 encoding and
does not validate or normalize it. Results own their bytes; no slice escapes. Ordinary
by-value String cloning still applies, including internal library calls. These APIs
do not provide a special borrowed calling convention. Allocation failures retain the
existing runtime error behavior.

```xen
use std.string;

fn main() {
    println(match std.string.find("name=xen", "=") {
        Option.Some(index) => index,
        Option.None => -1,
    });
    println(match std.string.slice_bytes("name=xen", 5, 8) {
        Result.Ok(value) => value,
        Result.Err(_) => "invalid range",
    });
}
```

This prints `4` and `xen`. The [key-value CLI example](../../examples/key_values.xen)
combines search, extraction, splitting and recoverable file I/O.

With `use std.iter;`, cloneable elements support `.iter()` on `Vec<T>` and `Slice<T>`.
`String.iter()` yields bytes; `Ptr<T>.iter()` follows the pointer's bounds descriptor.
Using a `Ptr<T>` still requires the caller's lexical `bb` capability. `.enumerate()`
consumes an iterator and yields `(Int, T)` pairs starting at zero.
Collections are not automatically converted for `for`, and consuming `into_iter()` for
move-only values is not available.

## `std.option` and `std.result`

| API | Contract |
| --- | --- |
| `std.option.unwrap_or<T>(value: Option<T>, fallback: T) -> T` | Returns the `Some` value or the fallback |
| `std.result.map_err<T, E, F>(value: Result<T, E>, convert: fn(E) -> F) -> Result<T, F>` | Preserves `Ok`; converts an `Err` payload |

Both helpers use ordinary by-value passing: cloneable values follow the existing copy or
clone rules, and move-only values move. The fallback to `unwrap_or` is evaluated before
the call, even when `value` is `Some`; an unused move-only fallback is dropped normally.
`map_err` invokes its concrete named function value once for `Err` and never for `Ok`,
passing the error payload by value under the same rules. These helpers do not add lazy
fallback, closures, generic function values, or implicit error conversion. Generic type
arguments follow the existing inference rules and must be explicit when static argument
types do not determine them.

After converting an error to the enclosing function's error type, the existing same-type
`?` can propagate it:

```xen
use std.fs;
use std.io;
use std.result;

enum AppError { Io(std.io.IoError) }

fn from_io(error: std.io.IoError) -> AppError {
    return AppError.Io(error);
}

fn read_config(path: String) -> Result<String, AppError> {
    let contents = std.result.map_err(std.fs.read(path), from_io)?;
    return Result.Ok(contents);
}
```

The [key-value CLI example](../../examples/key_values.xen) uses both helpers while
combining I/O and byte-range errors with parse errors in one `AppError`.

## `std.path`

These operations use Linux `/` separators and do not access the filesystem or normalize
`.` and `..`:

| API | Contract |
| --- | --- |
| `is_absolute(path: String) -> Bool` | True when the first byte is `/`; false for an empty path |
| `join(left: String, right: String) -> String` | An absolute right side wins; an empty side returns the other; otherwise joins with `/` |
| `basename(path: String) -> String` | Last component after ignoring trailing `/`; empty path gives `""`, root gives `"/"` |
| `dirname(path: String) -> String` | Parent before the last component; empty or single relative path gives `"."`, root gives `"/"` |

For example, `join("a", "../b")` returns `"a/../b"`; it does not resolve symlinks.

## `std.io`

`write_stdout(text: String) -> Result<Int, IoError>` and
`write_stderr(text: String) -> Result<Int, IoError>` complete partial writes and retry
`EINTR`. They return the number of bytes written. `read_stdin() -> Result<String,
IoError>` and `read_fd(fd: Int) -> Result<String, IoError>` read binary bytes through
EOF. `read_fd` leaves the caller's descriptor open. `write_fd(fd: Int, text: String)
-> Result<Int, IoError>` writes all bytes. `describe_error(error: IoError) -> String`
formats the current `IoError` variants.

## `std.fs`

The one-shot filesystem API returns `Result` and closes its descriptors before returning:

| API | Contract |
| --- | --- |
| `read(path: String) -> Result<String, IoError>` | Read the entire file to a byte-preserving string |
| `read_open(fd: Int) -> Result<String, IoError>` | Read an open descriptor; does not close the caller's descriptor |
| `write(path: String, contents: String) -> Result<Int, IoError>` | Truncate or create and write the full contents |
| `copy(source: String, destination: String) -> Result<Int, IoError>` | Read all source bytes, then write the destination |
| `append(path: String, contents: String) -> Result<Int, IoError>` | Append, creating the file when missing; multi-write atomicity is not guaranteed |
| `metadata(path: String) -> Result<Metadata, IoError>` | Follow symlinks and return metadata without requiring read permission |
| `read_dir(path: String) -> Result<Vec<String>, IoError>` | Return non-dot entry names in kernel order; does not recurse or sort |

`Metadata` has `size: Int`, `modified_seconds: Int` (seconds since the epoch),
`is_file: Bool`, and `is_directory: Bool`. `IoError` includes `InvalidPath`, `Open(Int)`,
`Read(Int)`, `Write(Int)`, `WriteZero`, `Close(Int)`, `Metadata(Int)`, `Directory(Int)`,
`Cwd(Int)`, and `InvalidDirectoryEntry`. All pathname APIs reject embedded NUL bytes.

## Toolchain modules

`core.intrinsics.size_of<T>()` and `align_of<T>()` return the concrete type's size and
alignment as `Int` constants. `core.box.Box<T>` and `core.box.new(value)` provide an
explicit owning indirection; see [Box and recursive data](box-and-recursive-aggregates.md).
