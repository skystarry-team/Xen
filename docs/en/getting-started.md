# Getting started

Xen generates static Linux ELF programs for x86_64 or AArch64. The default target
follows the compiler's Linux build architecture. A generated program does not
need a C compiler, assembler, linker or libc.

Compiler installation, source builds and cross toolchains are documented in the
[compiler build guide](../compiler-build/en/build.md). The source-built executable
is `compiler/dist/xen`; a binary distribution provides `bin/xen`, the standard
library and learning examples. Extract the archive and keep its directory structure intact so the compiler can find the
adjacent standard library. Use `<package>/bin/xen`, or put that `bin` directory on
`PATH`. If Xen is already on `PATH`, use `xen` in the commands below.

## Your first program

Save this as `hello.xen`:

```xen
fn main() {
    println("hello, Xen");
}
```

Every executable program defines a parameterless `main` function that returns `Unit`.
Check the source, generate an executable, and run it:

```console
$ compiler/dist/xen check hello.xen
$ compiler/dist/xen build hello.xen -o hello
$ ./hello
hello, Xen
```

`check` parses the project and checks types, ownership, and borrows. `build` writes a
static non-PIE ELF executable. `run` compiles to a temporary executable, runs it, and
removes that temporary file:

```console
$ compiler/dist/xen run hello.xen
hello, Xen
```

## Program arguments

Put `--` between Xen's source path and the arguments for the Xen program:

```xen
fn main() {
    println(arg_count());
    println(arg(0));
}
```

```console
$ compiler/dist/xen run args.xen -- report.txt
1
report.txt
```

Use `std.env.args()` when a program needs the full argument vector. See the [CLI
reference](cli.md) for every command and its exit status.

## Keep learning

The [guided tour](tutorial.md) builds a small file-processing CLI. The [language
guide](language-guide.md) links each topic to its reference page. Xen's compiler test
suite is for contributors; language-level tests use `test fn` and `xen test` as
described in the [testing guide](testing.md).
