# SPDX-License-Identifier: MIT OR Apache-2.0
"""Experimental JIT cold/first invocation/warm loop observations, no thresholds."""
import json
from pathlib import Path
import re
import statistics
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
XEN = ROOT / 'compiler/dist/xen'
ITERATIONS = 2000000
SOURCE = '''#global[bb]
fn stamp(p:Ptr<Int>)->Int{
    syscall2(228,1,ptr_addr(p));
    return raw_load_int(p,0)*1000000000+raw_load_int(p,1);
}
fn compute(x:Int)->Int{#scope[jit]{let a=x*x;let b=x*x;return a+b;}}
fn main(){
    let clock=raw_alloc_int(2);
    let t0=stamp(clock);
    let first=compute(7);
    let t1=stamp(clock);
    let start=stamp(clock);
    let mut i=0;let mut total=0;
    while i<2000000{total=total+compute(i);i=i+1;}
    let end=stamp(clock);
    println(first);println(total);println(t1-t0);println(end-start);
    raw_free_int(clock);
}
'''


def median(xs):
    return round(statistics.median(xs), 3)


with tempfile.TemporaryDirectory(prefix='xen-jit-bench-') as directory:
    root = Path(directory)
    source = root / 'app.xen'
    source.write_text(SOURCE)
    result = {'iterations': ITERATIONS, 'repetitions': 5, 'baseline': 'basic AOT (--jit=off)', 'modes': {}}
    for mode in ('off', 'on'):
        binary = root / mode
        builds = []
        for _ in range(5):
            start = time.perf_counter()
            subprocess.run([str(XEN), 'build', source, '--opt=basic', f'--jit={mode}', '-o', binary],
                           check=True, capture_output=True)
            builds.append((time.perf_counter() - start) * 1000)
        first = []
        warm = []
        process = []
        for _ in range(5):
            start = time.perf_counter()
            r = subprocess.run([binary], check=True, capture_output=True)
            process.append((time.perf_counter() - start) * 1000)
            lines = list(map(int, r.stdout.splitlines()))
            assert lines[:2] == [98, 5333329333334000000] and r.stderr == b''
            first.append(lines[2])
            warm.append(lines[3])
        data = binary.read_bytes()
        phoff = struct.unpack_from('<Q', data, 32)[0]
        phsize, phnum = struct.unpack_from('<HH', data, 54)
        size = next(struct.unpack_from('<Q', data, phoff + i * phsize + 32)[0]
                    for i in range(phnum) if struct.unpack_from('<II', data, phoff + i * phsize)[0] == 1 and struct.unpack_from('<II', data, phoff + i * phsize)[1] & 1)
        result['modes'][mode] = {'elf_bytes': len(data), 'code_segment_bytes': size,
                                'build_ms': median(builds), 'first_invocation_ns': median(first),
                                'warm_loop_ms': median(warm) / 1000000,
                                'warm_ns_per_iteration': median(warm) / ITERATIONS,
                                'process_ms': median(process)}
    report = root / 'report'
    subprocess.run([str(XEN), 'build', source, '--opt=basic', '--jit-report', '-o', report], check=True, capture_output=True)
    r = subprocess.run([report], check=True, capture_output=True)
    result['instrumented_runtime'] = {label: int(re.search(('jit ' + label + r': (\d+)').encode(), r.stderr)[1])
                                      for label in ('compilations', 'cache hits', 'compile ns')}
    result['instrumented_runtime']['mapped_bytes'] = 4096 * result['instrumented_runtime']['compilations']
    print(json.dumps(result, indent=2))
