# Runnable example corpus

The canonical learning examples and their expected output are embedded in the
[English documentation](../docs/en/README.md). The `.xen` files in this directory are
additional runnable smoke and regression examples; documentation does not rely on
these files for its source code.

Build Xen from the repository root, then check and run a small example:

```console
$ dune build @release
$ compiler/dist/xen check examples/basics.xen
$ compiler/dist/xen run examples/basics.xen
120
2.5
7
positive
```

## Programs

| File | Topic |
| --- | --- |
| `demo.xen` | README example: split a byte string and print each word |
| `native_core.xen` | Control-flow smoke test |
| `basics.xen` | Fixed-width types, conversions, loops, and conditionals |
| `strings_and_vectors.xen` | Strings, vectors, empty-vector annotations, and slices |
| `generic_vectors.xen` | Generic vectors, managed structs, and cloning |
| `structs_and_generics.xen` | Nested and generic structs |
| `enums_and_match.xen` | Enums, tuples, `Option`, `Result`, and exhaustive matching |
| `recursive_ast.xen` | Recursive tree ownership with `Box` |
| `ownership_and_references.xen` | Clone, move, lexical scopes, and references |
| `raw_memory_bb.xen` | Typed raw memory, POD layout, and Linux syscalls |
| `modules/app.xen` | Project imports and qualified names |
| `sum_file.xen` | Parse and sum decimal integers in a file |
| `copy_file.xen` | Recoverable binary file copy |
| `word_count.xen` | ASCII byte tokenization |
| `key_values.xen` | Byte search, extraction and LF-separated `key=value` input |

File examples may create or overwrite their destination. Pass a disposable path to
`file_lifecycle.xen`, `copy_file.xen`, and other writing examples. Programs that read a
file accept its path after `--`, as described in the [CLI reference](../docs/en/cli.md).

`key_values.xen` reads stdin without arguments or a file with one path argument. It
ignores blank LF-separated lines, accepts empty values, and preserves whitespace,
NUL, non-UTF-8 bytes, and any `=` after the first one. It prints `key: value` records.
Missing `=` or an empty key reports the one-based line number and exits unsuccessfully.
CR is an ordinary byte; this example does not normalize CRLF or parse a configuration format.
It uses `std.option.unwrap_or` for an absent separator and `std.result.map_err` to combine
I/O and byte-range failures with parse errors in one `AppError`. File-local module aliases
shorten API calls, and a tuple `let` unpacks the key/value pair after `?`.

## Expected compile failures

Files under `errors/` are negative compiler examples. A nonzero `check` status is
expected, and they are not `run` targets. Each file includes a comment naming the
intended diagnostic.

For complete, stable error examples with their output, use the [diagnostics
guide](../docs/en/diagnostics.md).

`jit_regions.xen` demonstrates the experimental scalar runtime JIT: the first
call compiles a region, and later calls reuse it with different arguments.
Use `xen run examples/jit_regions.xen --opt=basic --jit-report` for statistics,
or `--jit=off` for the AOT comparison.
