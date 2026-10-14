# Testing your code

Use `test fn` to check a small behavior. Test functions take no arguments and return no value. Check and run a test-only file without `main` using `xen test`. The ordinary `check`, `run`, and `build` commands require `main`. Save this as `testing.xen`:

```xen
fn doubled(value: Int) -> Int {
    return value * 2;
}

test fn doubles_a_number() {
    assert(doubled(3) == 6);
}

test fn empty_vector() {
    let values: Vec<Int> = [];
    assert_msg(values.len() == 0, "an empty vector has no items");
}
```

```console
$ xen test testing.xen
PASS testing.doubles_a_number
PASS testing.empty_vector
2 passed; 0 failed
```

`assert` checks that a condition is true. `assert_msg` adds a message for failure. Change the expected value in the first test to 7 and observe the failure.

## Select tests

```sh
xen test testing.xen --filter doubles
xen test .
xen test std.string
```

Select a file, a directory, or a standard-library module. With no target, `xen test` searches the current directory. `--filter` selects names containing the given text. No discovered tests or no matching names is a failure.

A directory target also becomes the root for project imports. Discovery skips hidden directories, `_build`, `dist`, `stdlib`, and symbolic links. You can still select standard-library tests explicitly with `xen test std.string`.

## Understand the result

Tests run individually in name order, continuing after failures. Output from passing tests is hidden; output from failing tests is shown. Tests have no program arguments and an empty standard input. The working directory and environment come from where you ran the command.

Prepare temporary data yourself for tests using file input. There is no separate fixture, mock, async, or automatic timeout framework. Stop a nonterminating test manually.

A filter does not hide type errors in other functions in the same project. The exit status is 0 if all selected tests pass, or 1 for errors and failures.

---

[Contents](README.md) · [Previous: Build a word counter](tutorial.md) · [Next: Standard library](stdlib.md) · [한국어](../ko/testing.md)
