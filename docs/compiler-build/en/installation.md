# Installing Xen

Download a matching compiler package and `SHA256SUMS` from
[GitHub Releases](https://github.com/skystarry-team/Xen/releases).
Use a new download directory for each release and select one compiler host CPU.
The host CPU identifies the machine that runs Xen; either compiler can generate
both supported Linux targets. AArch64 remains experimental as described in the
[project support scope](../../../README.md).

| Host CPU | Debian architecture | Debian package | Binary archive |
| --- | --- | --- | --- |
| x86-64 | `amd64` | `xen-lang_<debian-version>_amd64.deb` | `xen-<version>-linux-x86_64.tar.gz` |
| AArch64 | `arm64` | `xen-lang_<debian-version>_arm64.deb` | `xen-<version>-linux-aarch64.tar.gz` |

## Debian and Ubuntu

Release CI checks Debian 12/13 and Ubuntu 22.04/24.04/26.04 on both architectures
before publishing. Derivatives are not individually tested. Check your package
architecture with `dpkg --print-architecture`, then download its `.deb` and the
checksum manifest from the same release.

From that download directory, verify the downloaded package. Other assets listed
in the manifest can remain undownloaded:

```sh
sha256sum --check --ignore-missing SHA256SUMS
```

For amd64:

```sh
sudo apt install ./xen-lang_*_amd64.deb
```

For arm64, use `sudo apt install ./xen-lang_*_arm64.deb` instead. The download
directory should contain only the selected release's package for that CPU.
Use apt so the compiler's system library dependencies are checked and installed.
OCaml, Dune and Python are not needed to use the installed compiler.

```sh
xen version
xen run /usr/share/doc/xen-lang/examples/demo.xen
xen test std.fs --filter null
```

The package is named `xen-lang`; its command is `xen`. The executable is
`/usr/bin/xen`, the required runtime modules are under `/usr/lib/xen`, and examples
and notices are under `/usr/share/doc/xen-lang`. No `XEN_STDLIB_ROOT` setting is
needed. Minimal OS images may exclude documentation; in that case use your own
source file instead of the bundled example.

Install a newer downloaded `.deb` with the same apt command to upgrade. Remove
the compiler and its bundled modules with:

```sh
sudo apt remove xen-lang
```

The Debian package version converts suffix separators and adds a packaging
revision. For example, `0.1.0-demo.3` becomes `0.1.0~demo.3-1`; `xen version`
still reports `0.1.0-demo.3`. See [version and dependency handling](packaging.md#debian-packages)
when building your own package, since its minimum system-library versions depend
on the build environment.

## Binary tar.gz

An archive can be unpacked into a user-owned directory. Download the binary
archive matching your host CPU and `SHA256SUMS`, then verify it with the checksum
command above. The source archive is intended for building the compiler yourself.

For x86-64, with one matching binary archive in the download directory:

```sh
tar -xzf xen-*-linux-x86_64.tar.gz
cd xen-*-linux-x86_64
./bin/xen version
./bin/xen run examples/demo.xen
export PATH="$PWD/bin:$PATH"
```

On AArch64, replace `x86_64` with `aarch64` in the archive and directory names.
The PATH change applies to the current shell; add the installed `bin` directory
to your shell configuration for later sessions. Keep `bin/` and `stdlib/`
together when moving the distribution. The compiler needs compatible system
libraries; generated Xen programs are static Linux executables.

For a source build, continue with [building Xen](build.md). Maintainers can
generate both package formats using the [packaging and release guide](packaging.md).
