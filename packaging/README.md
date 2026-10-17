# Distribution tooling

Run commands from the repository root. Python 3.10+, OCaml and Dune are required;
Debian packages additionally require `dpkg-dev` and the target's library metadata.

| Directory | Responsibility |
| --- | --- |
| `archive/` | Binary and source tar.gz payloads |
| `debian/` | Debian metadata, filesystem layout and installation checks |
| `windows/` | PE dependency validation, portable ZIP and relocated execution checks |
| `toolchains/` | Cross compiler configuration examples and Dune workspace |
| `github/` | Complete release asset validation and SHA-256 manifest |

`common.py` shares compiler-version and payload checks, with ELF, Mach-O and Windows PE validation. `build.py` orchestrates
native/cross builds; `cli.py` packages an existing executable or exports source.
All requested formats and CPUs finish before replacing existing artifacts.

```sh
make package                       # both CPUs, tar.gz
make package-deb                   # both CPUs, .deb
make release-package               # both CPUs, tar.gz and .deb
make release-package PACKAGE_ARCHS=x86_64  # one native build, for CI
make package-one PACKAGE_FORMATS=deb PACKAGE_BINARY=/path/to/xen
make source-package
python3 -m packaging.github.release # verify seven packages and write SHA256SUMS
```

On a native Windows x86_64 OCaml switch, without Make (PowerShell):

```powershell
opam exec -- dune build '@release'
opam exec -- python -m packaging.cli --platform windows --architecture x86_64 --formats zip
$version = (Get-Content VERSION -Raw).Trim()
python -m packaging.windows.smoke "dist/xen-$version-windows-x86_64.zip" --version $version
```

The ZIP bundles `bin/xen.exe`, all stdlib profiles, examples and license notices.
Its compiler must report the requested version and import only the reviewed
Windows system DLLs in `windows/pe.py`; delay imports are rejected. Unknown DLLs
require resolving their link/bundling requirements before packaging.
The smoke test relocates the actual ZIP and exercises check/build/run/test with
only its `bin` and Windows System32 on PATH, without stdlib overrides. It also
checks missing-bundle failure and Linux cross output. This is not a clean OS
installation or physical hardware test. Windows x86_64 remains experimental;
Windows desktop validation on physical hardware is required.

On native Apple Silicon macOS, `python3 scripts/test.py --suite macos` builds the
compiler, runs generated Mach-O programs, creates the `macos-aarch64` tar.gz and
checks its relocated execution. Native CI validation is pending.

Keep the existing Make interface when adding formats. Put format-specific logic
and templates in their own directory. See the [English guide](../docs/compiler-build/en/packaging.md)
or [한국어 안내](../docs/compiler-build/ko/packaging.md) for dependencies, version
mapping, supported platforms and the release workflow.
