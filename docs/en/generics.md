# Reusing types

Declare a type parameter with `<T>` to reuse code that stores or passes values of different types. Save this as `generics.xen`:

```xen
struct Pair<T> { first: T, second: T }

fn identity<T>(value: T) -> T {
    return value;
}

fn main() {
    let pair = Pair<Int> { first: identity(7), second: 9 };
    println(pair.first);
    println(identity<String>("hello"));
}
```

```console
$ xen run generics.xen
7
hello
```

In `identity(7)`, the argument determines `T`. `identity<String>("hello")` supplies it explicitly. For several parameters, provide all types as `<A, B>`. Structs and enums can also have type parameters. Methods for a generic type use `impl<T> Pair<T> { ... }`.

## When a type is unknown

An empty vector or `Option.None` does not identify an item type by itself. Write `let items: Vec<Int> = [];` or `let missing: Option<String> = Option.None;`.

Generic function inference uses argument types, not the type of the variable receiving the result. `let n: I32 = identity(1);` fails because `1` selects `Int`. Use `identity<I32>(1)` or `identity(i32(1))`. Partial type argument lists are unsupported.

## What can be reused?

A generic function can store, pass, and return values and work with known shapes such as `Option<T>` or `Vec<T>`. It cannot directly apply `+`, comparisons, or arbitrary fields and methods to an unknown `T`. For example, `a + b` inside `fn add<T>(a: T, b: T) -> T` is rejected. Use a concrete numeric type such as `Int`, or pass a named function callback that performs the required operation. Traits, bounds, and operator overloading are unavailable.

A generic function can match an enum or tuple whose shape is already known. It cannot match an unknown `T` against number literals or a particular enum.

---

[Contents](README.md) · [Previous: Structs and enums](types.md) · [Next: Copies, moves, and references](ownership.md) · [한국어](../ko/generics.md)
