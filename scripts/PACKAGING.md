# Compiler packaging

`make package` builds and packages **both Linux x86_64 and AArch64 compilers**.
The output names are:

```text
dist/xen-<version>-linux-x86_64.tar.gz
dist/xen-<version>-linux-aarch64.tar.gz
```

Each archive contains the corresponding executable compiler, both Linux standard
library profiles, examples, documentation and license notices. The compiler host
architecture is distinct from the Xen program's output target. macOS is unsupported.

## Toolchains

The native Linux OCaml installation and Dune must be on `PATH`. The other
architecture requires an OCaml native cross compiler of the same version, its
target C toolchain and libraries, and a way to execute the resulting compiler
for version validation. QEMU user-mode can provide that execution path.

Configure cross prefixes and runners in `.package-toolchains.json` at the
repository root. This machine-local file is excluded from source archives and
Git. Use `scripts/package-toolchains.example.json` as the configuration reference:

```json
{
  "aarch64": {
    "prefix": "/opt/ocaml-aarch64",
    "runner": ["qemu-aarch64", "-L", "/path/to/aarch64-sysroot"]
  }
}
```

On an AArch64 host, configure the `x86_64` entry instead. Prefixes must be absolute
and contain executable `bin/ocamlc` and `bin/ocamlopt`. Only the non-native
architecture uses its configured prefix and runner. An empty runner uses direct
execution, requiring an appropriate kernel binary handler for a cross executable.
Without configuration, cross prefixes default to `/opt/ocaml-aarch64` and
`/opt/ocaml-x86_64`, with direct execution. Select another configuration file with
`PACKAGE_TOOLCHAINS=/path/to/toolchains.json`.

The build validates both compilers' OCaml version, system and architecture before
invoking Dune. Missing or mismatched toolchains fail the requested build; targets
are never silently omitted. Dune uses a native `default` context and a
`package_<architecture>` cross context with `host default` for build-time tools.
The package build requests `compiler/main.exe` directly and does not promote over
`compiler/dist/xen`.

## Commands

```sh
make package
make package VERSION=0.1.0
make package-build
make package PACKAGE_ARCHS=x86_64
make package PACKAGE_ARCHS=aarch64
```

`package-build` builds the same two compiler architectures without archiving.
`PACKAGE_ARCHS` explicitly selects a subset; `arm64` is accepted as an alias for
`aarch64`. Each packaged compiler must have the requested ELF architecture and
report the requested version. All requested archives are completed in a temporary
directory before existing release archives are replaced.

## Single compiler packaging

Use `make package-one` for a selected Dune context or an existing executable:

```sh
make package-one
make package-one DUNE_WORKSPACE=scripts/dune-workspace.arm64 \
  PACKAGE_CONTEXT=arm64 PACKAGE_ARCH=aarch64 \
  PACKAGE_RUNNER='["qemu-aarch64","-L","/path/to/aarch64-sysroot"]'
make package-one PACKAGE_BINARY=/path/to/xen
```

An explicit `PACKAGE_BINARY` skips Dune. For compatibility, `make package` with
a nonempty `PACKAGE_BINARY`, `PACKAGE_CONTEXT`, `DUNE_WORKSPACE` or `PACKAGE_ARCH`
also selects the single-compiler path. `PACKAGE_NAME` and `PACKAGE` select a custom
name or output file only through this path. `DIST_DIR` selects the output directory
for either mode. `make source-package` exports source without building compilers.
