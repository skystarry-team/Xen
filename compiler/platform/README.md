# Platform boundary

Reserve this directory for operating-system services, executable formats and
platform ABI support. CPU instruction encoders live in `../cpu/`.

OS implementations live under `linux/` and `darwin/`; CPU-specific implementations
sit below each OS. Both `linux/x86_64/` and `linux/arm64/` own the Linux runtime,
ELF writer and a thin composition of their CPU's `Native_backend.Make(Linux_runtime)`.
CPU libraries have
no OS-library dependencies or Linux default instances. Shared heap/file routines
require explicit inline allocation/unmap/open/read/write/close hooks.

Both CPU lowerings use `Native_backend.Make(Runtime)`:
platform entry, termination, output, file flags, raw syscall emission and executable
construction are explicit hooks. Formatting, numeric parsing and ownership logic
can reuse normalized services. x86-64's inline service register/clobber/stack
contract is in `cpu/x86_64/runtime_intf.ml`. Float formatting, file read builtins
and token parsing are CPU algorithms with symbolic labels and relocations;
the platform supplies their allocation/I/O services.
ARM64's inline syscall hooks preserve leaf helpers' LR;
the x86 writer's relocations never become another CPU backend's dependency.

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

## macOS: unsupported

macOS on Intel and Apple Silicon is unsupported and has no planned support.
No macOS compiler build, binary package or standard library profile is provided.
CPU architecture support, Mach-O/signing code and internal Darwin prototypes are
retained for implementation testing; structural tests do not enable OS support.

`Target` recognizes x86_64-macos and aarch64-macos, including arm64/darwin aliases.
OCaml amd64/macosx and arm64/macosx host configurations resolve to those targets.
Neither has a registered backend: the CLI diagnoses them as unsupported
before loading source or writing output, while `version` works independently.
The CLI never automatically chooses a Linux backend on macOS. Legacy library
callers of `Backend.default` retain the explicit `Target.default` fallback on
unsupported/unknown hosts, independently of backend registration order; callers
needing host validation use `Backend.default_target` and `Backend.select`.

The internal `darwin/arm64/Darwin_backend` prototype composes the existing instruction
encoder with `Darwin_runtime` and `darwin/`'s CPU-independent `Mach_o` writer.
It emits LC_MAIN/PIE/dyld/libSystem images with a direct ad-hoc SHA-256 signature.
The writer accepts AArch64 or x86_64 code; an Intel Darwin code generator is absent.
ARM64 address fixups use ADRP+ADD with checked architectural 4KiB page
deltas and preserve their instruction bytes under a common aligned ASLR slide.
BSD services use x16 and svc #0x80; carry/positive errno becomes negative errno,
and x1..x5 are preserved around the trap. Memory/file services have Darwin-specific
numbers, flags and open arguments; raw BSD numbers are not translated from Linux.
No Darwin stdlib profile, public FFI or macOS compiler package is supplied.

`python3 scripts/test.py --suite macos-prototype` checks both CPU headers, segments/permissions, entry
and load commands, SHA-256 known answers, independent CodeDirectory page hashes,
PIE relocation and generation from checked Xen IR. `tests/darwin_fixture.exe`
can emit an internal ARM64 prototype image. These are structural
and encoding checks, not proof of dyld acceptance or successful Darwin execution.
The CLI stays unregistered under the unsupported policy. The ELF/Linux-only
packager rejects macOS packages. See the
[prototype validation scope](darwin/MACOS_VALIDATION.md).
