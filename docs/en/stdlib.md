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
Collections are not automatically converted for `for`. `Vec<T>.into_iter()` consumes
the vector, including a cloneable vector, and yields owned items in original order.
The iterator is move-only; early loop exit drops its remaining items.

## Iterator transformations

With `use std.iter;`, `.map(fn(T) -> U)` and `.filter(fn(&T) -> Bool)` construct lazy
adapters and consume their receiver. Concrete named functions are accepted; closures
are not. Creation executes no callback. Map passes each item by value; filter borrows
each yielded item during the predicate call and drops rejected items. Filter requires
a referable item type, so `Unit` is not supported. Both stop permanently at the first
`None`. A borrowed `.iter()` chain retains the source loan until its last use.

```xen
use std.iter;
fn twice(value: Int) -> Int { return value * 2; }
#![explc]
fn large(value: &Int) -> Bool { return *value > 2; }
fn main() {
    let values = [1, 2, 3];
    for value in values.iter().map(twice).filter(large) { println(value); }
}
```

This prints `4` and `6`. An existing inherent `map`/`filter` method takes precedence
and does not require the iterator import. Predicate bodies provide their own `explc`;
adapter construction does not require that capability from the caller.

`std.iter.fold<I,T,A>(iterator, initial, step: fn(A,T) -> A) -> A` performs an ordered
left fold and returns initial for an empty iterator. Ordinary by-value clone/move
rules apply to the iterator, accumulator and callback arguments. `std.iter.collect<I,T>`
eagerly creates a `Vec<T>` in source order; specify all type arguments when T cannot
be inferred, for example `std.iter.collect<std.iter.IntoIter<Int>,Int>(values.into_iter())`.
In `for value in iterator`, a move-only iterator moves into loop ownership. A manual
while loop calling an outer iterator's `next()` can break and later resume that owner.

## HashMap and owned replacement

`use std.hashmap;` provides a move-only `std.hashmap.HashMap<V>` with String byte keys.
Empty keys, NUL and invalid UTF-8 bytes are valid; equality compares bytes. Hash
collisions are resolved by key equality. Iteration and key snapshots have unspecified
order. Hash-table operations have expected amortized constant probe counts; key hashing
also takes time proportional to byte length, and collisions can require a full scan.

| API | Behavior |
| --- | --- |
| `new<V>()`, `len()`, `is_empty()` | Create a map and inspect its entry count |
| `insert(key: String, value: V) -> Option<V>` | Replace a duplicate value and return the previous value; length stays unchanged |
| `remove(key: &String) -> Option<V>` | Transfer the removed value; absent key returns None |
| `contains_key(key: &String)` | Test presence without copying key/value |
| `get_cloned(key: &String) -> Option<V>` | Return an owned copy/clone; move-only values are rejected |
| `with_value<V,R>(&HashMap<V>, &String, fn(&V)->R) -> Option<R>` | Borrow a present value only during the callback; no reference can escape |
| `keys() -> Vec<String>`, `clear()` | Owned key snapshot; drop entries and empty the map |
| `into_iter()` | Consume the map and yield owned `(String,V)` entries |

Explicit reference arguments require `explc`. File and Box values support insertion,
replacement, removal and consuming iteration without cloning them. Discarding a
returned previous/removed value drops it normally. `Unit` supports storage and owned
lookup; reference callbacks and `(String,Unit)` entry iteration are unavailable under
the existing referability/tuple rules. There is no reference-returning get/get_mut.
Public struct fields are not private; use the map APIs to maintain table invariants.

```xen
use std.hashmap;
#![explc]
fn main() {
    let mut map = std.hashmap.new<Int>();
    map.insert("answer", 42);
    let key = "answer";
    println(match map.get_cloned(&key) { Option.Some(value) => value, _ => 0 });
}
```

`use std.mem;` provides `std.mem.replace<T>(&mut T, T) -> T`: install a prepared
replacement and return the previous owned value. `Vec.replace(index, value) -> T`
does the same for an element without changing length; `Vec.swap(left, right)` exchanges
elements without cloning or dropping them. Invalid indices terminate with a runtime error.

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
