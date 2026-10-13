# SPDX-License-Identifier: MIT OR Apache-2.0
"""Observe counted-loop fusion and cold/warm prefix-cache costs on the host."""
import argparse
import os
from pathlib import Path
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--iterations', type=int, default=2_000_000)
    parser.add_argument('--repetitions', type=int, default=5)
    args = parser.parse_args()
    if args.iterations < 0 or args.repetitions < 1:
        parser.error('iterations must be nonnegative and repetitions positive')
    xen = Path(os.environ.get('XEN_BIN', ROOT / 'compiler/dist/xen')).resolve()
    if not xen.is_file():
        parser.error('build the compiler with dune build @release first')
    env = dict(os.environ)
    env.setdefault('XEN_STDLIB_ROOT', str(ROOT / 'stdlib'))
    source = ('fn calculate(n:Int)->Int{let mut i=0;let mut j=0;let mut a=0;let mut b=0;'
              '#scope[opt]{while i<n{a=a+i*i;i=i+1;}while j<n{b=b+j+j;j=j+1;}}'
              f'return a+b+i+j;}}fn main(){{println(calculate({args.iterations}));}}')
    n = args.iterations
    expected = (n * (n - 1) * (2 * n - 1) // 6 + n * (n - 1) + 2 * n) % (1 << 64)
    if expected >= 1 << 63:
        expected -= 1 << 64
    expected = f'{expected}\n'.encode()
    with tempfile.TemporaryDirectory(prefix='xen-aot-fusion-bench-') as directory:
        root = Path(directory)
        app = root / 'app.xen'
        app.write_text(source)
        warm_cache = root / 'warm-cache'
        def build(binary, flags):
            return subprocess.run([str(xen), 'build', str(app), *flags, '-o', str(binary)],
                                  env=env, capture_output=True, check=True, timeout=60)
        build(root / 'warm-up', [f'--opt-cache={warm_cache}'])
        basic_bytes = None
        for mode in ('off', 'basic', 'cold-cache', 'warm-cache'):
            builds, runs = [], []
            binary = root / f'{mode}.bin'
            for repetition in range(args.repetitions):
                flags = {'off': ['--opt=off'], 'basic': [],
                         'cold-cache': [f'--opt-cache={root / ("cold-" + str(repetition))}'],
                         'warm-cache': [f'--opt-cache={warm_cache}']}[mode]
                start = time.perf_counter()
                build(binary, flags)
                builds.append((time.perf_counter() - start) * 1000)
                start = time.perf_counter()
                result = subprocess.run([str(binary)], capture_output=True, check=True, timeout=60)
                runs.append((time.perf_counter() - start) * 1000)
                assert result.stdout == expected and result.stderr == b'', result
            data = binary.read_bytes()
            if mode == 'basic':
                basic_bytes = data
            elif mode in ('cold-cache', 'warm-cache'):
                assert data == basic_bytes, 'cache changed native code'
            print(f'{mode}: compile={statistics.median(builds):.3f} ms '
                  f'run={statistics.median(runs):.3f} ms executable={len(data)} bytes')
        print(f'independent checksum matched: {expected.decode().strip()}')
        print('Times are observations; a prefix hit does not guarantee a faster build.')

if __name__ == '__main__':
    main()
