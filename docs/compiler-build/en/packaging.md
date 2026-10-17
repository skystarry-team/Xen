# Compiler distributions

`make package` builds and packages **both Linux x86_64 and AArch64 compilers**.
Its default format is tar.gz. The output names are:

```text
dist/xen-<version>-linux-x86_64.tar.gz
dist/xen-<version>-linux-aarch64.tar.gz
```

`make package-deb` creates `xen-lang_<debian-version>_amd64.deb` and
`xen-lang_<debian-version>_arm64.deb`. `make release-package` creates both formats
in one staged operation. `PACKAGE_FORMATS="tar.gz deb"` also selects both formats
on `make package` or `make package-one`. Existing Make selectors remain available.

| Command | Formats | Default compiler CPUs |
| --- | --- | --- |
| `make package` | tar.gz | x86_64 and aarch64 |
| `make package-deb` | .deb | x86_64 and aarch64 |
| `make release-package` | tar.gz and .deb | x86_64 and aarch64 |
| `make source-package` | source tar.gz | No compiler build |

For installation of downloaded artifacts, see [installing Xen](installation.md).

Distribution code is organized under [`packaging/`](../../../packaging/README.md):
`archive/`, `debian/`, `windows/`, `toolchains/` and `github/`, with shared validation and build
orchestration at the top level. `scripts/` contains the general test runner.

Binary archives contain `bin/xen`, the runtime standard library, learning examples,
license notices, `VERSION` and a distribution README. The `.xen` files in `stdlib/`
are required by the compiler's module loader. All four platform profiles are
included so each compiler can emit Linux x86_64/AArch64, Windows x86_64 and Apple Silicon macOS programs.
Compiler source, build documentation and development scripts belong to the
separate source archive. Intel macOS is unsupported.

## Windows portable ZIP (experimental)

On a native Windows x64 OCaml switch, run from the repository root in PowerShell:

```powershell
opam exec -- dune build '@release'
opam exec -- python -m packaging.cli --platform windows --architecture x86_64 --formats zip
$version = (Get-Content VERSION -Raw).Trim()
python -m packaging.windows.smoke "dist/xen-$version-windows-x86_64.zip" --version $version
```

This produces `dist/xen-<version>-windows-x86_64.zip` with `bin/xen.exe`, all
standard library profiles, examples and license notices. No Make is required.
The script checks AMD64 PE32+, the embedded version and the reviewed system DLL
import list. Extra runtime DLLs and delay imports fail packaging. A completed
temporary ZIP replaces the output only after successful creation.

The smoke test extracts and moves the actual ZIP to a path containing spaces and
Unicode, then executes version/check/build/run/test outside the repository with
only the installed `bin` and Windows System32 on PATH. It checks generated PE
execution, stdlib file I/O and both Linux cross targets, plus failure without the
bundled stdlib. This is an isolated PATH test on CI, not a clean Windows install.
Compiler, loader and standard library checks have passed Windows Server 2022 native
CI; the new ZIP check must also pass before release. Windows desktop validation
on physical hardware is still required. Windows ARM64 is unsupported.

## Apple Silicon tar.gz (experimental)

On a native macOS arm64 OCaml switch, run `python3 scripts/test.py --suite macos`.
It creates `dist/xen-<version>-macos-aarch64.tar.gz` and checks its relocated
compiler, generated programs and standard library under a restricted PATH.
The macOS 15 native CI gate passes; Intel macOS is unsupported.

## Cross toolchain configuration

Native OCaml and Dune must be on `PATH`. The other architecture requires an OCaml
cross compiler of exactly the same version, target C tools and libraries, and
an execution path for version validation. Follow the [AArch64 source build guide](aarch64.md)
to prepare the cross compiler on x86_64.

Configure cross prefixes and runners in `.package-toolchains.json` at the
repository root. This machine-local file is excluded from Git and source archives.
[`packaging/toolchains/example.json`](../../../packaging/toolchains/example.json)
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
make package VERSION=v0.1.0-demo.4
make package-build
make package PACKAGE_ARCHS=x86_64
make package PACKAGE_ARCHS=aarch64
```

`package-build` builds both compilers without packaging. `PACKAGE_ARCHS` explicitly
selects a subset; `arm64` aliases `aarch64`. Each bundled compiler must match the
requested ELF architecture and report the requested version. All requested
artifacts are completed before existing release artifacts are replaced.

For one selected context or an existing binary:

```sh
make package-one
make package-one DUNE_WORKSPACE=packaging/toolchains/dune-workspace.arm64 \
  PACKAGE_CONTEXT=arm64 PACKAGE_ARCH=aarch64 \
  PACKAGE_RUNNER='["qemu-aarch64","-L","/usr/aarch64-linux-gnu"]'
make package-one PACKAGE_BINARY=/path/to/xen
```

Adjust the workspace's two prefix paths before using the explicit context.
`PACKAGE_BINARY` skips Dune. For compatibility, nonempty `PACKAGE_BINARY`,
`PACKAGE_CONTEXT`, `DUNE_WORKSPACE` or `PACKAGE_ARCH` also select single mode
when passed to `make package`. `PACKAGE_NAME` and `PACKAGE` customize the name
or output file in single mode with one format selected. Debian `PACKAGE_NAME`
changes only the output filename; its installed package name remains `xen-lang`.
`DIST_DIR` selects the artifact directory in either mode.

## Debian packages

Install build tools with `sudo apt install dpkg-dev`. Native packaging is the
simplest route; select `PACKAGE_ARCHS=x86_64` or `PACKAGE_ARCHS=aarch64` on each
native builder. Cross packaging also requires target libraries and their Debian
package metadata, in addition to OCaml and the version-check runner. For example,
on an amd64 Debian/Ubuntu builder, install the foreign runtime using
`sudo dpkg --add-architecture arm64`, `sudo apt update` and
`sudo apt install libc6:arm64` (configure matching arm64 apt sources first where
required). `dpkg-shlibdeps` must resolve every linked target library; missing
metadata fails the package rather than guessing dependencies.

The package is named `xen-lang` and installs `/usr/bin/xen`, runtime modules under
`/usr/lib/xen`, and examples/notices under `/usr/share/doc/xen-lang`. Both target
profiles are bundled. No environment variables or maintainer scripts are needed.
All package files belong to root, including when built by an ordinary user.
Minimal OS images may exclude documentation using their dpkg configuration.

The following amd64 example assumes `dist/` contains one matching package.
Use `_arm64.deb` on arm64. See [installation](installation.md) for CPU selection
and checksum verification.

```sh
sudo apt install ./dist/xen-lang_*_amd64.deb
xen version
xen run hello.xen
sudo apt remove xen-lang
```

Debian versions must start with a digit. `_` and `-` suffix separators become
`~`, and packaging revision `-1` is appended: `v0.1.0-demo.4` becomes
`0.1.0~demo.4-1`, which sorts before `0.1.0-1`. Legacy `0.1.0_1-demo`
versions map to `0.1.0~1~demo-1`. The compiler's version and bundled
`VERSION` retain the original text. Dependency versions are calculated from the
actual ELF with `dpkg-shlibdeps`; rebuilding on a newer OS can raise the minimum
required glibc version. See [Debian's version rules](https://www.debian.org/doc/debian-policy/ch-controlfields.html#version)
and [dpkg-shlibdeps](https://manpages.debian.org/stable/dpkg-dev/dpkg-shlibdeps.1.en.html).

## GitHub releases

[The release workflow](../../../.github/workflows/release.yml) builds natively on
Ubuntu 22.04 for amd64 and arm64, Windows Server 2022 for x86_64, and macOS 15 for arm64, using OCaml 5.5.0 and Dune 3.24.2. This builds
both the OCaml runtime and Xen against the older system libraries. Linux packages must
pass installation, stdlib discovery, check/build/run/test and removal in clean
**Debian 12/13 and Ubuntu 22.04/24.04/26.04** containers on each CPU. ARM hardware
validation of other compiler features remains subject to the project's existing
experimental-support scope. Other derivatives are not separately certified.

1. Set `VERSION`, commit the release changes, and push the matching `v<VERSION>` tag.
2. Both Linux jobs build tar.gz and .deb assets and run installation checks. The Windows and macOS jobs build, relocate and execute their packages.
3. Assembly requires both Linux binary archives, both .deb files, the Windows ZIP, the macOS tar.gz and one source
   archive, then generates `SHA256SUMS`.
4. Only a tag push publishes a GitHub release. It creates a draft, uploads all eight
   assets, then publishes it. Versions with `_` or `-` suffixes, or alpha/beta/rc
   markers, are marked as prereleases. A failed upload leaves a draft for inspection;
   delete that draft before rerunning the publish job. Published releases are not overwritten.

`workflow_dispatch` and packaging pull requests build and validate artifacts
without publishing. Download the `release-assets` Actions artifact for review.
Local validation uses `python3 scripts/test.py --suite packaging`. Build a complete
local asset set in an empty output directory (both compiler toolchains and target
Debian metadata must be configured):

```sh
make release-package DIST_DIR=dist/release
make source-package DIST_DIR=dist/release
# Copy xen-<version>-windows-x86_64.zip from the native Windows build into dist/release.
# Copy xen-<version>-macos-aarch64.tar.gz from the native macOS build into dist/release.
python3 -m packaging.github.release --directory dist/release
(cd dist/release && sha256sum --check SHA256SUMS)
```

`release-package` itself creates four Linux binary packages. The Windows ZIP, macOS tar.gz, source archive and
checksum manifest are separate steps; the GitHub workflow performs all of them.
After committing the release changes, publish the matching tag:

```sh
XEN_RELEASE_TAG="v$(cat VERSION)"
git tag "$XEN_RELEASE_TAG"
git push origin "$XEN_RELEASE_TAG"
```

To validate an assembled local directory, run
`python3 -m packaging.github.release --directory /path/to/assets --tag v<VERSION>`.
The asset directory must contain only the seven release packages (and optionally
an existing `SHA256SUMS`); stale files are rejected.

## Source distribution

```sh
make source-package VERSION=v0.1.0-demo.4
```

This exports `xen-<version>-source.tar.gz` with compiler and standard library
sources, build files, `packaging/`, release workflows, scripts, tests, documentation,
examples and license notices.
It does not build compilers or include Git history, machine-local toolchains or
generated build outputs. Compiler build guides are included in this archive.
