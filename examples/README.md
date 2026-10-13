# Runnable example corpus

`arm64_collections.xen` exercises deep Vec clones, Slice views, consuming
iteration and HashMap<Box<String>>. Run with `--target=aarch64-linux` on a
compatible host, or build and execute explicitly under QEMU.

The canonical learning examples and their expected output are embedded in the
[English documentation](https://github.com/skystarry-team/Xen/blob/main/docs/en/README.md). The `.xen` files in this directory are
additional runnable smoke and regression examples; documentation does not rely on
these files for its source code.

Use `bin/xen` from a binary distribution or `compiler/dist/xen` from a source build.
Place the executable's directory on `PATH` to use `xen` in these commands:

```console
$ xen check examples/basics.xen
$ xen run examples/basics.xen
120
2.5
7
positive
```

## Programs

`arm64_core.xen` demonstrates the initial ARM64 subset. Build it with
`xen build examples/arm64_core.xen --target=aarch64-linux -o app`,
then execute it on Linux ARM64 or with `qemu-aarch64 ./app hello`.
`arm64_float.xen` demonstrates scalar F32/F64 operations, checked conversions,
aggregate returns and decimal output with the same build flags.
`arm64_heap.xen` demonstrates heap String production and a recursive Box list,
including ownership transfer and cleanup, with the same build flags.
`file_lifecycle.xen` also runs on ARM64: it transfers owned File descriptors,
writes and reads bytes, and closes them on scope exit. Pass a disposable path;
the program creates or overwrites it. This uses the managed File runtime rather
than the recoverable std.fs module. Both managed File and std.fs are supported
on Linux x86-64 and ARM64.

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
| `file_lifecycle.xen` | Owned File transfer and lexical cleanup, including ARM64 |
| `word_count.xen` | ASCII byte tokenization |
| `key_values.xen` | Byte search, extraction and LF-separated `key=value` input |

File examples may create or overwrite their destination. Pass a disposable path to
`file_lifecycle.xen`, `copy_file.xen`, and other writing examples. Programs that read a
file accept its path after `--`, as described in the [CLI reference](https://github.com/skystarry-team/Xen/blob/main/docs/en/cli.md).

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
guide](https://github.com/skystarry-team/Xen/blob/main/docs/en/diagnostics.md).

`opt_regions.xen` demonstrates scalar AOT optimization inside `#scope[opt]`.
`opt_loops.xen` computes loop-invariant arithmetic once per invocation.
`opt_fusion.xen` fuses two independent integer loops with identical trip counts.
Repeat `xen run examples/opt_fusion.xen --opt-cache=.xen-opt-cache --opt-report`
to inspect exact-prefix hits; changed or broken prefixes rebuild their suffix.
Use `xen run examples/opt_loops.xen --opt-report` to inspect transformations,
or `--opt=off` to compare the original checked IR.
