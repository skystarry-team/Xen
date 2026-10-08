# SPDX-License-Identifier: MIT OR Apache-2.0
"""Reproducible optimization costs; times are observations, never pass criteria."""
import json
from pathlib import Path
import platform
import statistics
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
XEN = ROOT / 'compiler/dist/xen'
SOURCE = '''fn compute(x:Int)->Int {
    let a=x*x;
    let b=x*x;
    return a+b;
}
fn main(){
    let mut i=0;
    let mut total=0;
    while i<2000000 {
        total=total+compute(i);
        i=i+1;
    }
    println(total);
}
'''


def code_bytes(data):
    phoff = struct.unpack_from('<Q', data, 32)[0]
    phsize, phnum = struct.unpack_from('<HH', data, 54)
    for i in range(phnum):
        kind, flags, _, _, _, size, _, _ = struct.unpack_from('<IIQQQQQQ', data, phoff + i * phsize)
        if kind == 1 and flags & 1:
            return size


with tempfile.TemporaryDirectory(prefix='xen-opt-bench-') as directory:
    root = Path(directory)
    source = root / 'calculation.xen'
    source.write_text(SOURCE)
    result = {'platform': platform.platform(), 'repetitions': 5, 'iterations': 2000000, 'modes': {}}
    outputs = []
    for mode in ('off', 'basic'):
        binary = root / mode
        compile_times = []
        run_times = []
        for _ in range(5):
            start = time.perf_counter()
            subprocess.run([str(XEN), 'build', str(source), f'--opt={mode}', '-o', str(binary)],
                           cwd=root, check=True, capture_output=True)
            compile_times.append(time.perf_counter() - start)
        for _ in range(5):
            start = time.perf_counter()
            output = subprocess.run([str(binary)], cwd=root, check=True, capture_output=True)
            run_times.append(time.perf_counter() - start)
            outputs.append(output.stdout)
        data = binary.read_bytes()
        result['modes'][mode] = {'elf_bytes': len(data), 'code_bytes': code_bytes(data),
                                'compile_ms_median': round(1000 * statistics.median(compile_times), 3),
                                'run_ms_median': round(1000 * statistics.median(run_times), 3)}
    assert len(set(outputs)) == 1
    result['stdout'] = outputs[0].decode().strip()
    scaling = subprocess.run(['dune', 'exec', 'benchmarks/semantic_opt_benchmark.exe'],
                             cwd=ROOT, check=True, capture_output=True, text=True)
    result['region_scaling'] = json.loads(scaling.stdout)
    print(json.dumps(result, indent=2))
