# Language guide

This guide is for developers who already know a programming language and want to learn
Xen's model and idioms. Read the pages in order, or use them as topic references.

1. [Getting started](getting-started.md) covers compiler setup, source checking,
   executable generation, and program arguments.
2. [Language basics](language-basics.md) covers values, numeric types, functions,
   expressions, and control flow.
3. [String, Vec, and Slice](strings-and-vectors.md) covers byte strings and collections.
4. [Ownership and references](ownership-and-references.md) explains which values are
   copied, cloned, moved, or borrowed and when cleanup happens.
5. [Generics, enums, tuples, and match](generics-enums-and-match.md) covers user-defined
   types, limited inference from argument types, `Option`, `Result`, and exhaustive matching.
6. [Modules and structs](modules-and-structs.md) covers project organization and methods.
7. [File APIs](file.md) and the [standard library](stdlib.md) cover command-line and
   filesystem programs.
8. [The `bb` capability](low-level-bb.md) covers typed raw memory and Linux syscalls.

For a compact grammar overview, see the [syntax reference](syntax-reference.md).

## Xen's core rules

- Integer and floating-point widths are explicit. Numeric types do not convert
  implicitly; conversion functions are checked.
- Generic function calls can omit all type arguments when static argument types
  uniquely determine them. Expected return types and function bodies are not inference
  sources. Unknown or conflicting parameters require explicit type arguments; partial
  omission is not supported.
- `String` is a byte sequence. Its length is measured in bytes, and it is not required
  to contain valid UTF-8.
- Managed values such as `String` and most `Vec<T>` values are cloned at ordinary
  by-value boundaries. `File`, owning `Box<T>`, and aggregates containing them are
  move-only.
- References are lexical, statically checked borrows. `explc` grants reference
  operations in a lexical region. It does not change how managed values are copied.
- Raw pointers and Linux syscalls require the lexical `bb` capability. Pointer bounds
  are checked; arbitrary address dereferencing is not available.
- Xen function calls, including recursion, allow up to 4096 active function frames,
  counting the entry function. Actual stack exhaustion can happen sooner depending on
  frame and argument sizes.
- Recoverable file and output errors use `Result`. Runtime errors and `panic` terminate
  the process without unwinding.

The [supported-features page](status-and-limitations.md) is the source for the current
target and unsupported constructs in the current demo.

Optional native integer/Bool optimization and bounded leaf fusion are described in
[Basic native optimization](optimization.md). The default is `--opt=off`; [scalar scope JIT](jit.md) is experimental.
