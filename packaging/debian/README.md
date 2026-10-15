# Xen Debian package

Install the package matching your CPU with
`sudo apt install ./xen-lang_<version>_amd64.deb` (or `_arm64.deb`).
Use `xen version`, `xen run hello.xen` or `xen test std.string` from any directory.
Remove it with `sudo apt remove xen-lang`.

The compiler is `/usr/bin/xen`, its required standard library is `/usr/lib/xen`,
and examples and license notices are in `/usr/share/doc/xen-lang`.
Both Linux target profiles are included. Generated programs require no compiler,
linker or libc. The compiler itself needs the system libraries listed by apt.

The Debian package version converts `_` and `-` suffix separators to `~` and
adds packaging revision `-1`. For example, `0.1.0_1-demo` becomes
`0.1.0~1~demo-1`, ordered before `0.1.0-1`. `xen version` and the installed
`VERSION` file retain `0.1.0_1-demo`.

The package name is `xen-lang`; the command is `xen`.
See https://github.com/skystarry-team/Xen for the language guide and sources.
