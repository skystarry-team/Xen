# Native tests

Declare a parameterless, nongeneric `Unit` function with `test fn`. It is compiled
through the normal checker and native backend, then run as an independent executable.
The test runner does not require `main`. Tests can use `assert`, `assert_msg`, and
`panic`. Function mode attributes such as `#![bb]` can precede a test.

Save this as `tests.xen`:

```xen
test fn vector_push() {
    let mut values = [1, 2];
    values.push(3);
    assert(values.len() == 3);
}
```

```console
$ compiler/dist/xen test tests.xen
PASS tests.vector_push
1 passed; 0 failed
```

Tests discovered from source files run in sorted order. A directory remains the project
source root, so imports resolve from that root. Hidden directories, `_build`, `dist`,
`stdlib`, and symlinked files or directories are not recursively searched. A file
target uses that file's directory as its source root. Toolchain tests can be selected
with a module target such as `xen test std.fs`.

Each selected test compiles the full source graph, so a filter does not hide type errors
in other functions in that graph. The runner continues after a failing test. Successful
tests hide stdout and stderr; failed tests retain their output. Test stdin is `/dev/null`,
arguments are empty, and cwd/environment are inherited. There is no fixture, mock,
snapshot, async, plugin, or timeout framework. A test that does not terminate must be
stopped manually.

The overall exit status is 0 when all selected tests pass, 1 for test, compile,
discovery, or no-match failures, and 2 for invalid CLI usage. See the [CLI
reference](cli.md) for target forms.
