# Third-party notices

The Xen compiler is implemented in OCaml and links the OCaml runtime,
standard library and Unix library. The demo build was verified with OCaml
5.5.0. Their original license is preserved in [licenses/OCaml.txt](licenses/OCaml.txt):
LGPL-2.1 with the OCaml linking exception. This material retains its original
copyright notices and is excluded from Xen's own license grants.

Upstream source: [ocaml/ocaml](https://github.com/ocaml/ocaml).
The exception permits distribution of a linked executable under terms of
the distributor's choice, subject to the conditions in the original text.

Generated Xen user programs use Xen's native runtime rather than the OCaml
runtime. The generated-runtime license is described in [LICENSE](LICENSE).

Dune and Python are build/test tools; they are not bundled in the binary
distribution. The Linux compiler dynamically uses the host system's glibc
and libm; those system libraries are not copied into the archive.
The minimum glibc version depends on the build environment. Release CI builds
OCaml and Xen on Ubuntu 22.04, then checks installation on the Debian/Ubuntu
versions listed in the [packaging guide](https://github.com/skystarry-team/Xen/blob/main/docs/compiler-build/en/packaging.md).
Debian packages record the actual ELF-derived library requirements in `Depends`;
inspect them with `dpkg-deb -f <package.deb> Depends`. Locally built archives may
require newer system libraries than the release artifacts.
The Windows x86_64 compiler uses native OCaml built with MinGW and Windows system
DLLs. Cygwin, MinGW, OCaml and Dune installations are not required to run the ZIP.
The package gate rejects additional runtime DLL dependencies rather than copying
them from the build machine. Generated Windows programs use Xen's runtime and
Windows system DLLs.
When changing the compiler's linked dependencies or OCaml
distribution, check their notices and update the bundled license texts
before creating a release archive.
