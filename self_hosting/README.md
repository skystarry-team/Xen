# Building Xen with Xen

This directory contains a **self-hosting compiler for a subset of Xen**. Lexical analysis, function declaration collection, parsing, type checking, x86-64 machine code generation, and ELF construction are all implemented in Xen. The existing OCaml compiler is used to produce the initial executable. Subsequent stages do not invoke an external compiler, assembler, or linker.

The current scope is **a subset of Xen supporting scalar values and POD structs on Linux x86-64**. It does not yet support compiling the full Xen language or its standard library.

## Where to Start Reading

The entry point is `compiler.xen`. The implementation is divided by responsibility under `src/`.

| File | Responsibility |
| --- | --- |
| `compiler.xen` | Overall flow: CLI → input → compilation → output |
| `src/compiler.xen` | Shared pipeline for input reading, analysis, code generation, and relocation |
| `src/cli.xen` | Argument and file path handling, build/check commands, executable output |
| `src/cli_text.xen` | Fixed byte sequences for help text and CLI errors |
| `src/context.xen` | `Context` struct, buffer allocation, and shared counter locations |
| `src/runtime.xen` | Memory reads and writes, mmap, Linux I/O |
| `src/lexer.xen` | Token storage, traversal, and lexical analysis |
| `src/diagnostics.xen` | Compilation error reporting and termination |
| `src/keywords.xen` | Keywords and reserved intrinsic names |
| `src/records.xen` | Type and struct declarations, size and alignment, fields, cycle detection |
| `src/symbols.xen` | Function signatures and local variable scopes |
| `src/expressions.xen` | Expression parsing, calls, constructors, field access |
| `src/statements.xen` | Assignment, branching, loops, function entry and return |
| `src/intrinsics.xen` | Supported asm constraints and syscall signatures |
| `src/x86_64.xen` | Instruction bytes, stack frames, value copying, branches, integer operations |
| `src/elf.xen` | ELF64 headers and println runtime |

The current file organization is **a source-level separation**, not an implementation of namespaces or Xen's `import` mechanism. `assemble.sh` concatenates the files listed in `sources.list` without transforming their contents, producing a single compilation unit at `build/compiler.xen`. When adding a file, update this list. Actual module loading and namespace handling are planned extensions.

## Reproducing the Build

From the repository root:

```sh
./self_hosting/bootstrap.sh
./self_hosting/verify.sh
```

The default stage0 compiler is `compiler/dist/xen`. To use a different Xen executable, specify its absolute path:

```sh
XEN_STAGE0=/path/to/xen ./self_hosting/verify.sh
```

If the existing compiler is unavailable, first run `make build` from the repository root. Generated artifacts are stored in `self_hosting/build/`, which is excluded from Git.

| Stage | Built by | Input |
| --- | --- | --- |
| stage0 | Existing OCaml implementation | Existing compiler |
| scalar-seed | stage0 | `bootstrap/scalar.xen` — initial scalar implementation |
| records-seed | scalar-seed | `bootstrap/records.xen` — struct-supporting implementation written using scalar syntax |
| driver | records-seed | `bootstrap/driver.xen` entry point and current `src/` — stdin-only transitional driver |
| stage1 | driver | Assembled `build/compiler.xen` — current implementation with CLI |
| stage2 | stage1 | Same `build/compiler.xen` |
| stage3 | stage2 | Same `build/compiler.xen` |

`bootstrap.sh` verifies that **stage2 and stage3 are byte-for-byte identical** and prints their SHA-256 hashes.

Stage1 is produced by a transitional driver originating from the earlier seeds, while stage2 and stage3 are built using the new CLI. The required fixed-point check is byte-for-byte equality between stage2 and stage3.

The shell handles source concatenation, program execution, redirection and executable permissions during the initial stages, and output comparison. Starting with stage1, Xen's CLI `build` command writes the next-stage executable. Language processing, executable generation, CLI argument handling, and file operations are performed by Xen code.

`bootstrap/scalar.xen` and `bootstrap/records.xen` are historical implementations retained to preserve the incremental bootstrap path. Normal development takes place in the current `src/` directory. New features do not require updating these snapshots.

## CLI

The bootstrap process also copies the final executable to `self_hosting/build/xen`.

To compile a separate program:

```sh
./self_hosting/build/xen --help
./self_hosting/build/xen check self_hosting/examples/core.xen
./self_hosting/build/xen build self_hosting/examples/core.xen -o /tmp/xen-core
/tmp/xen-core
```

The default output of `build` is `a.out` in the current directory. The `-o` option may appear before or after the input path.

After successful compilation, the output is written to a unique temporary file in the destination directory. The file is given `0755` permissions, closed, and then published by renaming it over the destination.

If compilation or output fails, the existing output file is preserved. Temporary files are removed on handled output errors. A forced termination may leave temporary files behind, and `fsync` is not performed for disk durability.

`check` does not save or execute an executable. It currently runs the full compilation pipeline, so code generation restrictions and errors also apply.

The path `-` represents stdin or stdout. Paths containing spaces or Korean characters can be quoted in the shell. Input filenames beginning with `-` must follow `--`.

```sh
./self_hosting/build/xen build 'working folder/example.xen' -o 'working folder/example'
./self_hosting/build/xen check -- -example.xen
./self_hosting/build/xen build - -o - < self_hosting/examples/core.xen > /tmp/xen-core
```

When invoked without arguments, the compiler prints the same help text as `--help` and exits with status 0.

To compile from stdin to stdout, explicitly use `build - -o -`:

```sh
./self_hosting/build/xen build - -o - < self_hosting/examples/core.xen > /tmp/xen-core
chmod +x /tmp/xen-core
/tmp/xen-core
```

Only the completed ELF executable is written to stdout. Errors are written to stderr. If compilation fails, no ELF data is emitted.

The `run` command, project loading, modules, and imports are not yet implemented. Until String support is available, help text and CLI error messages are emitted as fixed byte sequences from `cli_text.xen`.

The `arg_count()` and `arg()` intrinsics are not yet implemented.

## Supported Xen Subset

| Area | Supported features |
| --- | --- |
| Values | `Int` (signed 64-bit integer), `Bool`, `Unit` as a function return type |
| Structs | Int, Bool, and nested struct fields; constructors; field reads and assignments; value copying |
| Functions | 0–6 arguments, struct arguments and returns, type checking, recursion, mutual recursion, forward calls |
| Variables | `let`, `let mut`, inferred and explicit types, assignment, block scopes, shadowing |
| Control flow | Blocks, `if` / `else if` / `else`, `while`, `return` |
| Integers | Decimal literals, `+ - * / %`, unary `+ - ~`, `& \| ^ << >>` |
| Comparisons | `== != < <= > >=`, Boolean `== !=` |
| Logic | `!`, `&&`, `\|\|`, with short-circuit evaluation of the right operand |
| Output and checks | `println(Int)`, `assert(Bool)` |
| Low-level operations | File-leading `#global[bb]`, `syscall0`–`syscall6`, and the four asm forms below |
| Other | Whitespace, `//` comments, required `fn main()` |

Ordinary function arguments are evaluated exactly once, from left to right. Syscalls accept up to seven expressions, including the syscall number. `main` must take no arguments and return `Unit`. Declarations following `#global[bb]` must begin on a new line.

Integer addition, subtraction, multiplication, and negation use wrapping semantics. Division truncates toward zero, and the remainder has the same sign as the dividend.

Division or remainder by zero, `Int.min / -1`, out-of-range shifts, and failed assertions terminate execution with exit status 101.

Structs have value semantics. Modifying one value after a local variable copy, assignment, function argument passing, or function return does not modify the other.

Nested field assignments modify the original value declared with `let mut`.

Field layout matches the existing Xen implementation: `Int` has size and alignment 8, `Bool` has size and alignment 1, and nested structs use their own alignment.

Constructor fields are evaluated in **struct declaration order**, matching the current behavior of the existing Xen compiler.

Missing, duplicate, or incorrectly typed fields, empty structs, and direct or indirect value cycles are rejected. Struct equality and inequality (`==` and `!=`) are not supported.

The following are the **only supported asm templates and constraints**. String literals are supported only in this syntax.

Function bodies are not replaced based on function names. Memory helper functions are parsed and compiled in the same way as any other function.

```xen
asm<Int>("mov rax, [rdi]", in("rdi", address), out("rax"))
asm("mov [rdi], rsi", in("rdi", address), in("rsi", value))
asm<Int>("movzx rax, byte [rdi]", in("rdi", address), out("rax"))
asm("mov [rdi], sil", in("rdi", address), in("rsi", value))
```

Addresses and mappings are represented as `Int` values, with memory allocated through the `mmap` syscall.

This uses the existing Xen semantics for `bb` and asm. The caller is responsible for managing memory address validity and lifetime.

The existing representations of `String` and `Ptr<T>` are not replaced with simplified or incompatible representations.

## Not Yet Supported

The following features are not implemented:

`String` values, vectors, enums, tuples, generics, Box, ownership, references, the standard library, modules and imports, floating-point values, `for`, `break`, `continue`, `match`, value-producing `if` expressions, exponentiation, general-purpose asm, `#scope`, function attributes, optimization, and other CPU architectures or operating systems.

Trailing block expressions and the `()` value are also unsupported.

Unsupported syntax is rejected with an error. There is no fallback path that delegates compilation to stage0.

The implementation has the following fixed limits:

| Resource | Limit |
| --- | --- |
| Source size | Less than 1 MiB |
| Tokens | 262,142, excluding EOF |
| Output size | 4 MiB |
| Functions | 256 |
| Active variables per function | 512 |
| Stack frame, including temporaries and arguments | 64 KiB |
| Call relocations | 65,536 |
| Structs | 128 |
| Fields per struct | 32 |
| Struct size | 32 KiB |

There are no separate limits or diagnostics for parser recursion depth or runtime stack usage.

Error messages and exit codes are not identical to those of the existing compiler.

## Implementation Architecture

The same source assembled through `sources.list` is used as input for stage1 through stage3.

Only the transitional driver replaces the entry point, using:

```sh
assemble.sh bootstrap/driver.xen
```

The driver uses the same current `src/` implementation, avoiding duplication of the compiler.

Executables produced by the historical records-seed lack the new startup information. Therefore, a stdin-only transitional driver is used to produce the first executable with the CLI using the current backend.

The compilation pipeline consists of the following stages:

1. `lex`: Stores tokens as 32-byte records.
2. `declarations`: Collects function signatures and body token positions.
3. `compile_function`: Parses function bodies while performing type checking and code generation.
4. `expression`: Handles precedence parsing, integer operations, short-circuit evaluation, and function calls.
5. `block` and `statement`: Handle variable scopes, branches, loops, and returns.
6. `elf` and `patch`: Complete the static ELF64 headers and relative call and branch addresses.

Buffer addresses are passed through the `Context` struct.

Shared counters and token and symbol tables are still stored in raw memory. Counters are accessed through `state_get` and `state_set`, and their numeric identifiers are defined in `src/context.xen`.

The compiler itself uses `make_context() -> Context`, so self-compilation also exercises the calling and return conventions for struct values.

Local variables and temporary struct values reside in stack storage relative to `rbp`. Scalar expression temporaries use `push` and `pop`.

Ordinary function arguments use the registers:

```text
rdi rsi rdx rcx r8 r9
```

Syscalls place the syscall number in `rax` and arguments in:

```text
rdi rsi rdx r10 r8 r9
```

Struct arguments are passed as addresses of independent snapshots. The callee saves all argument registers before copying the arguments into its own stack frame.

For struct returns, the caller passes the address of a temporary return area as a hidden `r10` argument. The result is copied into this area before returning.

This is the compiler's internal calling convention, not the C ABI.

The ELF executable separates the RX code segment from the RW startup-information segment.

Before the first function call, the entry code stores the initial Linux stack address at `0x800000`.

The CLI reads `argc` and NUL-terminated `argv` strings through the existing memory-reading functions, without depending on procfs.

The code segment begins at `0x400000` and is limited to 4 MiB, so it does not overlap the startup-information area.

This address is part of the generated executable's internal convention, not a general pointer or String API.

Large decimal constants used for keyword and asm comparisons encode ASCII bytes packed in little-endian order.

Name comparisons examine the complete original byte sequences and do not rely on hash collisions.

## Verification and Progress

The following tests were performed on Linux x86-64 on October 16, 2026.

- Self-compilation from stage1 through stage2 to stage3, including byte-for-byte equality between stage2 and stage3.
- `core.xen`: Recursion, forward calls, evaluation order for six arguments and nested calls, integer boundaries, signed division, operator precedence, short-circuit evaluation, variable scopes, branching, and loops.
- `memory.xen`: Actual mmap allocation, all four asm forms, and syscalls. Both examples produced identical runtime output with stage0 and stage2.
- `records.xen`: Constructor evaluation in declaration order, nested field mutation, copy independence, struct return lifetime and recursion, six arguments mixing structs and scalars, consecutive Bool fields, and copying structs of sizes 1 and 5 bytes. Runtime output matched between stage0 and stage2.
- The incremental bootstrap path from the initial scalar implementation to the struct-supporting scalar implementation and then to the Context-based implementation, including final stage2/stage3 byte equality.
- Rejection of invalid types, variables, functions, returns, literals, syscalls without `bb`, and unsupported syntax, with verification that stdout remains empty.
- Rejection of calls to functions shadowed by local variables, function declarations using reserved intrinsic names, and statements after returns, by both stage0 and stage2.
- Verification of exit codes for invalid division, remainder, shifts, and failed assertions.

Following initial scalar self-hosting, the compiler has now reached **self-hosting with structs used in the compiler implementation itself**.

A possible next step is to add `String` and dynamic buffers, allowing address-based tables and numeric diagnostics to migrate to ordinary data types.

Actual modules and standard library support are also future work.

After adding the CLI, `bootstrap.sh` was run to generate stage2 and stage3 using the new `build` command, and the two files were confirmed to be byte-for-byte identical.

The full regression suite described above was not rerun after the CLI changes.

## Error Codes

Compilation errors use the format:

```text
E<code> <zero-based source byte offset>
```

When compiling the compiler itself, the byte offset refers to the assembled `build/compiler.xen`.

| Code | Meaning |
| --- | --- |
| 101–103 | Missing required symbol, keyword, or expression, or unsupported syntax |
| 201–210 | Token, number, string, character, output, function, variable, relocation, source, or input errors |
| 301–302 | Type mismatch or unsupported type |
| 303–305 | Reserved name, duplicate function, too many arguments |
| 306–309 | Unknown variable, duplicate variable, unknown function, assignment to immutable variable |
| 310–312 | Missing return path, missing main, invalid main signature |
| 313–314 | Calling a scalar local variable, unreachable statement |
| 401–404 | Unsupported asm, invalid register constraint, missing bb permission, missing newline after global declaration |
| 501–506 | Duplicate struct, invalid field declaration, unknown field, missing or duplicate constructor field, value cycle, struct limit exceeded |

Memory allocation failures exit with status 70, output failures with 74, and compilation errors with 1.

CLI argument errors exit with status 64, input file open failures with 66, output file creation or publication failures with 73, and file write or close failures with 74.

Filesystem errors include the path and Linux errno.

Source read failures retain the existing `E210` diagnostic and exit status 1.

Both `--help` and a successful `check` exit with status 0.