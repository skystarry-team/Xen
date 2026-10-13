# Target stdlib services

Each `<architecture>-<os>/std/platform.xen` implements the internal service contract
described in [compiler/platform](../../compiler/platform/README.md). Its module name
is always `std.platform`; `Project_loader` selects exactly one normalized output
target before checking source. Keep all implemented profiles in every package.

Public std.io/fs/env/process APIs contain no syscall numbers or kernel record
offsets. Linux profiles share the explicitly OS-specific `std.platform_linux`
decoders. A new OS supplies normalized metadata, directory names and cwd bytes as
well as read/write/open/close/process calls, native flags and errno handling.
Do not copy Linux profiles to macOS or make a common std/platform.xen fallback.

`open_path` and `decode_directory` retain their native-ABI compatibility contracts;
portable callers use fs.read/write/append/metadata/read_dir. Allocation failure
remains fatal; recoverable I/O errors release temporary buffers and owned fds.
