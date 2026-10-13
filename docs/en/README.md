# Xen documentation

This documentation describes the language and tools implemented by the compiler in
this repository. Xen currently generates Linux x86-64 static non-PIE ELF programs.
Examples labeled as errors are expected to fail; their command output is part of the
example.

## Learning path

1. [Get started](getting-started.md): locate the compiler and run a program.
2. [Guided tour](tutorial.md): build a small command-line program using the standard
   library.
3. [Language guide](language-guide.md): follow the concepts in a useful order.
4. Read the [language basics](language-basics.md), [values and ownership](ownership-and-references.md),
   [collections](strings-and-vectors.md), [types and matching](generics-enums-and-match.md),
   and [modules](modules-and-structs.md) as needed.

## Reference

Compiler installation and source builds are covered separately in the
[compiler build guide](../compiler-build/en/build.md), including
[AArch64 cross toolchains](../compiler-build/en/aarch64.md) and
[packaging](../compiler-build/en/packaging.md).

- [Command-line reference](cli.md): `check`, `build`, `run`, and `test`.
- [Syntax reference](syntax-reference.md): declarations, types, statements, expressions,
  and patterns.
- [String, Vec, and Slice](strings-and-vectors.md)
- [Ownership and references](ownership-and-references.md)
- [Box and recursive data](box-and-recursive-aggregates.md)
- [Generics, enums, tuples, and match](generics-enums-and-match.md)
- [Modules and structs](modules-and-structs.md)
- [File APIs](file.md) and the [standard library](stdlib.md)
- [Low-level `bb` capability](low-level-bb.md)
- [Diagnostics](diagnostics.md)
- [Native tests](testing.md)
- [Supported features and limitations](status-and-limitations.md)

The standard library is Xen source distributed with the compiler. Project modules use
`import`; toolchain modules use `use std.*` or `use core.*`. Existing standalone
examples are collected under [`examples/`](../../examples/README.md), while every
example in this guide is shown directly on its page.

Explicit `#scope[opt]` blocks use integer/Bool AOT optimization, bounded leaf
expansion and conservative loop-invariant code motion. Unmarked code is unchanged.
See [scoped AOT optimization](optimization.md).
