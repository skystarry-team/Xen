# SPDX-License-Identifier: MIT OR Apache-2.0
"""CLI contract and decoded native leaf call removal (no timing assertions)."""
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
XEN = ROOT / 'compiler/dist/xen'
ENV = dict(os.environ, XEN_STDLIB_ROOT=str(ROOT / 'stdlib'))


def command(*args, cwd=None, input=None):
    return subprocess.run([str(XEN), *map(str, args)], cwd=cwd, env=ENV,
                          input=input, capture_output=True, timeout=30)


def leaf_calls(path):
    data = path.read_bytes()
    # The distinctive source-function prologue increments the logical depth.
    leaf = data.index(bytes.fromhex('55 48 89 e5 48 ff 05'))
    executable_segment = None
    phoff = struct.unpack_from('<Q', data, 32)[0]
    phsize, phnum = struct.unpack_from('<HH', data, 54)
    for i in range(phnum):
        kind, flags, offset, _, _, size, _, _ = struct.unpack_from('<IIQQQQQQ', data, phoff + i * phsize)
        if kind == 1 and flags & 1:
            executable_segment = (offset, offset + size)
    start, stop = executable_segment
    dis = subprocess.run(['objdump', '-D', '-b', 'binary', '-m', 'i386:x86-64',
                          f'--start-address={start}', f'--stop-address={stop}', str(path)],
                         check=True, capture_output=True, text=True).stdout
    return sum(int(target, 16) == leaf for target in re.findall(r'\bcall\s+0x([0-9a-f]+)', dis))


with tempfile.TemporaryDirectory(prefix='xen-opt-cli-') as directory:
    root = Path(directory)
    source = root / 'main.xen'
    source.write_text('fn leaf(x:Int)->Int{return x*x;}\nfn main(){println(leaf(arg_count()));println(arg(0));}')
    off = command('run', source, '--opt=off', '--', '--opt=basic')
    basic = command('run', '--opt=basic', source, '--', '--opt=basic')
    default = command('run', source, '--', '--opt=basic')
    assert off.returncode == 0 and off.stdout == b'1\n--opt=basic\n'
    assert (off.returncode, off.stdout, off.stderr) == (basic.returncode, basic.stdout, basic.stderr)
    assert (off.returncode, off.stdout, off.stderr) == (default.returncode, default.stdout, default.stderr)
    report = command('run', source, '--opt=basic', '--opt-report', '--', '--opt=basic')
    assert report.returncode == 0 and report.stdout == off.stdout
    assert b'opt basic: fused=1' in report.stderr and b'inputs=[' in report.stderr and b'split=' in report.stderr
    for mode in ('off', 'basic'):
        binary = root / mode
        result = command('build', source, f'--opt={mode}', '-o', binary)
        assert result.returncode == 0 and result.stdout == result.stderr == b''
    assert leaf_calls(root / 'off') == 1
    assert leaf_calls(root / 'basic') == 0
    for args in [('run', source, '--opt=bogus'), ('build', source, '--opt-report'),
                 ('check', source, '--opt=basic')]:
        assert command(*args).returncode == 2
    source.write_text('fn main(){let x=1;println(missing(x*0));}')
    checked = command('check', source)
    for mode in ('off', 'basic'):
        result = command('run', source, f'--opt={mode}')
        assert result.returncode == checked.returncode == 1 and result.stderr == checked.stderr
    # Global JIT stays unsupported when basic optimization is selected.
    source.write_text('#global[jit]\nfn main(){println(1);}')
    assert b'global jit mode is not supported' in command('build', source, '--opt=basic').stderr
    source.write_text('fn leaf(x:Int)->Int{return x+1;} test fn ok(){assert(leaf(2)==3);}')
    a = command('test', source, '--opt=off')
    b = command('test', source, '--opt=basic')
    assert a.returncode == b.returncode == 0 and a.stdout == b.stdout and a.stderr == b.stderr == b''
    payload = b'alpha=one\nbeta=two\nempty=\n'
    data = root / 'entries.txt'
    data.write_bytes(payload)
    for args in ([], ['--', data]):
        a = command('run', ROOT / 'examples/key_values.xen', '--opt=off', *args, input=payload, cwd=root)
        b = command('run', ROOT / 'examples/key_values.xen', '--opt=basic', *args, input=payload, cwd=root)
        assert (a.returncode, a.stdout, a.stderr) == (b.returncode, b.stdout, b.stderr)
        assert a.returncode == 0 and a.stdout == b'alpha: one\nbeta: two\nempty: \n' and a.stderr == b''
# A read-before-write program detects missing initial-state restoration.
sys.path.insert(0, str(ROOT / 'tests/property'))
from grammar import Program
from props import run_program
initial = Program(files={
    'app.xen': 'fn main(){let s=read_text("state.txt");println(s);let mut f=open_write("state.txt");f.write(s+"changed");f.close();}',
    'state.txt': 'initial',
}, entry='app.xen', expected_stdout='initial\n', features=frozenset({'file'}))
result = run_program(initial)
assert result.status == 0 and result.stdout == initial.expected_stdout and result.stderr == ''
print('Optimization CLI, file restoration and decoded machine call tests passed')
