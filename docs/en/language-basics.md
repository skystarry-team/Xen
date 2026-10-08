# Language basics

## Types and literals

| Type | Meaning |
| --- | --- |
| `I8`, `I16`, `I32`, `I64` | Signed fixed-width integers |
| `U8`, `U16`, `U32`, `U64` | Unsigned fixed-width integers |
| `F32`, `F64` | IEEE-754 floating-point values |
| `Int`, `Float` | Compatibility names for `I64` and `F64` |
| `Bool`, `Unit` | Boolean and no meaningful value |
| `String`, `Vec<T>`, `Slice<T>`, `File` | Byte string, vector, borrowed view, and owned file |

An integer literal defaults to `I64`; a floating-point literal defaults to `F64`.
Annotations and known parameter, return, field, and generic contexts can determine the
literal type. Numeric types never convert implicitly.

The conversion functions `i8`, `u8`, `i16`, `u16`, `i32`, `u32`, `i64`, `u64`, `f32`,
and `f64` perform checked numeric conversions. `int` and `float` are compatibility
conversions for `F64` to `Int` and `Int` to `Float`. A range error that can be proven
from a literal is a compile error. A range error discovered at runtime, or conversion
of NaN or infinity to an integer, is a runtime error.

```xen
fn main() {
    let wide: I64 = 120;
    let narrow: I8 = i8(wide);
    let ratio: F64 = float(5) / 2.0;
    println(narrow);
    println(ratio);
}
```

```console
$ compiler/dist/xen run numbers.xen
120
2.5
```

## Bindings and assignment

`let` creates an immutable binding. Use `let mut` when the binding itself will be
reassigned or when calling a mutating receiver such as `Vec.push` or `File.read`.
Names cannot be declared twice in one lexical block; a nested block can shadow an outer
name. An initializer is checked before its new binding enters scope, so in `let x = x +
1` the right-hand `x` refers to an outer binding.

```xen
fn main() {
    let answer = 42;
    let mut count = 1;
    count = count + answer;
    println(count);
}
```

```console
$ compiler/dist/xen run bindings.xen
43
```

## Tuple bindings

```xen
let (number, label) = (42, "xen");
let (first, (_, last)) = (1, (2, 3));
let mut (left, right): (Int, Int) = (1, 2);
left = 4;
let _ = box(0);
```

`let` accepts bindings, `_`, and nested tuple patterns. Arity and types are checked
statically; names cannot repeat within the pattern or the same lexical block.
`mut` applies to every binding; a type annotation describes the entire initializer.
The initializer is evaluated once before any new name becomes visible, so it can
still read an outer binding with the same name. Each binding follows ordinary
by-value copy, clone and move rules. Discarded fields and the hidden owner are
cleaned up at the end of the declaration, before the next statement. Early `?` or
`return` uses the same cleanup rules. Literal, enum and struct patterns and
pattern assignment are not supported here; existing tuple element type limits apply.

## Operators

| Operators | Types and behavior |
| --- | --- |
| `+`, `-`, `*`, `/` | Same numeric type; `+` also concatenates two `String` values |
| `%` | Same integer type |
| `<`, `<=`, `>`, `>=` | Same numeric type |
| `==`, `!=` | Numeric values, `Bool`, `String`, and supported `Vec` values |
| `&&`, `||`, `!` | `Bool`; `&&` and `||` short-circuit |
| unary `-` | Signed integer or float |

Integer `+`, `-`, and `*` wrap modulo the width of their type. Division or remainder by
zero and signed minimum divided or remaindered by `-1` are runtime errors.

## Functions and control flow

Functions use `fn name(parameters) -> ReturnType { ... }`. The return type can be omitted
for `Unit`. Every path through a function returning a non-`Unit` type must return a
value. Functions support up to six parameters and arguments, and calls including
recursion allow up to 4096 active function frames counting the entry function. The
process stack can be exhausted sooner depending on frame and argument sizes.

```xen
fn average(total: Float, count: Int) -> Float {
    return total / float(count);
}

fn main() {
    let label = if average(10.0, 4) > 2.0 { "above" } else { "low" };
    println(label);
}
```

```console
$ compiler/dist/xen run control.xen
above
```

`if` can be a statement or an expression. An expression `if` requires a final `else`;
each branch produces one semicolon-free expression of the same type. `while`, `break`,
`continue`, and `return` are supported. A standalone `{ ... }` creates a lexical scope.
Owned locals in that scope are cleaned up on normal exit, `break`, `continue`, and
`return`.

The `for` loop uses the iterator protocol, and `start..end` creates a half-open `Int`
range. See the [guide to generics and matching](generics-enums-and-match.md) for
patterns and the [language guide](language-guide.md) for the iterator limits.

## Built-ins

| Call | Behavior |
| --- | --- |
| `print(value)`, `println(value)` | Print supported scalars, `Bool`, `String`, and supported vectors |
| `len(value)` | Return a string's byte length or a collection's element count |
| `assert(condition)`, `assert_msg(condition, message)` | Terminate with a runtime error if false |
| `panic(message)` | Write a runtime error to stderr and exit |
| `arg_count()`, `arg(index)` | Read individual program arguments |
| `int_to_str(value)` | Format an `Int` as decimal text |

For file access, prefer the recoverable APIs in [`std.fs` and `std.io`](file.md). For
complete argument collection, use `std.env.args()` from the [standard library](stdlib.md).

## A type error

There is no implicit conversion between integer widths:

```xen
fn main() {
    let wide: I64 = 7;
    let narrow: I32 = wide;
    println(narrow);
}
```

```console
$ compiler/dist/xen check numeric_error.xen
numeric_error.xen:3:23: error: expected I32, found Int (I64)
help: convert explicitly with i32(...)
$ echo $?
1
```

Convert explicitly with `i32(wide)` when the checked conversion is appropriate. See
[diagnostics](diagnostics.md) for the compiler's error format.
