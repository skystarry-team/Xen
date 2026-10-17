# SPDX-License-Identifier: MIT OR Apache-2.0
"""Validate the portable compiler's PE header and direct DLL dependency policy.

Field layouts: https://learn.microsoft.com/en-us/windows/win32/debug/pe-format
This is a package gate, not a replacement for execution by the Windows loader.
"""
from pathlib import Path
import struct

# Audited native OCaml/MinGW build dependencies. New DLLs require an explicit
# distribution decision; do not accidentally depend on the builder's PATH.
SYSTEM_DLLS = frozenset({
    "kernel32.dll", "msvcrt.dll", "shell32.dll", "advapi32.dll", "ole32.dll",
    "shlwapi.dll", "api-ms-win-core-synch-l1-2-0.dll", "version.dll", "ws2_32.dll",
})


def inspect(binary: Path) -> set[str]:
    data = binary.read_bytes()

    def unpack(layout, offset):
        if offset < 0 or offset + struct.calcsize(layout) > len(data):
            raise ValueError("truncated compiler PE image")
        return struct.unpack_from(layout, data, offset)

    if data[:2] != b"MZ":
        raise ValueError("Windows compiler must be an AMD64 PE32+ executable")
    pe, = unpack("<I", 0x3c)
    if pe < 64 or data[pe:pe+4] != b"PE\0\0":
        raise ValueError("invalid compiler PE signature")
    machine, count, _, _, _, size, flags = unpack("<HHIIIHH", pe+4)
    opt = pe+24
    if machine != 0x8664 or not flags & 2 or flags & 0x2000:
        raise ValueError("Windows compiler must be an AMD64 executable image, not a DLL")
    if size < 112 or unpack("<H", opt)[0] != 0x20b:
        raise ValueError("Windows compiler must use PE32+")
    directories, = unpack("<I", opt+108)
    if directories < 2 or directories > 16 or size < 112+8*directories:
        raise ValueError("invalid compiler PE data directories")
    if not 1 <= count <= 96:
        raise ValueError("invalid compiler PE section count")
    sections = []
    for index in range(count):
        _, virtual_size, rva, raw_size, raw, _, _, _, _, _ = unpack("<8sIIIIIIHHI", opt+size+40*index)
        if raw_size and raw+raw_size > len(data):
            raise ValueError("truncated compiler PE section")
        sections.append((rva, min(virtual_size, raw_size), raw))

    def offset(rva, length):
        for start, size, raw in sections:
            if start <= rva and rva+length <= start+size:
                return raw+rva-start
        raise ValueError("compiler PE RVA is not backed by section data")

    def directory(index):
        return unpack("<II", opt+112+8*index) if index < directories else (0, 0)

    # No delay loader is needed by the current compiler. Reject rather than
    # silently omit a second dependency table from the policy check.
    if directory(13) != (0, 0):
        raise ValueError("Windows compiler delay imports are not supported by the portable package")
    rva, length = directory(1)
    if not rva or length < 20:
        raise ValueError("missing compiler PE import directory")
    imports = set()
    for index in range(length // 20):
        descriptor = unpack("<5I", offset(rva+index*20, 20))
        if not any(descriptor):
            break
        name_rva = descriptor[3]
        name = bytearray()
        for at in range(256):
            byte = data[offset(name_rva+at, 1)]
            if not byte:
                break
            name.append(byte)
        else:
            raise ValueError("unterminated compiler PE DLL name")
        try:
            imports.add(name.decode("ascii").lower())
        except UnicodeDecodeError as error:
            raise ValueError("invalid compiler PE DLL name") from error
    else:
        raise ValueError("unterminated compiler PE import directory")
    if not imports or imports - SYSTEM_DLLS:
        raise ValueError(f"Windows compiler has unapproved DLL dependencies: {sorted(imports - SYSTEM_DLLS)}")
    return imports
