# SPDX-License-Identifier: MIT OR Apache-2.0
"""Real loop fusion and persistent exact-prefix reuse across CLI processes."""
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
XEN = ROOT / 'compiler/dist/xen'
ENV = dict(os.environ, XEN_STDLIB_ROOT=str(ROOT / 'stdlib'))

def invoke(*args):
    return subprocess.run([str(XEN), *map(str, args)], env=ENV,
                          capture_output=True, timeout=30)

def prefixes(result, kind='calculation'):
    return [line for line in result.stderr.splitlines()
            if line.startswith(b'opt prefix ') and f'kind={kind} '.encode() in line]

def assert_run(result, expected):
    assert result.returncode == 0 and result.stdout == expected, result

with tempfile.TemporaryDirectory(prefix='xen-prefix-fusion-') as directory:
    root = Path(directory)
    source = root / 'app.xen'
    source.write_text((ROOT / 'examples/opt_fusion.xen').read_text())
    expected = b'0\n17\n5691522\n'
    cache = root / 'cache'
    flags = (f'--opt-cache={cache}', '--opt-report')
    cold = invoke('run', source, *flags)
    assert_run(cold, expected)
    assert b'opt loop-fusion calculate ' in cold.stderr and b' fused reason=fused' in cold.stderr
    assert prefixes(cold) and all(b'cache=miss' in line for line in prefixes(cold))
    warm = invoke('run', source, *flags)
    assert_run(warm, expected)
    assert all(b'cache=hit' in line for line in prefixes(warm))
    # One broken node must invalidate the dependent suffix, even if rebuilding
    # it produces exactly the same scalar operations.
    lines = prefixes(warm)
    broken = re.search(rb'key=([^ ]+)', lines[1]).group(1).decode()
    (cache / f'{broken}.prefix').write_text('broken cache record\n')
    rebuilt = invoke('run', source, *flags)
    assert_run(rebuilt, expected)
    receipts = prefixes(rebuilt)
    # Reports follow CFG traversal, while region output follows block storage.
    assert b'cache=hit' in receipts[0]
    assert all(b'cache=miss' in line for line in receipts[1:])
    warm_again = invoke('run', source, *flags)
    assert_run(warm_again, expected)
    assert all(b'cache=hit' in line for line in prefixes(warm_again))
    # Both backends generate identical code with/without a warm forward cache.
    for target in ('x86_64-linux', 'aarch64-linux'):
        off, uncached, cached = (root / f'{target}-{mode}' for mode in ('off', 'basic', 'cached'))
        for output, options in ((off, ('--opt=off',)), (uncached, ()),
                                (cached, (f'--opt-cache={cache}',))):
            result = invoke('build', source, f'--target={target}', *options, '-o', output)
            assert result.returncode == 0 and result.stderr == b'', result
        assert uncached.read_bytes() == cached.read_bytes()
        assert off.read_bytes() != cached.read_bytes()
        cpu = {'arm64': 'aarch64', 'amd64': 'x86_64'}.get(platform.machine(), platform.machine())
        target_cpu = target.split('-')[0]
        runner = [] if cpu == target_cpu else [shutil.which('qemu-' + target_cpu)]
        if not runner or runner[0]:
            for binary in (off, uncached, cached):
                result = subprocess.run([*runner, str(binary)], capture_output=True, timeout=30)
                assert (result.returncode, result.stdout, result.stderr) == (0, expected, b''), result
    def scalar(middle, last):
        return ('fn main(){let n=arg_count()+7;#scope[opt]{let a=n*n;println(a);'
                f'let b=n+{middle};println(b);let c=n*{last};println(c);}}}}')
    source.write_text(scalar(2, 3))
    assert_run(invoke('run', source, *flags), b'49\n9\n21\n')
    assert all(b'cache=hit' in line for line in prefixes(invoke('run', source, *flags)))
    source.write_text(scalar(4, 3))
    changed = invoke('run', source, *flags)
    assert_run(changed, b'49\n11\n21\n')
    receipts = prefixes(changed)
    assert b'cache=hit' in receipts[0] and any(b'cache=miss' in line for line in receipts)
    first_miss = next(i for i, line in enumerate(receipts) if b'cache=miss' in line)
    assert all(b'cache=miss' in line for line in receipts[first_miss:])
    parallel_cache = root / 'parallel-cache'
    workers = []
    for index in range(4):
        binary = root / f'parallel-{index}'
        process = subprocess.Popen([str(XEN), 'build', str(source),
                                    f'--opt-cache={parallel_cache}', '-o', str(binary)],
                                   env=ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        workers.append((process, binary))
    parallel_outputs = []
    for process, binary in workers:
        stdout, stderr = process.communicate(timeout=30)
        assert (process.returncode, stdout, stderr) == (0, b'', b''), (stdout, stderr)
        parallel_outputs.append(binary.read_bytes())
    assert len(set(parallel_outputs)) == 1
    parallel_warm = invoke('run', source, f'--opt-cache={parallel_cache}', '--opt-report')
    assert_run(parallel_warm, b'49\n11\n21\n')
    assert all(b'cache=hit' in line for line in prefixes(parallel_warm))
    # A cache never bypasses source checking or writes failed optimization output.
    before = {p.name: p.read_bytes() for p in cache.iterdir()}
    source.write_text('fn main(){#scope[opt]{let x:Bool=3;}}')
    assert invoke('run', source, *flags).returncode == 1
    assert before == {p.name: p.read_bytes() for p in cache.iterdir()}
    for options in (('--opt-cache=',), ('--opt=off', f'--opt-cache={cache}')):
        assert invoke('build', source, *options).returncode == 2
    assert invoke('check', source, f'--opt-cache={cache}').returncode == 2
    source.write_text('test fn cached(){#scope[opt]{let a=3;assert(a*a==9);}}')
    assert invoke('test', source, *flags).returncode == 0
    second_test = invoke('test', source, *flags)
    assert second_test.returncode == 0 and any(b'cache=hit' in line for line in prefixes(second_test))
print('Loop fusion and persistent prefix invalidation passed on both targets')
