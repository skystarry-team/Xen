# Compiler distributions

`make package` builds and packages **both Linux x86_64 and AArch64 compilers**.
The output names are:

```text
dist/xen-<version>-linux-x86_64.tar.gz
dist/xen-<version>-linux-aarch64.tar.gz
```

Binary archives contain `bin/xen`, the runtime standard library, learning examples,
license notices, `VERSION` and a distribution README. The `.xen` files in `stdlib/`
are required by the compiler's module loader. Both Linux platform profiles are
included so either compiler can emit either supported target.
Compiler source, build documentation and development scripts belong to the
separate source archive. macOS is unsupported.

## Cross toolchain configuration

Native OCaml and Dune must be on `PATH`. The other architecture requires an OCaml
cross compiler of exactly the same version, target C tools and libraries, and
an execution path for version validation. Follow the [AArch64 source build guide](aarch64.md)
to prepare the cross compiler on x86_64.

Configure cross prefixes and runners in `.package-toolchains.json` at the
repository root. This machine-local file is excluded from Git and source archives.
[`scripts/package-toolchains.example.json`](../../../scripts/package-toolchains.example.json)
describes both architecture entries:

```json
{
  "aarch64": {
    "prefix": "/absolute/path/to/ocaml-aarch64",
    "runner": ["qemu-aarch64", "-L", "/usr/aarch64-linux-gnu"]
  }
}
```

On an AArch64 host, configure the `x86_64` entry instead. Prefixes must be absolute
and contain executable `bin/ocamlc` and `bin/ocamlopt`. Only the non-native
architecture uses its configured prefix and runner. An empty runner uses direct
execution and requires a compatible host or kernel binary handler.
Without configuration, cross prefixes default to `/opt/ocaml-aarch64` and
`/opt/ocaml-x86_64`, with direct execution. Select another file with
`PACKAGE_TOOLCHAINS=/path/to/toolchains.json`.

The build checks OCaml versions, system and architecture before invoking Dune.
Missing or mismatched toolchains fail; requested architectures are never omitted.
Dune uses native `default` and cross `package_<architecture>` contexts, with
`host default` for build-time tools. It requests `compiler/main.exe` directly
without promoting over `compiler/dist/xen`.

## Binary distribution commands

```sh
make package
make package VERSION=0.1.0
make package-build
make package PACKAGE_ARCHS=x86_64
make package PACKAGE_ARCHS=aarch64
```

`package-build` builds both compilers without archiving. `PACKAGE_ARCHS` explicitly
selects a subset; `arm64` aliases `aarch64`. Each bundled compiler must match the
requested ELF architecture and report the requested version. All requested
archives are completed before existing release archives are replaced.

For one selected context or an existing binary:

```sh
make package-one
make package-one DUNE_WORKSPACE=scripts/dune-workspace.arm64 \
  PACKAGE_CONTEXT=arm64 PACKAGE_ARCH=aarch64 \
  PACKAGE_RUNNER='["qemu-aarch64","-L","/usr/aarch64-linux-gnu"]'
make package-one PACKAGE_BINARY=/path/to/xen
```

Adjust the workspace's two prefix paths before using the explicit context.
`PACKAGE_BINARY` skips Dune. For compatibility, nonempty `PACKAGE_BINARY`,
`PACKAGE_CONTEXT`, `DUNE_WORKSPACE` or `PACKAGE_ARCH` also select single mode
when passed to `make package`. `PACKAGE_NAME` and `PACKAGE` customize the name
or output file in single mode. `DIST_DIR` selects the archive directory in either mode.

## Source distribution

```sh
make source-package VERSION=0.1.0
```

This exports `xen-<version>-source.tar.gz` with compiler and standard library
sources, build files, scripts, tests, documentation, examples and license notices.
It does not build compilers or include Git history, machine-local toolchains or
generated build outputs. Compiler build guides are included in this archive.
