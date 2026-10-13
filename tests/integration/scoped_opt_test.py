# SPDX-License-Identifier: MIT OR Apache-2.0
"""Scoped AOT defaults, runtime removal, and scope-only optimization."""
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
XEN = ROOT / 'compiler/dist/xen'
ENV = dict(os.environ, XEN_STDLIB_ROOT=str(ROOT / 'stdlib'))

def invoke(*args):
    return subprocess.run([str(XEN), *map(str, args)], env=ENV,
                          capture_output=True, timeout=30)

with tempfile.TemporaryDirectory(prefix='xen-scoped-aot-') as directory:
    root = Path(directory)
    source = root / 'app.xen'
    source.write_text('fn f(n:Int)->Int{let mut i=0;let mut sum=0;'
                      '#scope[opt]{while i<n{let w=n*n+3;sum=sum+w+i;i=i+1;}}return sum;}'
                      'fn main(){println(f(0));println(f(3));println(f(257));}')
    expected = b'0\n39\n17008260\n'
    for flags in [(), ('--opt=basic',), ('--opt=off',)]:
        run = invoke('run', source, *flags)
        assert (run.returncode, run.stdout, run.stderr) == (0, expected, b''), run
    report = invoke('run', source, '--opt-report')
    assert report.returncode == 0 and report.stdout == expected
    assert b'opt loop f ' in report.stderr and b'hoisted=' in report.stderr
    for target in ('x86_64-linux', 'aarch64-linux'):
        default, explicit, off = (root / (target + name) for name in ('-default', '-basic', '-off'))
        for output, flags in ((default, ()), (explicit, ('--opt=basic',)), (off, ('--opt=off',))):
            build = invoke('build', source, f'--target={target}', *flags, '-o', output)
            assert build.returncode == 0 and build.stderr == b'', build
        assert default.read_bytes() == explicit.read_bytes()
        assert default.read_bytes() != off.read_bytes()
        cpu = {'arm64': 'aarch64', 'amd64': 'x86_64'}.get(platform.machine(), platform.machine())
        target_cpu = target.split('-')[0]
        runner = [] if target_cpu == cpu else [shutil.which('qemu-' + target_cpu)]
        if not runner or runner[0]:
            for binary in (default, explicit, off):
                run = subprocess.run([*runner, str(binary)], capture_output=True, timeout=30)
                assert (run.returncode, run.stdout, run.stderr) == (0, expected, b''), run
    source.write_text('fn main(){let x=arg_count()+7;println(x*x+x*x);}')
    outputs = []
    for mode in ('off', 'basic'):
        binary = root / mode
        build = invoke('build', source, f'--opt={mode}', '-o', binary)
        assert build.returncode == 0 and build.stderr == b''
        outputs.append(binary.read_bytes())
    assert outputs[0] == outputs[1], 'unmarked code was optimized'
    for flag in ('--jit=off', '--jit=on', '--jit=adaptive', '--jit-report'):
        assert invoke('run', source, flag).returncode == 2
    for text in ('fn main(){#scope[jit]{}}', '#global[jit]\nfn main(){}', '#![jit]\nfn main(){}'):
        source.write_text(text)
        result = invoke('check', source)
        assert result.returncode == 1 and b'unknown' in result.stderr, result
    source.write_text('test fn scoped(){#scope[opt]{let x=3;assert(x*x+x*x==18);}}')
    assert invoke('test', source).returncode == 0
    source.write_text('#global[opt]\nfn main(){}')
    assert b'global opt mode is not supported' in invoke('check', source).stderr
print('Scoped AOT CLI defaults, both targets, and removed JIT contract passed')
