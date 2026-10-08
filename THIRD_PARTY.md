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
distribution. The demo compiler dynamically uses the host system's glibc
and libm; those system libraries are not copied into the archive.
The verified executable references symbols up to `GLIBC_2.38`.
When changing the compiler's linked dependencies or OCaml
distribution, check their notices and update the bundled license texts
before creating a release archive.
