# SPDX-License-Identifier: MIT OR Apache-2.0
"""Actual runtime encoding, cache/ABI, permissions, bounds and failure checks."""
import ctypes
import errno
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
XEN = ROOT / 'compiler/dist/xen'
ENV = dict(os.environ, XEN_STDLIB_ROOT=str(ROOT / 'stdlib'))


def invoke(*args, cwd=None, input=None):
    return subprocess.run([str(XEN), *map(str, args)], cwd=cwd, input=input, env=ENV,
                          capture_output=True, timeout=30)


def stats(stderr):
    return tuple(int(re.search(rb'jit ' + label + rb': (\d+)', stderr)[1])
                 for label in (b'compilations', b'cache hits', b'compile ns'))


def deny_mprotect(trap_unmap=False):
    # Linux headers: seccomp_data.nr=0, BPF_LD|W|ABS=0x20,
    # BPF_JMP|JEQ|K=0x15, BPF_RET|K=6; x86-64 mprotect syscall=10.
    class Filter(ctypes.Structure):
        _fields_ = [('code', ctypes.c_ushort), ('jt', ctypes.c_ubyte),
                    ('jf', ctypes.c_ubyte), ('k', ctypes.c_uint)]
    class Program(ctypes.Structure):
        _fields_ = [('length', ctypes.c_ushort), ('filter', ctypes.POINTER(Filter))]
    rows = [Filter(0x20, 0, 0, 0), Filter(0x15, 0, 1, 10), Filter(6, 0, 0, 0x50000 | errno.EACCES)]
    if trap_unmap:
        rows += [Filter(0x15, 0, 1, 11), Filter(6, 0, 0, 0x30000)]
    rows += [Filter(6, 0, 0, 0x7fff0000)]
    filters = (Filter * len(rows))(*rows)
    program = Program(len(rows), filters)
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(38, 1, 0, 0, 0) or libc.prctl(22, 2, ctypes.byref(program), 0, 0):
        raise OSError(ctypes.get_errno(), 'seccomp test setup failed')


with tempfile.TemporaryDirectory(prefix='xen-jit-') as directory:
    root = Path(directory)
    source = root / 'app.xen'
    checked = 0

    def compare(text, expected=None, report=False):
        global checked
        source.write_text(text)
        for opt in ('off', 'basic'):
            a = invoke('run', source, f'--opt={opt}', '--jit=off', cwd=root)
            b = invoke('run', source, f'--opt={opt}', '--jit=on', cwd=root)
            assert (a.returncode, a.stdout, a.stderr) == (b.returncode, b.stdout, b.stderr), (text, a, b)
            if expected is not None:
                assert a.returncode == 0 and a.stdout == expected and a.stderr == b''
        checked += 1
        if report:
            r = invoke('run', source, '--opt=basic', '--jit-report', cwd=root)
            assert r.returncode == 0 and r.stdout == b.stdout
            return stats(r.stderr)
        return a

    assert compare('fn f(x:Int)->Int{#scope[jit]{return x*x+1;}}fn main(){println(f(2));println(f(5));let c:fn(Int)->Int=f;println(c(7));}', b'5\n26\n50\n', True)[:2] == (1, 2)
    compare('fn down(n:Int)->Int{#scope[jit]{let x=n*n;}if n==0{return 1;}let child=down(n-1);#scope[jit]{return child+n;}}fn main(){println(down(20));}', b'211\n', True)
    compare('fn main(){let mut i=0;#scope[jit]{while i<5{let x=i*i+1;println(x);i=i+1;}}}', b'1\n2\n5\n10\n17\n', True)
    for typ, maximum in [('I8', '127'), ('U8', '255'), ('I16', '32767'), ('U16', '65535'), ('I32', '2147483647'), ('U32', '4294967295'), ('I64', '9223372036854775807'), ('U64', '18446744073709551615')]:
        compare(f'fn f(a:{typ},b:{typ}){{#scope[jit]{{println(a+b);println(a-b);println(a*b);println(a<b);println(a<=b);println(a>b);println(a>=b);println(a==b);println(a!=b);}}}}fn main(){{let a:{typ}={maximum};let b:{typ}=1;f(a,b);f(b,a);}}')
    compare('fn main(){#scope[jit]{let a:U64=18446744073709551615;let b:U64=9223372036854775808;println(a>b);println(a+b);let c:Int=-9223372036854775808;println(-c);let x:Bool=true;println(!x);println(x==false);}}')
    compare('fn tick(n:Int)->Int{println(n);return n;}fn main(){let mut x=arg_count()+4;#scope[jit]{let a=x*x;let b=a;x=7;println(a+b+x*x);println(tick(2)+tick(3));}}')
    compare('#global[explc]\nfn set(x:&mut Int){*x=9;}fn main(){let mut x=3;#scope[jit]{let a=x*x;set(&mut x);let b=x*x;println(a);println(b);}}', b'9\n81\n')
    compare('fn side()->Bool{println(99);return true;}fn main(){#scope[jit]{println(false && side());println(true || side());let s="hi";let mut v=[s];while v.len()<3{v.push("bye");}println(v.len());}}', b'false\ntrue\n3\n')
    compare('fn main(){#scope[jit]{let x:Int=128;println(i8(x));}}')
    compare('fn main(){#scope[jit]{let x:Int=-9223372036854775808;println(x/-1);}}')
    compare('fn main(){#scope[jit]{println(1%0);}}')
    compare('fn main(){#scope[jit]{let x:F32=1.5;println(x*x);}}', b'2.25\n')
    compare('enum Choice{First(Int),Second((Int,Int))}fn main(){#scope[jit]{let ch=Choice.First(11);println(match ch{Choice.First(x)=>x,Choice.Second((a,b))=>a+b});}}', b'11\n')
    compare('fn main(){#scope[jit]{println(1+match Option.Some(3){Option.Some(x)=>x,Option.None=>0});let x=if true{match true{true=>3,false=>4}}else{5};println(x);}}', b'4\n3\n')
    # Same operator/result with different signedness must select different recipes.
    compare('fn main(){#scope[jit]{let a:I64=-1;let b:U64=18446744073709551615;println(a<1);println(b<1);}}', b'true\nfalse\n')
    for n, status in [(4093, 0), (4094, 1)]:
        r = compare(f'fn leaf(x:Int)->Int{{#scope[jit]{{return x+1;}}}}\nfn down(n:Int)->Int{{if n==0{{return leaf(7);}}return down(n-1);}}\nfn main(){{println(down({n}));}}')
        assert r.returncode == status
        if status:
            assert b':2:36: xen runtime error: maximum call depth exceeded' in r.stderr
    # Region cap: one page each, 64 process entries; later regions remain AOT.
    c, h, _ = compare('fn main(){#scope[jit]{' + 'println(1);' * 80 + '}}', b'1\n' * 80, True)
    assert (c, h) == (64, 0)
    compare('fn f(x:Int)->Int{#scope[jit]{let mut y=x;' + 'y=y+x;' * 70 + 'return y;}}fn main(){println(f(3));}', b'213\n', True)
    # Output resides in anonymous RX mappings; none are writable/executable.
    source.write_text('fn f(x:Int)->Int{#scope[jit]{return x*x+1;}}fn main(){println(f(3));println(read_text("/proc/self/maps"));}')
    a = invoke('run', source, '--jit=off')
    b = invoke('run', source, '--jit-report')
    def anonymous_rx(out):
        return [line for line in out.splitlines() if re.match(rb'^[0-9a-f]+-[0-9a-f]+ r-xp ', line) and len(line.split()) == 5]
    assert not anonymous_rx(a.stdout) and len(anonymous_rx(b.stdout)) == stats(b.stderr)[0] == 1
    assert not re.search(rb'^[0-9a-f]+-[0-9a-f]+ rwx', b.stdout, re.M)
    # Deny new mappings after startup: JIT must diagnose, never silently use AOT.
    source.write_text('#global[bb]\nfn main(){let p=raw_alloc_int(2);raw_store_int(p,0,0);raw_store_int(p,1,0);syscall4(302,0,9,ptr_addr(p),0);raw_free_int(p);#scope[jit]{println(1);}}')
    a = invoke('run', source, '--jit=off')
    b = invoke('run', source)
    assert a.returncode == 0 and a.stdout == b'1\n'
    column = source.read_text().splitlines()[1].index('println(1)') + len('println(') + 1
    assert b.returncode == 1 and f'{source}:2:{column}: xen runtime error: JIT compilation failed'.encode() in b.stderr
    # Denied mprotect also fails; the runtime follows its explicit munmap path.
    source.write_text('fn main(){#scope[jit]{println(1);}}')
    binary = root / 'failure'
    assert invoke('build', source, '-o', binary).returncode == 0
    r = subprocess.run([str(binary)], preexec_fn=deny_mprotect, capture_output=True, timeout=10)
    column = source.read_text().index('println(1)') + len('println(') + 1
    assert r.returncode == 1 and r.stdout == b'' and f'{source}:1:{column}: xen runtime error: JIT compilation failed'.encode() in r.stderr
    r = subprocess.run([str(binary)], preexec_fn=lambda: deny_mprotect(True), capture_output=True, timeout=10)
    assert r.returncode == -signal.SIGSYS  # kernel observed the cleanup munmap
    assert invoke('build', source, '--jit=off', '-o', binary).returncode == 0
    r = subprocess.run([str(binary)], preexec_fn=lambda: deny_mprotect(True), capture_output=True, timeout=10)
    assert r.returncode == 0 and r.stdout == b'1\n'  # trap isn't host setup noise
    for args in [('run', source, '--jit=wat'), ('run', source, '--jit=off', '--jit-report'), ('check', source, '--jit=on')]:
        assert invoke(*args).returncode == 2
    assert invoke('check', source).returncode == 0
    source.write_text('fn f(x:Int)->Int{#scope[jit]{return x+1;}}test fn ok(){assert(f(2)==3);}')
    a = invoke('test', source, '--jit=off')
    b = invoke('test', source)
    assert a.returncode == b.returncode == 0 and a.stdout == b.stdout and a.stderr == b.stderr == b''
    report = invoke('test', source, '--jit-report')
    assert report.returncode == 0 and stats(report.stderr)[0] == 1
print(f'Runtime JIT tests passed: {checked} differential cases plus cache, RX and failure controls')
