# AArch64 OCaml cross toolchain

This procedure builds an OCaml compiler that **runs on Linux x86_64 and generates
AArch64 code**. It is used to build the AArch64 executable of the Xen compiler.
On an AArch64 machine, use [native OCaml and the ordinary Xen build](build.md).
Cross OCaml is not needed merely to emit AArch64 Xen programs from an x86_64 Xen compiler.

OCaml 5.5's cross compiler support is experimental and requires a native OCaml
installation of exactly the same version. The following commands use 5.5.0 and
follow [OCaml's cross build instructions](https://github.com/ocaml/ocaml/blob/5.5.0/INSTALL.adoc).

## Prepare the host tools

Install native OCaml 5.5.0 and Dune 3.18 or later using the [native build guide](build.md).
Keep the native OCaml installation selected by `PATH`.
On Ubuntu/Debian, install the AArch64 C toolchain, target libc and QEMU:

```sh
sudo apt install build-essential gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
  libc6-dev-arm64-cross qemu-user curl
ocamlc -version
ocamlopt -version
aarch64-linux-gnu-gcc --version
```

These C tools build OCaml and link the Xen compiler executable. Xen program
generation itself remains independent of a C compiler or linker.

## Build cross OCaml from source

Use a fresh source directory distinct from the native OCaml build. The persistent
prefix below is user-owned and does not require a system-wide installation:

```sh
XEN_OCAML_SOURCE_ROOT="$HOME/.local/src/xen-ocaml-5.5.0"
XEN_OCAML_AARCH64_PREFIX="$HOME/.local/opt/ocaml-aarch64-5.5.0"
mkdir -p "$XEN_OCAML_SOURCE_ROOT/aarch64"
curl --fail --location https://github.com/ocaml/ocaml/archive/refs/tags/5.5.0.tar.gz \
  --output "$XEN_OCAML_SOURCE_ROOT/ocaml-5.5.0.tar.gz"
tar -xzf "$XEN_OCAML_SOURCE_ROOT/ocaml-5.5.0.tar.gz" \
  -C "$XEN_OCAML_SOURCE_ROOT/aarch64" --strip-components=1
cd "$XEN_OCAML_SOURCE_ROOT/aarch64"
test "$(ocamlc -version)" = "$(head -n 1 VERSION)"
./configure --prefix="$XEN_OCAML_AARCH64_PREFIX" --target=aarch64-linux-gnu \
  --without-zstd CC=aarch64-linux-gnu-gcc CC_FOR_BUILD=gcc
make crossopt -j2
make installcross
```

Do not add the cross prefix to the normal `PATH`: Dune needs native OCaml to
build tools that execute during the build. Select cross OCaml by its absolute
path or inside a dedicated Dune context.

Check the installed configuration:

```sh
test "$("$XEN_OCAML_AARCH64_PREFIX/bin/ocamlc" -config-var architecture)" = arm64
test "$("$XEN_OCAML_AARCH64_PREFIX/bin/ocamlopt" -config-var system)" = linux
test "$("$XEN_OCAML_AARCH64_PREFIX/bin/ocamlopt" -version)" = "$(ocamlopt -version)"
printf '%s\n' "$XEN_OCAML_AARCH64_PREFIX"
```

`architecture: arm64` describes the emitted code. The cross compiler executable
itself still runs on the x86_64 host.

## Build the AArch64 Xen compiler

Return to the Xen repository root. Create `.package-toolchains.json` using the
absolute prefix printed above:

```json
{
  "aarch64": {
    "prefix": "/absolute/path/to/ocaml-aarch64-5.5.0",
    "runner": ["qemu-aarch64", "-L", "/usr/aarch64-linux-gnu"]
  }
}
```

JSON does not expand `$HOME`, environment variables or `~`. The QEMU library
prefix shown here uses libc installed by `libc6-arm64-cross`; use the matching
sysroot if the target libraries came from another toolchain.

```sh
make package-build
aarch64-linux-gnu-readelf -h _build/package_aarch64/compiler/main.exe
qemu-aarch64 -L /usr/aarch64-linux-gnu _build/package_aarch64/compiler/main.exe version
make package
```

The ELF header must identify AArch64 (machine number 183). Both Make commands
request x86_64 and AArch64 by default. `PACKAGE_ARCHS=aarch64` explicitly selects
only AArch64. The cross result is `_build/package_aarch64/compiler/main.exe`;
package builds do not promote over `compiler/dist/xen`.

Verify source loading and generated program execution:

```sh
qemu-aarch64 -L /usr/aarch64-linux-gnu _build/package_aarch64/compiler/main.exe \
  check examples/arm64_core.xen
qemu-aarch64 -L /usr/aarch64-linux-gnu _build/package_aarch64/compiler/main.exe \
  build examples/arm64_core.xen --jit=off -o app
qemu-aarch64 ./app
```

The compiler executable needs its target libc; the generated Xen program is static
and does not need QEMU's `-L` option. A QEMU-user compiler process does not install
a binary handler for `run` or `test` child processes. Those commands require a
native AArch64 host or a configured kernel handler.

After `make package`, verify the extracted and relocated compiler with the host suite:

```sh
XEN_BIN="$PWD/_build/package_aarch64/compiler/main.exe" \
  XEN_HOST_ARCHIVE="$PWD/dist/xen-$(cat VERSION)-linux-aarch64.tar.gz" \
  XEN_HOST_RUNNER='["/usr/bin/qemu-aarch64","-L","/usr/aarch64-linux-gnu"]' \
  python3 tests/integration/host_test.py
```

Native `run`/`test` checks are skipped when this suite uses a cross compiler through
QEMU; generated AArch64 programs are executed separately. See the
[host test contract](../../../tests/README.md).

## Optional explicit Dune workspace

[`scripts/dune-workspace.arm64`](../../../scripts/dune-workspace.arm64) provides
an `arm64` context with `host default`. Replace both `/opt/ocaml-aarch64` paths
with the installed cross prefix and verify its configuration before building:

```sh
dune build --workspace=scripts/dune-workspace.arm64 _build/arm64/compiler/main.exe
aarch64-linux-gnu-readelf -h _build/arm64/compiler/main.exe
qemu-aarch64 -L /usr/aarch64-linux-gnu _build/arm64/compiler/main.exe version
```

This context uses `_build/arm64/`, unlike the automatic package context's
`_build/package_aarch64/`. A missing workspace prefix can otherwise fall back to
native OCaml through `PATH`. `make package-build` validates prefixes first.
See [Dune context documentation](https://dune.readthedocs.io/en/stable/reference/dune-workspace/context.html)
and [packaging](packaging.md) for single-context archives and configuration options.
