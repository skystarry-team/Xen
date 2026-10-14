# Strings and collections

Use `Vec<T>` to keep several values in order. Find text splitting functions in `std.string`. Save this as `collections.xen`:

```xen
use std.string as text;

fn main() {
    let words = text.split_ascii_whitespace("red green blue");
    println(words.get(1));
    println("한".len());
    let mut scores: Vec<Int> = [];
    scores.push(10);
    scores.push(20);
    scores[0] = 11;
    println(scores);
    let view = scores.slice(0, 2);
    println(view.get(1));
}
```

```console
$ xen run collections.xen
green
3
[11, 20]
20
```

## Strings

A `String` is an immutable sequence of bytes. Joining strings with `+` creates a new string. `len()` counts bytes, not characters: `"한"` occupies three bytes in UTF-8. Character indexing and string mutation syntax are unavailable.

Inside a string, use `\n`, `\t`, `\r`, `\"`, and `\\`. Xen does not automatically validate UTF-8, so file contents retain their original bytes. Cutting at byte positions can split a character's encoding.

`std.string.split_ascii_whitespace` splits at ASCII whitespace, including spaces, tabs, and newlines, without producing empty items. `split_byte(text, u8(44))` splits at comma bytes and keeps empty items. It does not interpret CSV quoting. See the [standard library](stdlib.md) for searching and extracting parts.

## Vectors

Create a vector with `[10, 20]`. Give an empty vector an element type such as `Vec<Int>`. Indices start at zero.

| Task | Expression |
| --- | --- |
| Count items | `scores.len()` |
| Read | `scores[0]` or `scores.get(0)` |
| Add or change | `scores.push(30)`, `scores.set(0, 12)` |
| Remove the last item | `scores.pop()` |
| Replace and return the previous item | `scores.replace(0, 12)` |
| Exchange two items | `scores.swap(0, 1)` |

Changes require `let mut`. An invalid index or `pop()` on an empty vector causes a runtime error. Check the length first. `get()` does not return an `Option` on failure. All elements must have the same type. References, slices, and pointers cannot be vector elements.

Move-only elements such as `Box` and `File` cannot be copied through indexing or `get()`. Take ownership with `pop()`, `replace()`, or `.into_iter()`, or create a shared element reference with `&values[index]` in a function with `explc`. While that reference remains in use, you cannot change or move the entire vector. Mutable element references are unavailable.

`String.as_bytes()` creates a read-only `Slice<U8>`. `Vec<U8>.into_string()` consumes the vector and transfers its bytes into a string without UTF-8 validation.

## Read-only views

`as_slice()` creates a `Slice<T>` over the whole vector; `slice(start, end)` views a range with an excluded end. This does not copy the elements into a new vector. You cannot change or move the original until the view's last use. Views cannot be returned from a function or stored in vectors; mutable views are unavailable. Copy items into a new vector if you need independent storage.

## Iteration and transformations

Loop over indices using a range, or add `use std.iter;` and call `.iter()`. `for value in values` does not automatically turn a vector into an iterator.

```xen
use std.iter;

fn doubled(value: Int) -> Int {
    return value * 2;
}

#![explc]
fn over_two(value: &Int) -> Bool {
    return *value > 2;
}

fn main() {
    let values = [1, 2, 3];
    for value in values.iter().map(doubled).filter(over_two) {
        println(value);
    }
}
```

```console
$ xen run iterators.xen
4
6
```

`.map` transforms each item and `.filter` keeps matching items. The functions run when you iterate. Supply named functions as callbacks. `.enumerate()` yields tuples containing a zero-based index and a value.

Vector and Slice `.iter()` calls require copyable or cloneable elements. You cannot change the source while a borrowed `.iter()` chain remains in use. `.into_iter()` takes ownership of the vector and yields its items in order. For move-only items such as `Box` or `File`, use `.into_iter()` or read through an element reference as described above. After `.into_iter()`, the original vector is no longer available. See [copies and moves](ownership.md).

---

[Contents](README.md) · [Previous: Functions and control flow](control-flow.md) · [Next: Structs and enums](types.md) · [한국어](../ko/collections.md)
