# String, Vec, and Slice

## String

`String` is an immutable byte sequence, not a sequence of Unicode characters. `len("é")`
is `2` for the UTF-8 byte encoding. String literals support newline, tab, carriage
return, double quote, and backslash escapes. Strings preserve embedded NUL bytes and do
not require valid UTF-8. Indexing/slicing syntax and mutation are not supported.
[`std.string`](stdlib.md#stdstring-and-stditer) provides owned `slice_bytes`, byte
`find`/`contains`, and `split_byte` without changing this byte representation.

Concatenating two strings with `+` creates a new string and leaves both operands
available. `String.as_bytes()` creates a local-only `Slice<U8>` view. Consuming a
`Vec<U8>` with `into_string()` transfers its bytes to a string without UTF-8 validation.

## Vec

`Vec<T>` accepts concrete sized element types: scalar values, `Bool`, `Unit`, `String`,
`File`, concrete structs and enums, and nested vectors. References, `Slice`, `Ptr`, and
unresolved type variables cannot be vector elements.

```xen
fn main() {
    let mut values: Vec<Int> = [];
    values.push(10);
    values.push(20);
    values[0] = 11;
    values.set(1, 21);
    println(values.get(0));
    println(values.len());
    println(values.pop());
}
```

```console
$ compiler/dist/xen run vec.xen
11
2
21
```

The element type of an empty literal cannot be inferred, so annotate it, for example
`let mut values: Vec<Int> = [];`. Negative or out-of-range indices and `pop()` on an
empty vector are runtime errors. `set`, `push`, and `pop` need a mutable receiver; `len`
and `get` can use a shared receiver. Indexing and `get` cannot clone a move-only
element. `push`, `set`, and `pop` transfer ownership of such elements.

Element storage uses the element's actual size and alignment. Cloneable elements such as
strings and managed aggregates are deep-cloned when needed. A vector containing a
move-only value such as `File` is itself move-only. Equality is available for vectors
whose element types support equality: numeric types, `Bool`, `String`, and nested
vectors. Structs and enums do not have equality.

## Slice

`Vec<T>.as_slice()` and `Vec<T>.slice(start, end)` create a read-only `Slice<T>`. A
slice supports `len()`, `get(index)`, indexing, and `len(slice)`. Its bounds must satisfy
`0 <= start <= end <= vec.len()`. The source vector cannot be changed or moved while the
slice remains live.

The current implementation permits slice locals, direct function parameters, and
local struct fields. Aggregate copies and field replacement preserve the original
owner's borrow. A slice or slice-containing aggregate cannot be returned or escape
its owner; vectors cannot store slices. Mutable slices are not available. A slice
cannot be used to clone a move-only element.

## File and numeric vector helpers

| Call | Result |
| --- | --- |
| `zeros(count)` | A `Vec<Int>` filled with zeroes |
| `repeat(value, count)` | A vector repeating an `Int` or `Float` value |
| `read_text(path)` | A `String` containing all file bytes |
| `read_ints(path)` | A vector of whitespace-separated decimal integers |
| `read_floats(path)` | A vector of whitespace-separated decimal floats |

Negative lengths are runtime errors; length zero produces an empty vector.
`read_ints` and `read_floats` use ASCII space, tab, CR, and LF as separators. File,
parse, and allocation failures are runtime errors. New code should use the recoverable
[`std.fs`](file.md) APIs instead.

## Out-of-range access

```xen
fn main() {
    let values = [4, 8];
    println(values[2]);
}
```

```console
$ compiler/dist/xen run bounds_error.xen
bounds_error.xen:3:13: xen runtime error: vector index out of bounds
$ echo $?
1
```

The process exits with status 1. See [diagnostics](diagnostics.md) for the runtime
error format.
