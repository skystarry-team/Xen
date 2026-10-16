# Syntax and common problems

Use this page to look up syntax while writing code. The linked chapters provide explanations and runnable examples.

## Find a form

| Task | Form | Chapter |
| --- | --- | --- |
| Name a value | `let name: Type = value;` | [Values](language-basics.md) |
| Mutable variable | `let mut name = value;` | [Values](language-basics.md) |
| Declare a function | `fn name(x: Int) -> Int { return x; }` | [Functions](control-flow.md) |
| Conditional value | `if condition { yes } else { no }` | [Control flow](control-flow.md) |
| Range loop | `for item in start..end { ... }` | [Control flow](control-flow.md) |
| Conditional loop | `while condition { ... }` | [Control flow](control-flow.md) |
| Ordered values | `[first, second]`, `Vec<T>` | [Collections](collections.md) |
| Struct declaration and construction | `struct User { name: String }`, `User { name: "Mina" }` | [Types](types.md) |
| Alternative forms | `enum State { Idle, Ready(Int) }` | [Types](types.md) |
| Select by form | `match value { Pattern => result, ... }` | [Types](types.md) |
| Unpack a tuple | `let (left, right) = pair;` | [Types](types.md) |
| Generics | `fn identity<T>(value: T) -> T { return value; }` | [Generics](generics.md) |
| Reference the original | `&value`, `&mut value`, `*reference` | [Ownership](ownership.md) |
| Propagate failure | `fallible_call()?` | [Errors](error-handling.md) |
| Use a project file | `module app;`, `import folder.module as short;` | [Modules](modules.md) |
| Use a standard module | `use std.string as text;` | [Standard library](stdlib.md) |
| Declare a test | `test fn name() { assert(condition); }` | [Tests](testing.md) |

Declare functions, structs, enums, and impl blocks at the top level. Put values and statements inside functions. Use semicolons for statements, leaving value-producing `if` and `match` branch expressions without them. Only `//` line comments are supported; block comments are unavailable. Names and strings are case-sensitive.

## Numbers and operators

Integer types are `I8` through `I64` and `U8` through `U64`; floating types are `F32` and `F64`. `Int = I64` and `Float = F64`. Literals are decimal; floating forms include `1.25` and `1e3`. Numeric separators such as `_` and hexadecimal literal syntax are unavailable.

Precedence, highest first: calls/fields/indices/`?`, power `**`, unary `+ - ! ~ & *`, `* / %`, `+ -`, `<< >>`, `&`, `^`, `|`, `< <= > >=`, `== !=`, `&&`, `||`. Power associates right to left; other binary operators at the same level associate left to right. Thus `2 ** 3 ** 2` is `512`, `-2 ** 2` is `-4`, and `(-2) ** 2` is `4`. The exponent may have a unary sign, as in `2.0 ** -2.0`. Add parentheses when unsure. Strings support `+`, `==`, and `!=`. Vector equality is available for supported numeric, boolean, string, and nested vector elements. Structs and enums do not have `==`.

| Operators | Operands and result |
| --- | --- |
| Unary `+` | Any numeric type; returns the unchanged value, including floating negative zero |
| Unary `-` | Signed integer or float; integer negation wraps at the type width |
| `+ - * /` | Two numbers of the same type; integer `+ - *` wrap, integer division truncates toward zero |
| `%` | Two numbers of the same type; remainder has the dividend's sign |
| `**` | Two numbers of the same type; exponentiation, including real floating exponents |
| `& \| ^`, unary `~` | Integer bitwise AND, OR, XOR and complement at the type width |
| `<< >>` | Two integers of the same type; result has that type |
| `&& \|\|`, unary `!` | `Bool`; `&&` and `\|\|` evaluate the right operand only when needed |

Shifts require `0 <= count < bit width`; an invalid count causes a runtime error even when the result is unused. Left shift discards bits beyond the type width. Right shift preserves the sign for signed types and fills with zero for unsigned types. For example, `i8(-8) >> i8(2)` is `-2`, and `u8(128) >> u8(2)` is `32`. Both shift and bitwise operands must have the same integer type; literals take their type from context, as in `let mask: U8 = 1 << 7;`. These operators are available in ordinary scopes.

Integer division and remainder by zero cause runtime errors, as do the minimum signed value divided by or taken modulo `-1`. Unary `&` borrows a value; binary `&` performs bitwise AND.
In prefix position, `**ref` retains double dereference. Use `value * *ref` to multiply by a dereferenced value.

Integer power uses exponentiation by squaring and wraps at the result type's width. Negative integer exponents cause a runtime error, including unused results. `0 ** 0` is `1`. Use floating operands for negative or fractional exponents: `2.0 ** -3.0` is `0.125`, and `9.0 ** 0.5` is `3.0`.

Floating `%` computes an exact remainder using a quotient truncated toward zero, without forming that quotient in floating point. A zero divisor, infinite dividend, or NaN operand produces NaN. A finite dividend modulo infinity returns the dividend; a zero result retains its sign. Floating `**` follows real-valued IEEE special cases: a negative finite base with a noninteger exponent produces NaN, overflow produces signed infinity, and underflow may produce signed zero. `NaN ** 0.0` and `1.0 ** NaN` are `1.0`. Both CPUs use shared binary64 arithmetic routines; F32 operands are widened exactly and the result is rounded to F32, including infinities and NaNs.

## Common problems and fixes

| Problem | Fix |
| --- | --- |
| Unknown empty vector type | Add a type: `let values: Vec<Int> = [];` |
| Immutable variable | Use `let mut` when changes are needed |
| Different numeric types | Convert explicitly, for example with `i32(...)` |
| Missing match arm | Add the missing variant or an appropriate `_` |
| Unknown generic type argument | Give arguments known types or specify all type arguments |
| Changing a borrowed value | Change it after the reference's last use |
| Using a moved value | Use the new owner or read necessary information before moving |
| Missing module | Check the path relative to the entry and the declared module name |
| Invalid index | Check the length before access |

This deliberately incorrect program uses a value after moving it:

```xen
fn main() {
    let original = box(42);
    let transferred = original;
    println(original.into_inner());
}
```

```sh
xen check move_error.xen
```

The error includes `moved`. Replace the last line with `println(transferred.into_inner());` to print 42.

## When a feature is unavailable

Closures, traits, exceptions, async, FFI, and package management are unavailable. Reference returns, mutable slices, string indexing, and match guards are also unsupported. Use the functions, loops, and `Result` patterns described in the relevant chapter.

The [`bb` low-level facility](low-level.md) supports raw memory, operating-system calls, bounded addresses, volatile and integer atomic accesses, CPU hints/fences, multiple-output inline `asm`, and scalar C ABI `extern_call`. Use the standard-library APIs for ordinary files, input/output, and paths.

---

[Contents](README.md) · [Previous: Command-line tools](cli.md) · [한국어](../ko/reference.md)
