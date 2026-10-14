# Copies, moves, and references

Whether the original value remains available after assignment or a function call depends on its type:

| Value | Passing it by value |
| --- | --- |
| Numbers, booleans, and other simple values | Copies it; the original remains usable |
| `String` and vectors with cloneable elements | Makes an independent copy of the contents; the original remains usable |
| `Box`, `File`, and structs or vectors containing them | Transfers ownership; the original is no longer usable |

Structs, enums, and tuples follow the rules of their components. If every component can be copied or cloned, the whole value can be copied or cloned. If any component is move-only, the whole value is move-only. For example, passing a struct containing only String fields by value leaves the original struct available.

A function return transfers its result to the caller. Save this as `ownership.xen`:

```xen
fn append_copy(values: Vec<Int>) {
    let mut copy = values;
    copy.push(3);
    println(copy);
}

#![explc]
fn append_shared(values: &mut Vec<Int>) {
    values.push(3);
}

#![explc]
fn main() {
    let mut values = [1, 2];
    append_copy(values);
    println(values);
    append_shared(&mut values);
    println(values);
    let original = box(42);
    let transferred = original;
    println(transferred.into_inner());
}
```

```console
$ xen run ownership.xen
[1, 2, 3]
[1, 2]
[1, 2, 3]
42
```

`append_copy` changes an independent vector, leaving the caller's value unchanged. `append_shared` changes the caller's vector. This distinction tells you whether a function changes your original data.

## Refer to the original

`&value` creates a shared reference for reading; `&mut value` creates a mutable reference. Parameter types are `&T` and `&mut T`; read through one with `*reference`. A mutable reference requires a `let mut` owner.

Put `#![explc]` on the line immediately before a function that creates explicit references or declares explicit reference parameters, as above. Use `#scope[explc] { ... }` to enable them in one block. A called function's annotation does not enable references in its caller.

While shared references remain in use, you cannot change or move the original. While a mutable reference remains in use, you cannot access the same value through another reference or the original. These restrictions end after the reference's last use. This program deliberately violates the rule:

```xen
#![explc]
fn main() {
    let mut value = 1;
    let shared = &value;
    value = 2;
    println(*shared);
}
```

```sh
xen check borrow_error.xen
```

The error includes `while it is borrowed`. Move `value = 2;` after `println(*shared);`. References cannot be stored in struct fields or returned. You cannot borrow a temporary directly; store it in a local first.

## Own a value in a Box

`box(value)` creates a `Box<T>`. Read with `as_ref()`, change with `as_mut()`, or consume the box with `into_inner()` to take its value out. A box is never copied, even if it contains a number. After assigning `original` to `transferred` above, `original` is unavailable.

For connected values, use a field such as `Option<Box<Node>>`. Save this as `recursive_data.xen`:

```xen
struct Node { value: Int, next: Option<Box<Node>> }

fn sum(node: Node) -> Int {
    let rest = match node.next {
        Option.Some(next) => sum(next.into_inner()),
        Option.None => 0,
    };
    return node.value + rest;
}

fn main() {
    let last = Node { value: 20, next: Option<Box<Node>>.None };
    let first = Node { value: 10, next: Option.Some(box(last)) };
    println(sum(first));
}
```

```console
$ xen run recursive_data.xen
30
```

A direct `next: Node` field would have no finite size and is rejected. Recursive connections need a `Box` or `Vec` boundary. A box cannot contain references, slices, or pointers.

## When a value's lifetime ends

Owned values are released when you leave a block, including through `return`, `break`, `continue`, or `?`. Open `File` values close automatically. A panic or runtime error immediately terminates the program without this normal cleanup. The [next chapter](error-handling.md) handles expected failures as values.

---

[Contents](README.md) · [Previous: Reusing types](generics.md) · [Next: Missing values and errors](error-handling.md) · [한국어](../ko/ownership.md)
