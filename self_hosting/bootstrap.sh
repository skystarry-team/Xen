#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
# Shell only orchestrates Xen executables, redirections and byte comparisons.
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if [ "$(uname -sm)" != 'Linux x86_64' ]; then
    echo 'This bootstrap currently requires Linux x86_64.' >&2
    exit 1
fi
stage0=${XEN_STAGE0:-../compiler/dist/xen}
mkdir -p build
./assemble.sh > build/compiler.xen.tmp
mv build/compiler.xen.tmp build/compiler.xen
./assemble.sh bootstrap/driver.xen > build/driver.xen.tmp
mv build/driver.xen.tmp build/driver.xen
# Preserve the upgrade path: the original scalar implementation compiles the
# scalar implementation of records, which compiles the new Context-based source.
"$stage0" build bootstrap/scalar.xen --target=x86_64-linux --opt=off -o build/scalar-seed
./build/scalar-seed < bootstrap/records.xen > build/records-seed.tmp
chmod +x build/records-seed.tmp
mv build/records-seed.tmp build/records-seed
# The old seed emits the previous startup ABI. This stdin-only entry uses the
# current shared backend to generate an executable with the new startup page.
./build/records-seed < build/driver.xen > build/driver.tmp
chmod +x build/driver.tmp
mv build/driver.tmp build/driver
./build/driver < build/compiler.xen > build/stage1.tmp
chmod +x build/stage1.tmp
mv build/stage1.tmp build/stage1
./build/stage1 build build/compiler.xen -o build/stage2
./build/stage2 build build/compiler.xen -o build/stage3
cmp build/stage2 build/stage3
cp build/stage3 build/xen.tmp
mv build/xen.tmp build/xen
echo 'Self compilation succeeded: stage2 == stage3.'
sha256sum build/stage2 build/stage3
