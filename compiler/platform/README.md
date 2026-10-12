# Platform boundary

Reserve this directory for operating-system services, executable formats and
platform ABI support. CPU instruction encoders live in `../cpu/`.

For now each CPU's `Linux_backend` composes its instruction encoder with its Linux
runtime and ELF writer. These implementations are explicitly Linux-specific.
They can move here when a shared platform contract is useful; the x86 writer's
relocations must not become a dependency of another CPU backend.

## Target services

`Project_loader` resolves `use std.platform;` exclusively from
`stdlib/platform/<architecture>-<os>/std/platform.xen`, using the normalized **code
generation target**, independently of the compiler host and stdlib root discovery.
There is no project/common-module fallback. `check`, `build`, `run`, toolchain test
discovery and directory test discovery all pass the same target. Discovered tests
retain it; execution with a different backend is rejected before generation.
Library callers can explicitly pass `~target` to `Project_loader.load/load_toolchain`;
the legacy library default remains x86_64-linux.

The public `std.io`, `std.fs`, `std.env`, and `std.process` implementations are common.
The internal `std.platform` contract supplies read/write/open/close/directory
services returning nonnegative success or negative native errno, interruption
recognition, native open flags/mode, normalized metadata, decoded directory names
and an owned cwd String without a terminator. It has no dependency on `std.io`,
avoiding an import cycle. Numeric errno payloads remain platform-native.
`std.platform_linux` shares Linux record/cwd helpers; other OS implementations
must provide their own decoding and normalize syscall return conventions.

Linux x86-64 and AArch64 profiles are shipped together in every archive so either
compiler can cross-build either target after relocation. AArch64 uses openat and
newfstatat, 128-byte stat with mode at byte 16, and O_DIRECTORY=16384. x86-64 uses
open/stat, 144-byte stat with mode at byte 24, and O_DIRECTORY=65536. Sources were
checked against the Linux [stat UAPI](https://github.com/torvalds/linux/blob/master/include/uapi/asm-generic/stat.h)
and [ARM64 flags](https://github.com/torvalds/linux/blob/master/arch/arm64/include/uapi/asm/fcntl.h).
`std.fs.open_path` takes target-native flags/mode and `decode_directory` takes
target-native records; these compatibility helpers are not portable data formats.
User `syscall0` through `syscall6` retain raw numbers and arguments without translation.
ARM64 implements `Ptr<T>` and checked raw POD memory operations to support these
services; the pointer descriptor is non-owning and must be freed explicitly.

## macOS extension

`Target` recognizes x86_64-macos and aarch64-macos, including arm64/darwin aliases.
OCaml amd64/macosx and arm64/macosx host configurations resolve to those targets.
Neither has a registered backend yet: the CLI diagnoses them as unimplemented
before loading source or writing output, while `version` works independently.
The CLI never automatically chooses a Linux backend on macOS. Legacy library
callers of `Backend.default` retain the explicit `Target.default` fallback on
unimplemented/unknown hosts, independently of backend registration order; callers
needing host validation use `Backend.default_target` and `Backend.select`.

For each CPU, register a macOS backend that reuses only suitable instruction
encoders and supplies Darwin startup/calling conventions, memory/file services,
Mach-O construction/relocations and executable permissions. Add its matching
stdlib profile implementing the same service interface. Do not reuse Linux syscall
numbers, stat/getdents layouts, ELF loading or JIT permission policy. The current
internal Xen value layout remains 64-bit; it is distinct from any C/platform ABI.
macOS binary packages require explicit Mach-O architecture validation and a macOS
platform branch in the packager; the current ELF/Linux-only packager rejects them.
Validate both Intel and Apple Silicon hosts and relocated cross-target packages
before declaring macOS execution supported.
