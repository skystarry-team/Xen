# Missing values and errors

A search may find nothing, and a user may enter an invalid number. Represent these situations with result values. `Option<T>` and `Result<T, E>` are available without an import.

## A possibly missing value: Option

`Option.Some(value)` contains a value; `Option.None` does not. The result of `std.string.find` is one example. Handle both cases with `match`. You can also choose a default with `std.option.unwrap_or(value, fallback)`. The fallback is evaluated before the call even for `Some`; use `match` if calculating it is expensive or has side effects.

## Success and failure: Result

`Result.Ok(value)` means success, and `Result.Err(error)` means failure. Save this as `errors.xen`:

```xen
use std.convert as convert;

fn double_number(text: String) -> Result<Int, convert.ParseIntError> {
    let number = convert.parse_int(text)?;
    return Result.Ok(number * 2);
}

fn main() {
    println(match double_number("21") {
        Result.Ok(number) => convert.format_int(number),
        Result.Err(_) => "Please enter a decimal integer.",
    });
    println(match double_number("hello") {
        Result.Ok(number) => convert.format_int(number),
        Result.Err(_) => "Please enter a decimal integer.",
    });
}
```

```console
$ xen run errors.xen
42
Please enter a decimal integer.
```

Handling bad input with `match` lets you print an alternative result or retry. Parsing `hello` here does not force the program to terminate.

## Propagate an error with ?

`parse_int(text)?` extracts a successful value or immediately returns the error from the current function. That function must return `Result<U, E>` with the same error type `E` as the call. `?` cannot be used in a result-free function such as `main()`, or on `Option`.

For different error types, convert first with `std.result.map_err(value, convert_error)`. The callback is a named function taking the old error and returning the new one. Then use `?`. Xen has no exceptions or `try/catch` syntax.

## When to stop the program

`panic(message)` prints an error and terminates unsuccessfully. `assert(condition)` and `assert_msg(condition, message)` terminate if the condition is false. Use `Result` for expected input and file failures, and choose termination where continuing is inappropriate.

Use `xen check` for errors detected before execution. Find the reported file, line, and column, then correct the code. Reference diagnostics include `note` locations showing where a borrow starts or is used later. See [common problems](reference.md) for fixes.

---

[Contents](README.md) · [Previous: Copies, moves, and references](ownership.md) · [Next: Working with multiple files](modules.md) · [한국어](../ko/error-handling.md)
