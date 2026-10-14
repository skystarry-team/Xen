# Build a word counter

Build a program that accepts a file path and prints the file's word count. This combines variables, functions, strings, and error handling.

## Prepare the input

Create a test file in your working directory:

```sh
printf 'one two\nthree four\n' > input.txt
```

This creates or overwrites `input.txt` in that directory. Save the following code as `word_count.xen`:

```xen
use std.env as env;
use std.fs as fs;
use std.io as io;
use std.string as text;

fn count_file(path: String) -> Result<Int, io.IoError> {
    let contents = fs.read(path)?;
    return Result.Ok(text.split_ascii_whitespace(contents).len());
}

fn main() {
    let arguments = env.args();
    if arguments.len() != 1 {
        panic("usage: word_count <path>");
    }
    match count_file(arguments.get(0)) {
        Result.Ok(count) => println(count),
        Result.Err(error) => { panic(io.describe_error(error)); },
    };
}
```

```console
$ xen run word_count.xen -- input.txt
4
```

## Read the program

`env.args()` returns only arguments passed to the program, excluding the executable name. `input.txt` after `--` becomes the first argument. Quote a path in your shell if it contains spaces.

`count_file` reads the whole file using `fs.read`, propagating a failure with `?`. On success, it counts the items separated by ASCII whitespace. `main` prints that count or describes the read error and terminates.

Here a word means a sequence of bytes separated by ASCII whitespace. The program does not remove punctuation or analyze language-specific words. It reads the whole file at once, so it is unsuitable for very large files.

## Try failures too

Pass a path that does not exist:

```sh
xen run word_count.xen -- missing.txt
```

You will see a file-opening error and a failure exit status. Omitting the path after `--` produces `usage: word_count <path>`. The precise file error number depends on your environment.

## Make a standalone executable

```sh
xen build word_count.xen -o word-count
./word-count input.txt
```

The result is again 4. Direct execution does not need `--`, which separated Xen's options from your program's arguments.

## Continue experimenting

Accept several paths and print a count for each. Change the error arm in `main` if you want to continue after a failed file. See [stdin_words](../../examples/stdin_words.xen) for a program reading standard input. Extracting word counting into a separate function makes it easier to add tests in the [next chapter](testing.md).

---

[Contents](README.md) · [Previous: Working with multiple files](modules.md) · [Next: Testing your code](testing.md) · [한국어](../ko/tutorial.md)
