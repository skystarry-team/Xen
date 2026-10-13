# Supported features and limitations

This page describes the current demo's full feature set on the
Linux x86-64 static non-PIE ELF target. The Linux ARM64 backend supports
an integer/float/Bool, control-flow, function, reference, aggregate, heap-string
and recursive Box/Vec ownership with borrowed Slice views, `std.string`, `std.iter`
and `std.hashmap`, managed `File` operations and `read_text`. The CLI defaults to the compiler's build architecture on Linux;
explicit `--target` overrides it.
ARM64 also supports Ptr/raw POD memory/syscalls and target-selected std.io/fs/env/process.
ARM64 supports checked numeric file readers. See its
[support matrix](../../compiler/cpu/arm64/README.md).

macOS on Intel and Apple Silicon is unsupported and has no planned support.
CPU encoders and internal Darwin/Mach-O prototypes are retained for implementation
testing. No macOS compiler or binary package is supplied.

## Supported

- `I8`, `U8`, `I16`, `U16`, `I32`, `U32`, `I64`, `U64`, `F32`, `F64`, `Bool`, `Unit`,
  and the compatibility names `Int = I64`, `Float = F64`.
- Contextual numeric literals, checked explicit conversions, width-specific wrapping
  integer `+`, `-`, and `*`, and scalar comparison.
- Functions and recursion up to six parameters and at most 4096 active source function
  frames, including the entry function. The process stack can be exhausted sooner
  depending on frame and argument sizes. `if` statements and expressions, `while`,
  `break`, `continue`, lexical blocks, `return`, structural `for`, and half-open `Int`
  ranges.
- Byte-preserving immutable `String`; generic `Vec<T>`; read-only, non-escaping
  `Slice<T>`; tuples; named structs with aligned layout; payload enums; limited
  monomorphized generics; exhaustive `match`; prelude `Option<T>` and `Result<T, E>`.
- Generic function type argument inference from known static argument types, including
  independent parameters and existing structural matching; explicit call suggestions
  for unknown parameters. See [inference limits](generics-enums-and-match.md).
- Generic-body matching of known enum/tuple shapes and typed callbacks, with symbolic
  restrictions preserved through locals, patterns, projections and calls.
- Byte search, owned extraction and delimiter splitting through `std.string`;
  see the [standard library](stdlib.md).
- `Result`-only postfix `?` when the function returns `Result<U, E>` with the same `E`.
- `std.option.unwrap_or` and `std.result.map_err` for eager fallback and explicit error conversion with a concrete named callback.
- Recursive clone, move, and drop for managed values; move-only `File` and owning
  `Box<T>`; shared/mutable references and non-lexical borrow end points.
- Nested struct/tuple field assignment, shared `match` with `ref` bindings, and generic reference parameters.
- Lazy iterator map/filter, ordered fold/collect and consuming Vec iteration; standard-library String-key HashMap.
- Irrefutable `let` bindings with `_` and nested tuples, whole-pattern annotations and `mut`.
- Project `module`/`import`, file-local module aliases, toolchain `use std.*` and `use core.*`, bundled Xen-source
  standard library, and concrete named function values.
- `explc` and `bb` lexical capabilities; typed raw pointers for scalar/POD values and
  Linux x86-64/AArch64 syscall primitives with 0 through 6 arguments within `bb`.
- `xen check`, `build`, `run`, and native `test` commands.
- Explicit `#scope[opt]` AOT integer/Bool optimization, bounded leaf expansion and
  conservative loop-invariant code motion, independent counted-loop fusion and
  optional persistent forward prefix caching; see [optimization](optimization.md).
  Unmarked source is not optimized.

- Runtime compilation and `jit` modes/options have been removed.

## Not supported

- Generic function inference from expected return types or function bodies, partial
  type arguments, common type search, or implicit numeric conversions.
- Targets other than Linux x86-64 and the initial Linux ARM64 subset; dynamic linking, FFI,
  GPU execution, exceptions, or asynchronous I/O.
- Pointer arithmetic, address-to-pointer conversion, or arbitrary address
  dereferencing.
- String indexing/slicing syntax and mutation; mutable slices; returning or escaping slices,
  or storing slices in vectors (local struct fields preserve the owner's borrow);
  automatic collection iteration.
- Package manifests, re-exports, visibility controls, and separate
  project module search paths.
- Match guards, struct patterns, or destructuring assignment.
- Method-local type parameters, static/extension methods, trait bounds, overloads,
  closures, and generic function values. Methods in `impl<T> Type<T>` are supported.
- Reference fields, reference returns, temporary borrows, reference-to-reference, or
  mutable reborrow syntax.
- `Box` containing reference, slice, or pointer values; moving a field through a
  borrowed box.
- `Option` propagation with `?` or implicit conversion between `Result` error types; use `std.result.map_err` for explicit conversion.
- Legacy `File` seek and append, environment-variable lookup, process spawn/wait/pipe,
  stdin/stdout File wrapping, and lazy directory iteration.
- Range steps, inclusive ranges, reverse ranges, locale-aware parsing, CSV, streaming
  parsing, fixed-width integer parsing beyond `Int`, or floating-point stdlib
  formatting/parsing.

For details about a particular boundary, use the linked topic page. This is a demo;
syntax and APIs may change.
