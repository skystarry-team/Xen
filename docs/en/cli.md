# Command-line tools

Commands assume `xen` is on `PATH`. From a distribution directory, substitute `./bin/xen`; from the repository, use `compiler/dist/xen`. On Windows PowerShell, use `.\bin\xen.exe` or `.\compiler\dist\xen.exe`.

| Command | Purpose |
| --- | --- |
| `xen version` or `xen --version` | Show the installed version |
| `xen check file.xen` | Find errors before execution |
| `xen run file.xen` | Run immediately |
| `xen build file.xen -o app` | Make a standalone executable |
| `xen test [file.xen or directory or std.module]` | Run tests |

Successful `check` and `build` commands produce no output. Without `-o`, `build` writes `a.out` for a Linux or macOS target or `a.exe` for a Windows target in the working directory, regardless of the compiler's host OS. An existing output file is overwritten. `run` uses the current working directory and standard input/output, removing its temporary executable when the program exits.

## Program arguments

```sh
xen run word_count.xen -- input.txt
xen build word_count.xen -o word-count
./word-count input.txt
```

Before `--` are Xen options; after it are your program's arguments. Read them with `std.env.args()` or `arg_count()` and `arg(index)`. The first argument has index 0; the executable name is excluded. An invalid `arg` index is a runtime error.

## Choose the execution environment

The default target follows the installed compiler's OS and architecture. `check`, `build`, `run`, and `test` accept `--target=x86_64-linux`, `--target=aarch64-linux`, `--target=x86_64-windows` and `--target=aarch64-macos`. `arm64-linux` and `arm64-darwin` are aliases.

```sh
xen build hello.xen --target=aarch64-linux -o hello-arm64
```

Run the output on a compatible OS and CPU. Selecting another target does not make it executable on the current machine. AArch64, Windows x86-64 and Apple Silicon macOS support are experimental. Apple Silicon native CI validation is pending; Intel macOS and Windows ARM64 remain unsupported. Windows compiler, PE execution and standard library tests pass on Windows Server 2022 native CI; Windows desktop hardware validation is still required. Windows raw syscalls and `extern_call` are unavailable. In PowerShell, build with `-o hello.exe` and execute `.\hello.exe`.

## Select tests

`xen test` searches the current directory. Narrow names with `--filter text`. See [testing](testing.md).

## Optional build options

Normal programs can use the defaults. For blocks you explicitly mark as `#scope[opt] { ... }`, `build`, `run`, and `test` use `--opt=basic` by default. Disable it with `--opt=off`. Unmarked code is unaffected.

`--opt-report` prints application information to stderr. `--opt-cache=directory` stores a build cache in that directory. Both require `basic` and are unavailable for `check`. These options are optional when learning and using the language.

## Exit status and help

| Status | Meaning |
| --- | --- |
| `0` | Success |
| `1` | Code, runtime, or test error, or no matching tests |
| `2` | Invalid command usage |

`run` propagates the program's exit status. Panics and ordinary runtime errors usually exit 1. There is no separate `--help` option. Running `xen` without arguments prints usage to stderr and exits 2.

---

[Contents](README.md) · [Previous: Standard library](stdlib.md) · [Next: Syntax and common problems](reference.md) · [한국어](../ko/cli.md)
