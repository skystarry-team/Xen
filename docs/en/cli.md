# Command-line reference

The Xen command-line interface has five subcommands:

```text
xen version
xen --version
xen check <file.xen> [--target=<architecture>-<os>]
xen build <file.xen> [-o output] [--target=<architecture>-<os>] [--opt=off|basic] [--opt-report] [--jit=on|off] [--jit-report]
xen run <file.xen> [--target=<architecture>-<os>] [--opt=off|basic] [--opt-report] [--jit=on|off] [--jit-report] [-- program-args...]
xen test [file.xen | directory | std.module] [--filter substring] [--target=<architecture>-<os>] [--opt=off|basic] [--opt-report] [--jit=on|off] [--jit-report]
```

## `version`

`xen version` and `xen --version` print `xen <version>` to stdout and exit 0.
They do not load source or the standard library. The default build version is
declared in the repository's `VERSION` file. `make build VERSION=...` and
`make package VERSION=...` embed the supplied version in the executable;
source archives retain it in their exported `VERSION` file.

## `check`

`xen check file.xen` loads the entry file and its project imports, then checks syntax,
types, ownership, references, and capabilities. It emits no output and exits 0 when the
project is valid. Compiler diagnostics go to stderr and a failed check exits 1.
It uses the selected target's platform stdlib profile; `--target` follows the same
default and validation as build. It does not generate code or accept opt/JIT flags.

## `build`

`xen build file.xen` writes `a.out` in the current directory. Use `-o path` to choose
the output path; parent directories are created when needed. A successful build emits
no output and exits 0. The result is a static non-PIE ELF executable for the
selected Linux target.

## `run`

`xen run file.xen` compiles to a temporary executable, runs it with the current
directory and standard input/output/error, and removes the temporary executable after
the process exits. To pass arguments, put `--` after the source path:

The program's exit status is propagated. A Xen runtime error writes to stderr and
normally exits 1. Put compiler flags before `--`; the delimiter separates them from
program arguments.

This complete program prints the number and first value of its arguments:

```xen
fn main() {
    println(arg_count());
    println(arg(0));
}
```

```console
$ compiler/dist/xen run args.xen -- one two
2
one
```

## `test`

`xen test` recursively discovers tests under the current directory. Give a source file,
directory, or standard-library module as the target. `--filter substring` selects test
display names containing a substring. See the [testing guide](testing.md) for output
and discovery rules.

## Target selection

`check`, `build`, `run`, and `test` accept `--target=x86_64-linux` or
`--target x86_64-linux`, before or after the source/test path. The default follows
the compiler's build architecture on Linux: x86-64 or AArch64. Explicit targets
take precedence. `aarch64-linux` (alias `arm64-linux`) supports the core language,
scalar F32/F64, heap Strings, recursive Box/Vec ownership and borrowed Slice.
JIT defaults to off for ARM64 and on for x86-64 after target selection, regardless
of option order. ARM64 supports raw POD memory/syscalls and platform-dependent stdlib;
numeric file readers and explicit JIT requests remain rejected.
`x86_64-macos` and `aarch64-macos` (OS alias `darwin`) are recognized but unimplemented,
as are Windows targets. They never select a Linux backend implicitly.
Invalid or unavailable targets fail before source loading or output creation.
All source loading uses the generation target, even when the compiler host differs.

`run`/`test` execute through the host kernel and require a compatible CPU/OS or
a configured binary handler; selecting a target does not provide emulation.
For cross execution: `xen build app.xen --target=aarch64-linux --jit=off -o app`,
then `qemu-aarch64 ./app`. Tokens after `run --` remain literal program arguments,
including `--target=...`. See the [compiler architecture](../../compiler/README.md)
for the ARM64 support matrix and the current 64-bit layout/stdlib constraints.

## Optimization

`build`, `run`, and `test` accept `--opt=off|basic` (default `off`).
`--opt-report` requires `basic` and writes region information and transformation
counts to stderr. `check` always examines the original source. See the
[basic optimization contract](optimization.md) for eligible operations and fusion limits.

## Experimental runtime JIT

`--jit=on|off` (default `on` for x86-64, `off` for ARM64) selects execution of explicitly annotated
`#scope[jit]` regions. `off` uses AOT for the same IR. `--jit-report` requires `on`
and embeds runtime compile/cache/timing output. See [runtime JIT](jit.md).

## Exit statuses and usage

| Status | Meaning |
| --- | --- |
| `0` | Command succeeded |
| `1` | Compile/runtime/test failure, discovery error, or no matching tests |
| `2` | Invalid command-line usage |

There is no separate `--help` option. Running `xen` without a valid
command prints the usage text to stderr and exits 2. Module loading can also fail if
the bundled standard library cannot be found. See [modules and structs](modules-and-structs.md)
for `XEN_STDLIB_ROOT` behavior.
