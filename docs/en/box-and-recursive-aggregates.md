# Box and recursive data

`Box<T>` owns one value in one explicit heap allocation. It is always move-only,
regardless of the inner type. `box(value)` creates an owning box; `as_ref()` and
`as_mut()` borrow its contents, and `into_inner()` consumes the box and returns the
owned value.

```xen
struct Node {
    value: Int,
    next: Option<Box<Node>>,
}

fn main() {
    let leaf = Node { value: 2, next: Option<Box<Node>>.None };
    let root = Node { value: 1, next: Option<Box<Node>>.Some(box(leaf)) };
    println(root.value);
}
```

```console
$ compiler/dist/xen run box.xen
1
```

Box size and alignment are both eight bytes. Allocation failure is a runtime error and
does not unwind. On normal scope exit, `return`, `break`, `continue`, or `?`, the box
recursively drops its owned value and frees its allocation. `into_inner()` instead
transfers the inner value to the caller and frees only the allocation.

## Recursive layouts

Structs and enums may be recursive when every layout cycle crosses an owning `Box` or
`Vec` boundary. Direct or indirect inline-size cycles are rejected. A box field does
not make a separate inline cycle valid. Generic recursion is accepted when it returns
to the same concrete type instance; type arguments that grow recursively are rejected.

`Box<T>` cannot store references, slices, or pointers in its inner value. Moving a
field out through a borrowed box is not supported; consume it with `into_inner()` first.
Matching on `*box` obtains an owned value. Use `match box.as_ref()` with `ref`
payload bindings to inspect an enum without consuming it; see [shared matching](generics-enums-and-match.md#shared-matching).

## Name resolution

If the source file does not declare its own `Box`, `Box<T>` names the owning type.
Existing user-defined inline `struct Box<T>` declarations remain valid. When both are
needed, import `core.box` and use its qualified name:

```xen
use core.box;
struct Box<T> { value: T }

fn main() {
    let inline = Box<Int> { value: 3 };
    let owned: core.box.Box<Int> = core.box.new(8);
    println(inline.value);
    println(owned.into_inner());
}
```

```console
$ compiler/dist/xen run box_names.xen
3
8
```
