# Variables and values

Use `let` to give a value a name. Use `let mut` if you will change it later. An annotation such as `: Int` specifies a type; omit it when the value makes the type clear.

Save this as `variables.xen`:

```xen
fn main() {
    let price: Int = 12;
    let mut quantity = 2;
    quantity = quantity + 1;
    let total = price * quantity;
    println(total);
    println(float(total) / 2.0);
}
```

```console
$ xen run variables.xen
36
18.0
```

Changing `quantity` does not automatically update a previously calculated `total`. Calculate again to get a new total. Assigning a new value to a variable declared with `let` is an error.

## Everyday types

| Type | Values |
| --- | --- |
| `Int` | Integers such as `42` and `-7`; the same type as `I64` |
| `Float` | Numbers such as `2.5`; the same type as `F64` |
| `Bool` | `true` and `false` |
| `String` | Strings such as `"hello"` |
| `Unit` | The return type of a function with no result; its value is `()` |

Integer literals default to `Int`, and floating literals to `Float`. A known type at the point of use can determine their type. Other integer choices are `I8`, `I16`, `I32`, `I64` and unsigned `U8`, `U16`, `U32`, `U64`. Floating types are `F32` and `F64`.

## Arithmetic and conversion

Use `+`, `-`, `*`, `/`, and integer remainder `%`. Dividing two `Int` values produces an integer. Convert with `float(...)` first if you need a fractional result. Functions such as `i32(...)`, `u8(...)`, and `f32(...)` select other numeric types explicitly. Values outside the destination type's range cause an error.

Different numeric types do not mix automatically. This deliberately incorrect program demonstrates the rule:

```xen
fn main() {
    let wide: I64 = 7;
    let narrow: I32 = wide;
    println(narrow);
}
```

```sh
xen check numeric_error.xen
```

The error includes `expected I32`. Change the declaration to `let narrow: I32 = i32(wide);`.

Integer `+`, `-`, and `*` wrap when a result exceeds the type's range. Consider the range in large calculations. Division by zero and dividing the minimum signed value by `-1` cause runtime errors.

## Comparisons and comments

`==`, `!=`, `<`, `<=`, `>`, and `>=` produce a `Bool`. Combine conditions with `&&`, `||`, and `!`. `&&` and `||` skip the right operand when the left operand determines the answer. Write a line comment after `//`.

You cannot declare the same name twice in one block. A nested `{ ... }` block may declare a name used outside it; the outer name becomes visible again after leaving the block.

---

[Contents](README.md) · [Previous: Your first program](getting-started.md) · [Next: Functions and control flow](control-flow.md) · [한국어](../ko/language-basics.md)
