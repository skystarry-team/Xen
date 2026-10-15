#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
# Run as root inside a disposable Debian/Ubuntu container, with /packages mounted.
set -eu
export DEBIAN_FRONTEND=noninteractive
unset XEN_STDLIB_ROOT
apt-get update -qq
apt-get install -y --no-install-recommends "/packages/$1"
test "$(xen version)" = "xen $2"
# Minimal Ubuntu images may exclude /usr/share/doc through dpkg configuration.
cd "$(mktemp -d)"
cat > hello.xen <<'EOF'
use std.string;
fn main() {
    assert(std.string.contains("hello", "ell"));
    println("deb-ok");
}
EOF
xen check hello.xen
test "$(xen run hello.xen)" = deb-ok
xen build hello.xen -o hello
test "$(./hello)" = deb-ok
xen build hello.xen --target=x86_64-linux -o hello-x86_64
xen build hello.xen --target=aarch64-linux -o hello-aarch64
xen test std.fs --filter null
apt-get remove -y xen-lang
test ! -e /usr/bin/xen
test ! -e /usr/lib/xen/std/string.xen
