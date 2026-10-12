# Darwin/Mach-O prototype validation

macOS on Intel and Apple Silicon is unsupported and has no planned support.
No macOS compiler executable, binary package or standard library profile is
provided. The CLI recognizes macOS target names and aliases but rejects them
before source loading or output creation.

## Retained components

| Component | Location | Scope |
| --- | --- | --- |
| CPU instruction encoders | `compiler/cpu/x86_64/`, `compiler/cpu/arm64/` | Instruction encoding and relocation |
| Mach-O writer and SHA-256 signer | `compiler/platform/darwin/` | Internal executable construction for x86_64 and AArch64 |
| Darwin ARM64 runtime and backend | `compiler/platform/darwin/arm64/` | Internal prototype; not registered in the CLI |

CPU libraries remain independent of operating-system implementations. The
Darwin prototype composes the ARM64 encoder with Darwin-specific services and
the shared Mach-O writer.

## Structural tests

Run the retained implementation checks with:

```sh
python3 scripts/test.py --suite macos-prototype
```

The checks cover:

- x86_64 and AArch64 Mach-O headers, segments, permissions, entry and load commands.
- SHA-256 known answers and independent CodeDirectory page hashes.
- ARM64 PIE address relocations and executable generation from checked Xen IR.
- Darwin syscall adapter carry/errno normalization, register preservation, stack
  balance and leaf return behavior, using simulated kernel returns under Linux QEMU.

These checks do not establish macOS execution support. dyld loading, kernel
services, platform code-signing acceptance and native compiler execution are
outside the validation scope.
