# Xen compiler distribution

This archive contains the compiled Linux Xen compiler, its standard library,
learning examples and license notices. The archive name identifies the compiler's
host architecture; `VERSION` identifies its release version.

Keep `bin/` and `stdlib/` together when moving the distribution. The `.xen` files
in `stdlib/` are runtime modules used by the compiler's source loader.

From the extracted directory:

```sh
./bin/xen version
./bin/xen check examples/demo.xen
./bin/xen run examples/demo.xen
./bin/xen build examples/demo.xen -o app
./app
./bin/xen test std.string
```

Use an archive matching the CPU and OS that will execute the compiler. Its host
system libraries must be available. Generated Xen programs are static Linux
executables and do not require a C compiler, assembler, linker or libc.

The compiler can emit both `x86_64-linux` and `aarch64-linux` programs with
`--target`. Executing a generated program requires a compatible host or a
separately configured emulator. macOS is unsupported.

See `examples/README.md` and the
[language documentation](https://github.com/skystarry-team/Xen/blob/main/docs/en/README.md)
for learning material. Licensing is described in `LICENSE`, `NOTICE` and `THIRD_PARTY.md`.
