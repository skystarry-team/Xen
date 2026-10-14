# Standard library

Import a module with `use std.name;` and optionally give it an alias with `as`. This page lists APIs commonly used in applications. `Int` is an integer, `String` contains bytes, and `IoError` means `std.io.IoError`.

## Text and numbers

| API | Result and purpose |
| --- | --- |
| `std.convert.parse_int(text: String)` | `Result<Int, ParseIntError>`; signed decimal parsing |
| `std.convert.format_int(value: Int)` | Decimal string |
| `std.string.find(text: String, needle: String)` | `Option<Int>`; first byte offset, or `None` |
| `std.string.contains(text: String, needle: String)` | `Bool`; whether a match exists |
| `std.string.slice_bytes(text: String, start: Int, end: Int)` | `Result<String, BoundsError>`; copy a range with an excluded end |
| `std.string.split_byte(text: String, separator: U8)` | `Vec<String>`; split at a byte, keeping empty parts |
| `std.string.split_ascii_whitespace(text: String)` | `Vec<String>`; split at ASCII whitespace, discarding empty parts |
| `std.string.is_ascii_whitespace(byte: U8)` | Whether the byte is a space or in the range 9–13 |

`parse_int` does not trim whitespace. An optional `+` or `-` must be followed by at least one digit. Errors are `ParseIntError.Empty`, `InvalidDigit((offset, byte))`, and `Overflow`. The standard library has no corresponding floating-point string parsing or formatting functions.

String positions and lengths count bytes. An empty search string gives `Some(0)` from `find` and `true` from `contains`. `slice_bytes` requires `0 <= start <= end <= text.len()`; otherwise it returns `BoundsError.InvalidRange((start, end, length))`. Splitting an empty string with `split_byte` gives one empty string.

## Arguments and paths

| API | Result and purpose |
| --- | --- |
| `std.env.args()` | `Vec<String>`; program arguments excluding the executable name |
| `std.env.cwd()` | `Result<String, IoError>`; working directory |
| `std.path.is_absolute(path: String)` | Whether the path starts with `/` |
| `std.path.join(left: String, right: String)` | Join paths; an absolute right side wins |
| `std.path.basename(path: String)` | Last path component |
| `std.path.dirname(path: String)` | Parent path; `"."` for a single relative filename |
| `std.process.id()`, `std.process.parent_id()` | Current and parent process IDs |

Path functions use `/` and do not access files, normalize `.` or `..`, or resolve symbolic links. Environment-variable lookup, process spawning, and pipe creation are unavailable.

## Files and input/output

| API | Return value |
| --- | --- |
| `std.fs.read(path: String)` | `Result<String, IoError>`; read the whole file |
| `std.fs.write(path: String, contents: String)` | `Result<Int, IoError>`; create or overwrite, returning bytes written |
| `std.fs.append(path: String, contents: String)` | `Result<Int, IoError>`; append, creating if absent |
| `std.fs.copy(source: String, destination: String)` | `Result<Int, IoError>`; read the whole source and overwrite the destination |
| `std.fs.metadata(path: String)` | `Result<std.fs.Metadata, IoError>` |
| `std.fs.read_dir(path: String)` | `Result<Vec<String>, IoError>`; immediate entry names |
| `std.io.read_stdin()` | `Result<String, IoError>`; read until the end of input |
| `std.io.write_stdout(text: String)`, `std.io.write_stderr(text: String)` | `Result<Int, IoError>`; bytes written |
| `std.io.describe_error(error: IoError)` | Human-readable error text |

Writing APIs change files. In particular, `write` and `copy` erase existing destination contents. Paths cannot contain NUL bytes. `read`, `copy`, and `read_stdin` hold the entire input in memory. Interactive stdin reading waits until input ends. Here is a pipeline example:

```xen
use std.io as io;
use std.string as text;

fn main() {
    let contents = match io.read_stdin() {
        Result.Ok(value) => value,
        Result.Err(error) => { panic(io.describe_error(error)); },
    };
    let words = text.split_ascii_whitespace(contents);
    for index in 0..words.len() {
        println(words.get(index));
    }
}
```

```console
$ printf 'one two\nthree\n' | xen run stdin_words.xen
one
two
three
```

`Metadata` has `size: Int`, `modified_seconds: Int`, `is_file: Bool`, and `is_directory: Bool`. Modification time is seconds since the Unix epoch. Metadata follows symbolic links. `read_dir` does not recurse, excludes `.` and `..`, and has unspecified ordering.

The `IoError` variants are `InvalidPath`, `Open(Int)`, `Read(Int)`, `Write(Int)`, `WriteZero`, `Close(Int)`, `Metadata(Int)`, `Directory(Int)`, `Cwd(Int)`, and `InvalidDirectoryEntry`. Use `describe_error` for a message to display.

## Dictionaries: HashMap

Use `std.hashmap.HashMap<V>` to look up values by string keys. Save this as `hashmap.xen`:

```xen
use std.hashmap as hashmap;

#![explc]
fn main() {
    let mut prices = hashmap.new<Int>();
    prices.insert("tea", 3);
    prices.insert("coffee", 4);
    let key = "tea";
    println(match prices.get_cloned(&key) {
        Option.Some(price) => price,
        Option.None => 0,
    });
    println(prices.len());
}
```

```console
$ xen run hashmap.xen
3
2
```

| Task | API |
| --- | --- |
| Create | `std.hashmap.new<V>()` |
| Count or check emptiness | `map.len()`, `map.is_empty()` |
| Insert or replace | `map.insert(key, value)`; returns the previous value as `Some` if present |
| Look up | `map.get_cloned(&key)`; returns a copy in an `Option` |
| Check presence | `map.contains_key(&key)` |
| Remove | `map.remove(&key)`; returns the removed value in an `Option` |
| List keys | `map.keys()`; an independent `Vec<String>` |
| Empty | `map.clear()` |
| Consume and iterate | `map.into_iter()`; `(String, V)` items |

The map itself is move-only. `get_cloned` cannot retrieve noncopyable values such as `Box` or `File`. Take them out with `remove`, or inspect them through `std.hashmap.with_value<V, R>(&map, &key, inspect)` using a named `fn(&V) -> R` callback. Explicit reference arguments require `explc`. Key lists and iteration have unspecified order. Use the APIs rather than changing map fields directly.

## Results, iterators, and replacement

`std.option.unwrap_or<T>(value, fallback)` chooses a default for a missing value. `std.result.map_err<T, E, F>(value, convert)` converts only errors. See [error handling](error-handling.md).

Add `use std.iter;` for `.iter()`, `.into_iter()`, `.map(...)`, `.filter(...)`, and `.enumerate()`. `std.iter.fold<I, T, A>(iterator, initial, step)` accumulates in order using a `fn(A, T) -> A` callback; empty input returns `initial`. `std.iter.collect<I, T>(iterator)` gathers items into a new vector. Supply all type arguments if they cannot be inferred. The [collections chapter](collections.md) includes a runnable example.

With `use std.mem;`, `std.mem.replace<T>(&mut target, value)` installs a new value and returns the old one. The explicit reference requires `explc`.

## Reading existing File code

`open_read(path)` and `open_write(path)` create a `File`. `open_write` creates or overwrites. On a mutable File, `read()` reads from the current position to the end, and `write(text)` writes at the current position. `close()` closes it and can be called repeatedly. `is_open()` reports its state. Files are move-only and close when leaving scope. Failures terminate the program, so prefer `std.fs` and `std.io` in new code that needs to handle failures. File has no seek or append methods.

---

[Contents](README.md) · [Previous: Testing your code](testing.md) · [Next: Command-line tools](cli.md) · [한국어](../ko/stdlib.md)
