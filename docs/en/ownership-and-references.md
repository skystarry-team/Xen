# Ownership and references

Xen checks initialization, partial moves, and borrow lifetimes through control flow.
The compiler inserts clone, move, and cleanup operations according to each type's
ownership rules.

## Cloneable managed values

`String`, most `Vec<T>` values, and aggregates made from cloneable managed values are
cloned at binding, assignment, and by-value argument boundaries. A function return
transfers the returned value to its caller. The `explc` capability controls reference
operations; it does not change these ownership rules.

```xen
#![explc]
fn consume(value: String) {}

#![explc]
fn main() {
    let value = "still available";
    consume(value);
    println(value);
}
```

```console
$ compiler/dist/xen run clone.xen
still available
```

## Move-only values and cleanup

`File`, owning `Box<T>`, and aggregates containing move-only
values cannot be cloned. Binding, assignment, by-value arguments, and returns transfer
their ownership. A moved binding cannot be used again until it is reinitialized where
that operation is supported.

Owned locals in a lexical block are dropped in reverse declaration order. `return`
cleans up all active function scopes; `break` and `continue` clean up through the
target loop body. Cleanup also happens when `?` returns an error. Runtime errors and
`panic` terminate without unwinding. A live `File` is closed automatically when its
owner leaves scope; a `Ptr` is never freed automatically.

## References

`&T` is a shared reference and `&mut T` is a mutable reference. Creating a reference,
declaring or passing an explicit reference parameter, and explicitly reborrowing require
the `explc` capability in the current lexical region. Dereferencing an already checked
reference does not need a separate capability. A mutable reference requires a mutable
owner.

```xen
#![explc]
fn append(values: &mut Vec<Int>, value: Int) {
    values.push(value);
}

#![explc]
fn main() {
    let mut values = [1];
    let reference = &mut values;
    append(reference, 2);
    println(*reference);
}
```

```console
$ compiler/dist/xen run borrow.xen
[1, 2]
```

Only one mutable loan can be active for a place. Shared references allow reads while
they are live and prevent mutation or move. A borrow ends after the last reachable use
of the reference, so the owner can be used again afterwards. The checker follows
references through branches, loops, aggregate copies, and calls.

Struct, tuple, and enum locals can be borrowed as whole values. Fields can be read or
updated through a reference using `reference.field` and `reference.0`. Replacing a
whole referent through `&mut` is supported. Reference fields, reference returns,
reference-to-reference, temporary borrows, and moving a `File` through a reference are
not supported.

## Shared reborrow

A mutable reference can be reborrowed as shared with `&*reference`, or coerced in a
context that expects `&T` for the same referent. The shared child keeps the parent from
mutating the referent until the child's last use. A shared reference cannot be made
mutable, and mutable reborrow syntax `&mut *reference` is not supported.

## Borrow conflict diagnostic

```xen
#![explc]
fn main() {
    let mut value = 1;
    let shared = &value;
    value = 2;
    println(*shared);
}
```

```console
$ compiler/dist/xen check borrow_error.xen
borrow_error.xen:5:5: error: cannot mutate 'value' while it is borrowed
borrow_error.xen:4:18: note: shared borrow of 'value' originates here
borrow_error.xen:6:13: note: borrow may remain live through this use
$ echo $?
1
```

The checker rejects the assignment because `shared` is used later. Narrow the borrow's
scope or move the mutation after its final use. See [diagnostics](diagnostics.md) for
how source locations and notes are reported.
