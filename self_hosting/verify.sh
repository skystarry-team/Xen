#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
./bootstrap.sh
stage0=${XEN_STAGE0:-../compiler/dist/xen}
for name in core memory records; do
    "$stage0" build "examples/$name.xen" --target=x86_64-linux --opt=off -o "build/$name.stage0"
    ./build/stage2 build - -o - < "examples/$name.xen" > "build/$name.stage2"
    chmod +x "build/$name.stage2"
    "./build/$name.stage0" > "build/$name.expected"
    "./build/$name.stage2" > "build/$name.actual"
    cmp "build/$name.expected" "build/$name.actual"
    echo "PASS: $name (stage0/stage2 output identical)"
done

# A compile error must fail, report the expected code, and emit no ELF bytes.
reject() {
    code=$1
    source=$2
    printf '%s\n' "$source" > build/rejected.xen
    if ./build/stage2 build - -o - < build/rejected.xen > build/rejected.elf 2> build/rejected.err; then
        echo "Unexpected acceptance: $source" >&2
        exit 1
    fi
    test ! -s build/rejected.elf
    case "$(cat build/rejected.err)" in
        "E$code "*) ;;
        *) cat build/rejected.err >&2; exit 1 ;;
    esac
}
reject_both() {
    reject "$1" "$2"
    if "$stage0" check build/rejected.xen --target=x86_64-linux > build/seed.out 2> build/seed.err; then
        echo "Seed unexpectedly accepted: $2" >&2
        exit 1
    fi
}
reject 309 'fn main() { let x = 1; x = 2; }'
reject 306 'fn main() { { let x = 1; } println(x); }'
reject 307 'fn main() { let x = 1; let x = 2; }'
reject 307 'fn f(x: Int) { let x = 2; } fn main() {}'
reject 307 'fn f(x: Int, x: Int) {} fn main() {}'
reject 301 'fn main() { let x: Bool = 1; }'
reject 301 'fn f(x: Bool) {} fn main() { f(1); }'
reject 301 'fn main() { if 1 {} }'
reject 301 'fn f() -> Int { return true; } fn main() {}'
reject 310 'fn f() -> Int { if true { return 1; } } fn main() {}'
reject 304 'fn main() {} fn main() {}'
reject 303 'fn for() {} fn main() {}'
reject 303 'fn len(x: Int) -> Int { return x + 1; } fn main() { println(len(41)); }'
reject 303 'fn atomic_compare_exchange() {} fn main() {}'
reject 313 'fn f() -> Int { return 42; } fn main() { let f = 1; println(f()); }'
reject 314 'fn main() { return; println(42); }'
reject 314 'fn main() { if true { return; } else { return; } println(42); }'
reject 311 'fn other() {}'
reject 312 'fn main(x: Int) {}'
reject 308 'fn main() { missing(); }'
reject 403 'fn main() { syscall0(39); }'
reject 401 '#global[bb]
fn main() { asm("nop"); }'
reject_both 404 '#global[bb] fn main() {}'
reject 103 'fn main() { println("unsupported String"); }'
reject_both 502 'struct Thing {} fn main() {}'
reject_both 501 'struct Thing { x: Int } struct Thing { y: Int } fn main() {}'
reject_both 502 'struct Thing { x: Int, x: Int } fn main() {}'
reject_both 302 'struct Thing { x: Unit } fn main() {}'
reject_both 302 'struct Thing { x: Missing } fn main() {}'
reject_both 505 'struct Thing { x: Thing } fn main() {}'
reject_both 505 'struct A { x: B } struct B { x: A } fn main() {}'
reject_both 503 'struct Thing { x: Int } fn main() { let x = Thing { y: 1 }; }'
reject_both 504 'struct Thing { x: Int } fn main() { let x = Thing {}; }'
reject_both 504 'struct Thing { x: Int } fn main() { let x = Thing { x: 1, x: 2 }; }'
reject_both 301 'struct Thing { x: Int } fn main() { let x = Thing { x: false }; }'
reject_both 503 'struct Thing { x: Int } fn main() { let x = Thing { x: 1 }; println(x.y); }'
reject_both 503 'fn main() { let x = 1; println(x.y); }'
reject_both 309 'struct Thing { x: Int } fn main() { let x = Thing { x: 1 }; x.x = 2; }'
reject_both 301 'struct Thing { x: Int } fn main() { let mut x = Thing { x: 1 }; x.x = false; }'
reject_both 301 'struct A { x: Int } struct B { x: Int } fn main() { let a = A { x: 1 }; let b: B = a; }'
reject_both 301 'struct A { x: Int } fn main() { let a = A { x: 1 }; assert(a == a); }'
reject_both 303 'struct Int { x: Int } fn main() {}'
reject 202 'fn main() { println(9223372036854775808); }'
reject 202 'fn main() { println(9223372036854775809); }'
reject 203 'fn main() { println("unterminated); }'
reject 204 'fn main() { @; }'
reject 101 'fn main() {'
echo 'PASS: invalid and unsupported programs rejected before output'

printf '#global[bb]\nfn main() {}\n' > build/global-newline.xen
"$stage0" check build/global-newline.xen --target=x86_64-linux
./build/stage2 build - -o - < build/global-newline.xen > build/global-newline
chmod +x build/global-newline
./build/global-newline
echo 'PASS: global capability declaration requires a newline'

# These compatibility regressions must also be rejected by the seed compiler.
for source in \
    'fn f() -> Int { return 42; } fn main() { let f = 1; println(f()); }' \
    'fn len(x: Int) -> Int { return x + 1; } fn main() { println(len(41)); }' \
    'fn main() { return; println(42); }' \
    'fn main() { if true { return; } else { return; } println(42); }'; do
    printf '%s\n' "$source" > build/rejected.xen
    if "$stage0" check build/rejected.xen --target=x86_64-linux > build/seed.out 2> build/seed.err; then
        echo "Seed unexpectedly accepted: $source" >&2
        exit 1
    fi
done
echo 'PASS: scope, reserved-name and unreachable-code regressions agree with stage0'

# Runtime errors must terminate unsuccessfully, including invalid shifts.
for expression in '1 / 0' '1 % 0' '-9223372036854775808 / -1' '-9223372036854775808 % -1' '1 << -1' '1 >> 64'; do
    printf 'fn main() { println(%s); }\n' "$expression" > build/trap.xen
    ./build/stage2 build - -o - < build/trap.xen > build/trap
    chmod +x build/trap
    status=0
    ./build/trap > build/trap.out 2> build/trap.err || status=$?
    if [ "$status" != 101 ]; then
        echo "Runtime error did not fail: $expression" >&2
        exit 1
    fi
done
printf 'fn main() { assert(false); }\n' > build/trap.xen
./build/stage2 build - -o - < build/trap.xen > build/trap
chmod +x build/trap
status=0
./build/trap > build/trap.out 2> build/trap.err || status=$?
test "$status" = 101
echo 'PASS: arithmetic runtime errors'
