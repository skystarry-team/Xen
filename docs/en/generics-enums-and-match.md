# Generics, enums, tuples, and match

## Limited generics

Functions, structs, and enums can declare comma-separated type parameters. A function
call can infer all type arguments from its arguments or specify all of them. The compiler generates only
the concrete instances used by the program.

Generic function bodies support binding, assignment, move, return, aggregate
construction, generic calls, and typed function callbacks. Known tuple and enum
structures can be decomposed with `match`. Operations on concrete fields and known
container shapes remain available; each concrete instance still checks element
restrictions. Type-specific arithmetic, comparison, built-ins, field access, methods,
and indexing on an unconstrained `T` are rejected, including through inferred locals,
pattern bindings, projections, and call results. An annotation or explicit type
argument cannot turn `T` into a concrete type.

The existing structural iterator call is an exception: `iterator.next()` on an abstract
iterator requires its concrete type to provide `next(&mut self) -> Option<Item>`.
There are no trait bounds, overloads, partial type arguments, or method-local type
parameters. Inherent methods in `impl<T> Type<T>` remain supported.
Canonical builtin calls retain builtin precedence even when a local has the same
name; that local's callback signature cannot change the builtin's type requirements.
The existing user-function and local-function shadowing rules for `box` are preserved.

```xen
fn unwrap_or<T>(value: Option<T>, fallback: T) -> T {
    return match value {
        Option.Some(item) => item,
        Option.None => fallback,
    };
}
```

Both arguments are evaluated before this ordinary call. Move-only values transfer
ownership, and the unselected value is dropped. The helper does not add a new prelude API.

### Limited function call inference

Omit type arguments when the arguments' known static types uniquely determine every
type parameter. Inference happens at compile time and reuses the same monomorphization,
type checking, and code generation as an explicit call.

```xen
fn identity<T>(value: T) -> T { return value; }
fn first<A, B>(a: A, b: B) -> A { return a; }

fn main() {
    let x: I64 = 42;
    let y: String = "hello";
    let a = identity(x);       // T = I64
    let b = identity<I64>(x);  // explicit calls remain supported
    let result = first(x, y);  // A = I64, B = String
    let narrow = identity(i32(7)); // T = I32
}
```

If the same type parameter corresponds to both `I32` and `I64`, inference reports a
conflict with both types. It does not find a common type or convert numbers implicitly.
Integer and floating literals without context default to `I64` and `F64`; the aliases
`Int` and `Float` are treated as their canonical types.

A parameter not determined by arguments is named in the error, with an explicit call
suggestion. For example, calling `fn create<T>() -> T` as `create()` reports:

```text
error: cannot infer type parameter 'T'
help: specify all type arguments explicitly, for example: create<I64>()
```

The suggested type is an example; choose the type your program needs. Inference does
not use the expected return type or inspect the function body. Thus
`let value: I32 = identity(1)` infers `I64` from the argument and fails type checking,
while `identity<I32>(1)` keeps the existing explicit literal context.
`let value: Option<I32> = identity(Option.None)` also cannot infer `T`; write
`identity<Option<I32>>(Option.None)`. Calls that previously depended on return
annotations to infer type arguments must now specify them explicitly.

An entire concrete aggregate type, including a tuple, can also directly match `T`.
Existing structural argument matching inside vectors, structs, enums, references, and
function types remains supported. Recursive inference inside tuple types is not
supported. This matches known argument types; it is not a general constraint solver.
If any type parameter remains unknown, including
calls with only empty collections or constructors without payload information, specify
all type arguments explicitly. Partial type argument omission is not supported.

## Enums and tuples

An enum variant can have no payload or one payload. Use a tuple as that payload when a
variant needs more than one value. `Option<T>` (`None`, `Some(T)`) and `Result<T, E>`
(`Ok(T)`, `Err(E)`) are available from the prelude.

```xen
enum Message<T> { Quit, Data((T, Bool)) }

fn describe(result: Result<Int, String>) -> String {
    return match result {
        Result.Ok(value) => "value=" + int_to_str(value),
        Result.Err(error) => error,
    };
}

fn main() {
    let message: Message<Int> = Message.Data((7, true));
    let label = match message {
        Message.Data((value, true)) => "enabled " + int_to_str(value),
        Message.Data((value, false)) => "disabled " + int_to_str(value),
        Message.Quit => "quit",
    };
    let option: Option<String> = Option.Some(label);
    println(match option {
        Option.Some(text) => text,
        Option.None => "none",
    });
    println(describe(Result.Ok(9)));
    println(describe(Result.Err("recoverable error")));
}
```

```console
$ compiler/dist/xen run enums.xen
enabled 7
value=9
recoverable error
```

Tuples use `(value1, value2)` and types such as `(I64, String)`. Read elements with
zero-based `.0`, `.1`, and so on. Direct elements of a mutable tuple local can be
assigned. `()` is the `Unit` value.

## Contextual enum types

When an enum constructor has a concrete expected type, the compiler passes that type to
its payload and nested vector literals. This lets nested constructors omit repeated
type arguments:

```xen
enum Tree<T> { Leaf(T), Branch(Vec<Tree<T>>) }

fn describe(tree: Tree<Int>) -> String {
    return match tree {
        Tree.Leaf(value) => "leaf " + int_to_str(value),
        Tree.Branch(children) => "branch with " + int_to_str(children.len()) + " children",
    };
}

fn main() {
    let tree: Tree<Int> = Tree.Branch([
        Tree.Leaf(3),
        Tree.Leaf(4),
    ]);
    println(describe(tree));
}
```

```console
$ compiler/dist/xen run tree.xen
branch with 2 children
```

Without a concrete expected type, the compiler uses the payload constraints available
in the expression. `Option.None` and `Tree.Branch([])` do not determine a type argument
on their own; add an annotation or explicit type argument. The compiler does not infer
an enum type from a different enum's context.

## Exhaustive match

`match` supports enum variants, tuples, booleans, scalar literals, nested patterns,
bindings, and `_`. Every possible value must be covered. An arm after an irrefutable
pattern is unreachable and is rejected. Match guards, struct patterns, and destructuring
assignment are not supported. A generic body can match a known enum or tuple shape;
an abstract `T` permits only a binding or wildcard, not concrete literal or constructor patterns.

`Option` and `Result` use ordinary enum patterns. The postfix `?` applies only to
`Result<T, E>`: `Ok(value)` produces `value`, and `Err(error)` returns from the current
function. The current function must return `Result<U, E>` with the same error type. It
works inside expressions, call arguments, conditionals, and match arms. It does not
propagate `Option`, convert error types implicitly, or work in a `Unit` function.
`std.result.map_err` accepts a concrete named callback for explicit conversion before
`?`; `std.option.unwrap_or` supplies an eager fallback for `Option<T>`.

```xen
use std.convert;

fn double_decimal(text: String) -> Result<Int, std.convert.ParseIntError> {
    let value = std.convert.parse_int(text)?;
    return Result.Ok(value * 2);
}

fn main() {
    let value = match double_decimal("21") {
        Result.Ok(number) => number,
        Result.Err(_) => 0,
    };
    println(value);
}
```

```console
$ compiler/dist/xen run result_question.xen
42
```

## Shared matching

Use `match &value` or match an existing shared reference to inspect a value without
cloning or consuming it. In shared mode, named payload bindings use `ref name` and
have type `&Payload`; plain consuming bindings are rejected. Creating the borrow
requires `explc`. Mutable reference sources require an explicit shared reborrow.

```xen
#![explc]
fn main() {
    let value: Option<Box<Int>> = Option.Some(box(8));
    println(match &value { Option.Some(ref item) => **item, Option.None => 0 });
    let owned = value;
    println(match owned { Option.Some(item) => item.into_inner(), Option.None => 0 });
}
```

Both lines print `8`. Bindings cannot move their borrowed payload or escape the arm
as a reference/Slice match result. Reference fields/returns, mutable patterns and
temporary borrows remain unsupported. Generic reference parameters such as `&T`
and `&mut T` are supported when the concrete referent is valid; reference-to-reference,
Unit and function referents are rejected.
