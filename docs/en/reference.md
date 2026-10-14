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

Precedence, highest first: calls/fields/indices/`?`, unary `-`/`!`/`&`/`*`, `* / %`, `+ -`, `< <= > >=`, `== !=`, `&&`, `||`. Add parentheses when unsure. Strings support `+`, `==`, and `!=`. Vector equality is available for supported numeric, boolean, string, and nested vector elements. Structs and enums do not have `==`.

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

The `bb` facility for direct raw memory and operating-system calls is unnecessary for ordinary programs. Use the standard-library APIs for files, input/output, and paths.

---

[Contents](README.md) · [Previous: Command-line tools](cli.md) · [한국어](../ko/reference.md)
