# Distribution tooling

Run commands from the repository root. Python 3.10+, OCaml and Dune are required;
Debian packages additionally require `dpkg-dev` and the target's library metadata.

| Directory | Responsibility |
| --- | --- |
| `archive/` | Binary and source tar.gz payloads |
| `debian/` | Debian metadata, filesystem layout and installation checks |
| `toolchains/` | Cross compiler configuration examples and Dune workspace |
| `github/` | Complete release asset validation and SHA-256 manifest |

`common.py` shares ELF, compiler-version and payload checks. `build.py` orchestrates
native/cross builds; `cli.py` packages an existing executable or exports source.
All requested formats and CPUs finish before replacing existing artifacts.

```sh
make package                       # both CPUs, tar.gz
make package-deb                   # both CPUs, .deb
make release-package               # both CPUs, tar.gz and .deb
make release-package PACKAGE_ARCHS=x86_64  # one native build, for CI
make package-one PACKAGE_FORMATS=deb PACKAGE_BINARY=/path/to/xen
make source-package
python3 -m packaging.github.release # verify five packages and write SHA256SUMS
```

Keep the existing Make interface when adding formats. Put format-specific logic
and templates in their own directory. See the [English guide](../docs/compiler-build/en/packaging.md)
or [한국어 안내](../docs/compiler-build/ko/packaging.md) for dependencies, version
mapping, supported platforms and the release workflow.
