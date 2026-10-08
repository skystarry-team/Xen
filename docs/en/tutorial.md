# Guided tour: sum integers from a file

This program reads a file of whitespace-separated signed decimal integers, checks each
token, and prints the sum. It demonstrates module imports, command-line arguments,
`Result`, `match`, `for`, and the Xen standard library.

Save the following complete program as `sum.xen`:

```xen
module sum;
use std.convert;
use std.env;
use std.fs;
use std.io;
use std.iter;
use std.string;

fn parse_message(index: Int, error: std.convert.ParseIntError) -> String {
    return match error {
        std.convert.ParseIntError.Empty =>
            "empty integer token at token " + std.convert.format_int(index),
        std.convert.ParseIntError.InvalidDigit((byte_index, byte)) =>
            "invalid integer token " + std.convert.format_int(index) +
            " at byte " + std.convert.format_int(byte_index) +
            " (value " + std.convert.format_int(i64(byte)) + ")",
        std.convert.ParseIntError.Overflow =>
            "integer overflow at token " + std.convert.format_int(index),
    };
}

fn main() {
    let args = std.env.args();
    if args.len() != 1 {
        panic("usage: sum <path>");
    }

    let contents = match std.fs.read(args.get(0)) {
        Result.Ok(text) => text,
        Result.Err(error) => {
            assert_msg(false, std.io.describe_error(error));
            ""
        },
    };

    let tokens = std.string.split_ascii_whitespace(contents);
    let mut total: Int = 0;
    for (index, token) in tokens.iter().enumerate() {
        let value = match std.convert.parse_int(token) {
            Result.Ok(number) => number,
            Result.Err(error) => {
                assert_msg(false, parse_message(index, error));
                0
            },
        };
        total = total + value;
    }
    match std.io.write_stdout(std.convert.format_int(total) + "\n") {
        Result.Ok(_) => (),
        Result.Err(error) => assert_msg(false, std.io.describe_error(error)),
    };
}
```

Create a small input file and run the program:

```console
$ printf '10 -3\n5\n' > numbers.txt
$ compiler/dist/xen check sum.xen
$ compiler/dist/xen run sum.xen -- numbers.txt
12
```

`std.fs.read` returns `Result<String, IoError>` rather than terminating on an ordinary
file error. `match` handles both variants. The parser returns a separate
`Result<Int, ParseIntError>` for malformed or out-of-range tokens. The program uses
`std.string.split_ascii_whitespace`, so the separators are ASCII whitespace bytes; it
does not perform Unicode whitespace or UTF-8 validation.

Change the input to a malformed token to see a runtime failure:

```console
$ printf '10 nope\n' > numbers.txt
$ compiler/dist/xen run sum.xen -- numbers.txt
assertion failed: invalid integer token 1 at byte 0 (value 110)
$ echo $?
1
```

This `assert_msg` runtime failure exits with status 1. Unlike some runtime checks, the
assertion message does not include a source location.
