# Platform boundary

Reserve this directory for operating-system services, executable formats and
platform ABI support. CPU instruction encoders live in `../cpu/`.

For now each CPU's `Linux_backend` composes its instruction encoder with its Linux
runtime and ELF writer. These implementations are explicitly Linux-specific.
They can move here when a shared platform contract is useful; the x86 writer's
relocations must not become a dependency of another CPU backend.

The bundled stdlib still contains Linux x86-64 syscalls and kernel record layouts.
The ARM64 backend provides heap String, Box and Vec allocation/cleanup with
borrowed Slice views, plus managed File operations and read_text using an explicit
Linux AArch64 file runtime. It still rejects raw syscalls and Ptr operations in
platform-dependent stdlib functions; numeric file token parsing is a later stage.
Future stdlib support must select or lower
platform services explicitly, while leaving user-supplied raw syscall numbers raw.
