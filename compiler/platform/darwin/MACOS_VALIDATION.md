# Darwin/Mach-O validation

Apple Silicon `aarch64-macos` is an experimental target with a registered CLI
backend, Darwin standard library profile and tar.gz package. Native macOS CI
must pass before claiming verified execution or publishing a release. Intel
`x86_64-macos` remains unsupported because it has no Darwin code generator.

## Retained components

| Component | Location | Scope |
| --- | --- | --- |
| CPU instruction encoders | `compiler/cpu/x86_64/`, `compiler/cpu/arm64/` | Instruction encoding and relocation |
| Mach-O writer and SHA-256 signer | `compiler/platform/darwin/` | Internal executable construction for x86_64 and AArch64 |
| Darwin ARM64 runtime and backend | `compiler/platform/darwin/arm64/` | Registered Apple Silicon target |

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

These structural checks alone do not establish macOS execution support. The
native gate is `python3 scripts/test.py --suite macos` on Apple Silicon. It
checks the native compiler, generated Mach-O signatures, dyld execution,
Darwin file and process services, and a relocated tar.gz under a restricted
PATH. CI uses the same command on `macos-15`.
