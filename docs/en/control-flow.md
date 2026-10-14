# Functions and control flow

A function names a task you want to reuse. Give parameters types and put the result type after `->`. Return a value with `return`. A function without a result can omit `-> Unit`.

Save this as `control_flow.xen`:

```xen
fn doubled(value: Int) -> Int {
    return value * 2;
}

fn main() {
    let mut total = 0;
    for number in 1..5 {
        total = total + doubled(number);
    }
    let label = if total >= 20 { "enough" } else { "more" };
    println(total);
    println(label);
    let mut remaining = 2;
    while remaining > 0 {
        println(remaining);
        remaining = remaining - 1;
    }
}
```

```console
$ xen run control_flow.xen
20
enough
2
1
```

## Choose with a condition

In `if condition { ... } else { ... }`, the condition must be a `Bool`. An `if` used as a value requires `else` and must produce the same type in every branch. As with `label` above, leave the branch's final value without a semicolon.

When selecting actions, each branch can contain several statements. Use `else if` to check another condition.

## Repeat work

`1..5` produces 1 through 4; the end is excluded. A `for` binding is visible only in its body. A range whose start is at least its end is empty. There is no syntax for range steps or reverse ranges.

`while` repeats while its condition is true. Make sure the body can change the condition. `break;` ends the innermost loop; `continue;` skips the rest of the current iteration. The [next chapter](collections.md) covers collection iteration.

## Return values and function values

A function with a result must return on every path. An ordinary function does not return its last expression automatically; write `return`. Functions can call themselves. At most six parameters are supported. Recursive calls have a depth limit, so consider a loop for long inputs.

A concrete named function can be stored or passed using a type such as `fn(Int) -> Int`. In the program above, `let transform: fn(Int) -> Int = doubled;` followed by `transform(3)` produces 6. Anonymous functions and closures are unavailable.

## Try a change

Change the range to `1..6` and observe the total. Try adding `continue` to skip one number.

---

[Contents](README.md) · [Previous: Variables and values](language-basics.md) · [Next: Strings and collections](collections.md) · [한국어](../ko/control-flow.md)
