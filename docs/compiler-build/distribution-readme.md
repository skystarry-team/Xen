# Xen compiler distribution

This archive contains the compiled Xen compiler, its standard library,
learning examples and license notices. The archive name identifies the compiler's
host architecture; `VERSION` identifies its release version.

Debian and Ubuntu users can also install the `xen-lang` `.deb` from the same
release. See the [installation guide](https://github.com/skystarry-team/Xen/blob/main/docs/compiler-build/en/installation.md)
for CPU selection, checksum verification, supported OS versions and apt commands.

Keep `bin/` and `stdlib/` together when moving the distribution. The `.xen` files
in `stdlib/` are runtime modules used by the compiler's source loader.

From the extracted directory:

On Linux:

```sh
./bin/xen version
./bin/xen check examples/demo.xen
./bin/xen run examples/demo.xen
./bin/xen build examples/demo.xen -o app
./app
./bin/xen test std.string
```

On Windows x86-64, in PowerShell:

```powershell
.\bin\xen.exe version
.\bin\xen.exe check examples\demo.xen
.\bin\xen.exe run examples\demo.xen
.\bin\xen.exe build examples\demo.xen -o app.exe
.\app.exe
.\bin\xen.exe test std.fs --filter null
```

Windows support is experimental. Compiler, PE execution and standard library
tests pass on Windows Server 2022 native CI. Validation on physical Windows
desktop hardware is still required; Windows ARM64 is unsupported. The ZIP's
relocation test uses an isolated PATH on CI, not a clean Windows installation.

Use an archive matching the CPU and OS that will execute the compiler. Its host
system libraries must be available. Generated Linux programs are static
executables; Windows programs use Windows system DLLs. Neither requires an
installed C compiler, assembler or linker. Using the compiler requires no OCaml,
Dune or Python installation.

The compiler can emit `x86_64-linux`, `aarch64-linux` and `x86_64-windows` programs with
`--target`. Executing a generated program requires a compatible host or a
separately configured emulator. macOS is unsupported.
Windows raw syscalls and `extern_call` are unavailable; use the portable standard
library for file I/O, cwd, arguments and process identity.

See `examples/README.md` and the
[language documentation](https://github.com/skystarry-team/Xen/blob/main/docs/en/README.md)
for learning material. Licensing is described in `LICENSE`, `NOTICE` and `THIRD_PARTY.md`.
