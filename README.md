<p align="center">
  <img src="assets/branding/full_logo.png" alt="Xen — AI-generated wordmark" width="560">
</p>

<p align="center">
  <strong>A small native language for Linux CLI and systems tools.</strong><br>
  <a href="docs/en/README.md">English docs</a> ·
  <a href="docs/ko/README.md">한국어 문서</a> ·
  <a href="examples/README.md">Examples</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-demo-orange" alt="Status: demo">
  <img src="https://img.shields.io/badge/target-Linux%20x86--64-blue" alt="Target: Linux x86-64">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-see%20scope-lightgrey" alt="Licenses: see scope"></a>
</p>

Xen compiles directly to static, non-PIE ELF executables. Generated programs need
no C compiler, assembler, linker or libc. The compiler is written in OCaml;
the standard library is written in Xen.

**This is an early demo.** Syntax, APIs and diagnostics may change. Linux x86-64
is the only supported host and target. [Scalar scope JIT](docs/en/jit.md) is
experimental, and its current measurements do not establish a speedup over AOT.

## A small example

```xen
use std.string;

fn main() {
    let words = std.string.split_ascii_whitespace("Hello from Xen");
    for index in 0..words.len() {
        println(words.get(index));
    }
}
```

Run [examples/demo.xen](examples/demo.xen) to print `Hello`, `from` and `Xen` on
separate lines.

## Try the demo

Build from source with OCaml and Dune 3.18 or later. The demo was verified
with OCaml 5.5.0. From the repository root:

```sh
make build
compiler/dist/xen version
compiler/dist/xen check examples/demo.xen
compiler/dist/xen run examples/demo.xen
compiler/dist/xen build examples/demo.xen -o /tmp/xen-demo
/tmp/xen-demo
compiler/dist/xen test std.string
```

`check` validates types, ownership and borrows; `build` writes an executable;
`run` builds and executes it; `test` runs native `test fn` functions. See the
[CLI reference](docs/en/cli.md) and [getting started](docs/en/getting-started.md).
`xen version` (or `xen --version`) prints the embedded compiler version.

To prepare a relocatable archive:

```sh
make package VERSION=0.1.0-demo
make source-package VERSION=0.1.0-demo
```

The archive in `dist/` contains `bin/xen`, `stdlib/`, examples, documentation,
branding and license notices. Keep its directory structure intact when moving
it so Xen can discover the adjacent standard library.
The verified demo compiler build requires glibc 2.38 or later and uses the
host's libm; source builds may have different requirements. Generated Xen
executables do not use these libraries.
The separate `*-source.tar.gz` includes the public source and tests without
Git history or local development artifacts.

After extracting it, change into the package directory and run:

```sh
./bin/xen run examples/demo.xen
```

## What is available

- Fixed-width integers and floats, `Bool`, byte-preserving `String`, structs,
  tuples, enums, exhaustive `match` and limited compile-time generics.
- Ownership, lexical cleanup, references, `Vec<T>`, read-only `Slice<T>` and
  move-only `Box<T>` for recursive aggregates.
- A Xen standard library for arguments, byte strings, conversion and recoverable
  file/byte I/O, with `Option<T>`, `Result<T,E>` and postfix `?`.
- Explicit lexical `bb` capability for typed raw memory and Linux syscalls.
- Optional `--opt=basic` scalar optimization and bounded leaf fusion
  (default `off`). Experimental `#scope[jit]` uses the same checked IR;
  `--jit=off` runs its marked source through AOT.

Numbers never convert implicitly. Strings preserve bytes without automatic
UTF-8 validation. Project modules use `import`; toolchain modules use `use std.*`
or `use core.*`. Closures, traits, async, FFI and other targets are not supported.
See [supported features and limitations](docs/en/status-and-limitations.md).

## Learn and contribute

Start with the [guided CLI tutorial](docs/en/tutorial.md), the
[language guide](docs/en/language-guide.md), or runnable tools such as
[key-value parsing](examples/key_values.xen), [file copying](examples/copy_file.xen)
and [word counting](examples/word_count.xen). [Korean documentation](docs/ko/README.md)
is also available.

Bug reports and small, reproducible improvements are welcome at
[skystarry-team/Xen](https://github.com/skystarry-team/Xen). Compiler tests require
Python 3.10 or later and binutils (`objdump`), with no third-party Python packages:

```sh
make test
```

See [contributing](CONTRIBUTING.md) and
[test layout and replay](https://github.com/skystarry-team/Xen/blob/main/tests/README.md).

## License and artwork

Copyright © 2026 vmintf(minsung). The license depends on the path:

| Material | License |
| --- | --- |
| Compiler source and executable | Apache-2.0 |
| Generative/metamorphic verification (`tests/property/`, `tests/semantic_ir_test.ml`) | Apache-2.0 |
| Other original code and documentation | MIT OR Apache-2.0 |
| Branding PNGs | CC BY 4.0 |

[LICENSE](LICENSE) defines the scope and the dual-license exception for Xen
runtime code included in generated user executables. Third-party components
retain their own licenses; see [THIRD_PARTY.md](THIRD_PARTY.md).

The Xen logo and icons are **AI-generated artwork**, supplied by vmintf(minsung).
Their [provenance, attribution and CC BY 4.0 terms](assets/branding/README.md)
are separate from the code licenses.
