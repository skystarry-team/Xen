# SPDX-License-Identifier: MIT OR Apache-2.0
"""Mach-O prototype structure and independently verified code page signatures.

These checks do not run macOS or establish Darwin backend execution support.
"""
import hashlib
from pathlib import Path
import struct
import platform
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
FIXTURE = REPO / "_build/default/tests/mach_o_fixture.exe"


class MachOTests(unittest.TestCase):
    def test_foreign_import_bind_stream(self):
        with tempfile.TemporaryDirectory(prefix="xen-darwin-import-") as temp:
            source = Path(temp) / "app.xen"
            source.write_text('''
#![bb]
fn main(){assert(extern_call<I32>("/usr/lib/libSystem.B.dylib","abs",i32(-42))==i32(42));
extern_call<Unit>("/tmp/libxen-ffi.dylib","mark_exit");}
''')
            output = Path(temp) / "app"
            result = subprocess.run([str(REPO / "_build/default/tests/darwin_fixture.exe"),
                                     str(source), str(output)], capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            image = output.read_bytes()
            commands = {}
            dylibs = []
            at = 32
            for _ in range(struct.unpack_from("<I", image, 16)[0]):
                command, size = struct.unpack_from("<II", image, at)
                commands[command] = at
                if command == 0xc:
                    name_offset = struct.unpack_from("<I", image, at+8)[0]
                    dylibs.append(image[at+name_offset:at+size].split(b"\0", 1)[0])
                at += size
            self.assertEqual(at, 32+struct.unpack_from("<I", image, 20)[0])
            self.assertEqual(dylibs, [b"/usr/lib/libSystem.B.dylib", b"/tmp/libxen-ffi.dylib"])
            info = struct.unpack_from("<10I", image, commands[0x80000022]+8)
            bind_offset, bind_size = info[2:4]
            bind = image[bind_offset:bind_offset+bind_size]
            self.assertTrue(bind.startswith(b"\x11\x40_abs\0\x51\x73\x18\x90"), bind)
            self.assertIn(b"\x12\x40_mark_exit\0\x51\x73\x20\x90", bind)
            self.assertEqual(bind[-1:], b"\0")
            signature_offset = struct.unpack_from("<I", image, commands[0x1d]+8)[0]
            self.assertLess(bind_offset+bind_size, signature_offset)

    def test_rebuild_replaces_signed_image_and_preserves_output_on_failure(self):
        fixture = REPO / "_build/default/tests/darwin_fixture.exe"
        with tempfile.TemporaryDirectory(prefix="xen-darwin-rebuild-") as temp:
            workspace = Path(temp) / "space 한글"
            workspace.mkdir()
            source = workspace / "app.xen"
            output = workspace / "app"
            previous_inode = None
            previous_image = None
            for message in ("first", "second", "third"):
                source.write_text(f'fn main(){{println("{message}");}}', encoding="utf-8")
                result = subprocess.run([str(fixture), str(source), str(output)],
                                        capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                inode = output.stat().st_ino
                self.assertNotEqual(inode, previous_inode, "signed image was modified in place")
                image = output.read_bytes()
                self.assertEqual(image[:4], b"\xcf\xfa\xed\xfe")
                self.assertNotEqual(image, previous_image)
                self.assertTrue(output.stat().st_mode & 0o111)
                previous_inode, previous_image = inode, image
            # Force the final rename to fail after the temporary image is written.
            # The existing destination and directory contents must survive intact.
            destination = workspace / "existing-directory"
            destination.mkdir()
            sentinel = destination / "keep"
            sentinel.write_bytes(b"original")
            before = set(workspace.iterdir())
            failure = subprocess.run([str(fixture), str(source), str(destination)],
                                     capture_output=True, timeout=30)
            self.assertNotEqual(failure.returncode, 0)
            self.assertEqual(sentinel.read_bytes(), b"original")
            self.assertEqual(output.read_bytes(), previous_image)
            self.assertEqual(set(workspace.iterdir()), before, "temporary image leaked")

    def test_darwin_adapter_carry_arguments_stack_and_leaf_return(self):
        runner = [] if platform.system() == "Linux" and platform.machine() in ("aarch64", "arm64") else [shutil.which("qemu-aarch64")]
        if runner and runner[0] is None:
            self.skipTest("adapter execution needs Linux ARM64 or qemu-aarch64")
        with tempfile.TemporaryDirectory(prefix="xen-darwin-adapter-") as temp:
            output = Path(temp) / "adapter"
            generated = subprocess.run([str(REPO / "_build/default/tests/darwin_abi_fixture.exe"), str(output)], capture_output=True, timeout=30)
            self.assertEqual(generated.returncode, 0, generated.stderr)
            result = subprocess.run([*runner, str(output)], capture_output=True, timeout=30)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"darwin-adapter\n", b""))

    def test_checked_xen_ir_emits_darwin_pie_traps(self):
        with tempfile.TemporaryDirectory(prefix="xen-darwin-ir-") as temp:
            source = Path(temp) / "app.xen"
            source.write_text('''
struct Node{label:String,child:Option<Box<Node>>}
#![bb]
fn main(){println(arg_count());println(arg(0));println(1.5);
 let tree=box(Node{label:"ap"+"ple",child:Option.Some(box(Node{label:"child",child:Option<Box<Node>>.None}))});
 let mut numbers=[1,2,3];numbers.push(4);println(numbers);
 let p=raw_alloc<F64>(2);raw_store(p,1,-0.0);println(raw_load(p,1));raw_free(p);
 let mut file=open_write("darwin-fixture.tmp");file.write(tree.as_ref().label);file.close();
 println(read_text("darwin-fixture.tmp"));println(read_ints("integers"));println(read_floats("floats"));
 println(syscall0(20));}
''')
            output = Path(temp) / "app"
            result = subprocess.run([str(REPO / "_build/default/tests/darwin_fixture.exe"),
                                     str(source), str(output)], capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            image = output.read_bytes()
            self.assertEqual(struct.unpack_from("<4I", image), (0xfeedfacf, 0x100000c, 0, 2))
            self.assertEqual(struct.unpack_from("<I", image, 24)[0], 0x200085)
            at = 32
            code = None
            for _ in range(struct.unpack_from("<I", image, 16)[0]):
                command, size = struct.unpack_from("<II", image, at)
                if command == 0x19 and image[at+8:at+24].rstrip(b"\0") == b"__TEXT":
                    section = struct.unpack_from("<16s16s2Q8I", image, at+72)
                    code = image[section[4]:section[4]+section[3]]
                at += size
            self.assertIsNotNone(code)
            words = [word[0] for word in struct.iter_unpack("<I", code)]
            self.assertNotIn(0xd4000001, words)  # Linux svc #0
            self.assertGreater(words.count(0xd4001001), 10)  # Darwin svc #0x80
            self.assertGreater(sum(word & 0x9f000000 == 0x90000000 for word in words), 10)
            self.assertTrue(output.stat().st_mode & 0o111)

    def test_pie_segments_entry_and_page_signature(self):
        with tempfile.TemporaryDirectory(prefix="xen-mach-o-") as temp:
            for architecture, cpu, subtype, page in (("aarch64", 0x100000c, 0, 16384),
                                                      ("x86_64", 0x1000007, 3, 4096)):
                with self.subTest(architecture=architecture):
                    path = Path(temp) / architecture
                    result = subprocess.run([str(FIXTURE), architecture, str(path)], capture_output=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    image = path.read_bytes()
                    header = struct.unpack_from("<8I", image)
                    self.assertEqual(header[:4], (0xfeedfacf, cpu, subtype, 2))
                    self.assertEqual(header[6:], (0x200085, 0))
                    offset = 32
                    commands = []
                    segments = []
                    for _ in range(header[4]):
                        command, size = struct.unpack_from("<II", image, offset)
                        self.assertGreaterEqual(size, 8)
                        self.assertEqual(size % 8, 0)
                        self.assertLessEqual(offset+size, 32+header[5])
                        commands.append((command, offset, size))
                        if command == 0x19:
                            name, address, extent, fileoff, filesize, maximum, initial, sections, flags = struct.unpack_from("<16s4Q4I", image, offset+8)
                            name = name.rstrip(b"\0").decode()
                            self.assertEqual(address % page, 0)
                            self.assertEqual(fileoff % page, 0)
                            self.assertEqual(extent % page, 0)
                            self.assertLessEqual(filesize, extent)
                            self.assertLessEqual(fileoff+filesize, len(image))
                            self.assertEqual(maximum, initial)
                            self.assertFalse(initial & 2 and initial & 4)
                            self.assertEqual(size, 72+80*sections)
                            self.assertEqual(flags, 0)
                            for i in range(sections):
                                section = struct.unpack_from("<16s16s2Q8I", image, offset+72+80*i)
                                self.assertEqual(section[1].rstrip(b"\0").decode(), name)
                                self.assertEqual(section[2]-address, section[4]-fileoff)
                                self.assertLessEqual(section[2]+section[3], address+extent)
                                self.assertLessEqual(section[4]+section[3], fileoff+filesize)
                                self.assertEqual(section[4] % (1 << section[5]), 0)
                                self.assertEqual(section[6:8], (0, 0))
                            segments.append((name, address, extent, fileoff, filesize, initial))
                        offset += size
                    self.assertEqual(offset, 32+header[5])
                    self.assertEqual([s[0] for s in segments], ["__PAGEZERO", "__TEXT", "__RODATA", "__DATA", "__LINKEDIT"])
                    self.assertEqual(segments[0][1:], (0, 0x100000000, 0, 0, 0))
                    self.assertEqual([s[5] for s in segments], [0, 5, 1, 3, 1])
                    for left, right in zip(segments, segments[1:]):
                        self.assertLessEqual(left[1]+left[2], right[1])
                    by_kind = {kind: at for kind, at, _ in commands}
                    entry, stack = struct.unpack_from("<QQ", image, by_kind[0x80000028]+8)
                    self.assertGreaterEqual(entry, 32+header[5])
                    self.assertLess(entry, segments[1][4])
                    self.assertEqual(stack, 0)
                    for command, prefix, wanted in ((0xe, 12, b"/usr/lib/dyld"),
                                                    (0xc, 24, b"/usr/lib/libSystem.B.dylib")):
                        at = by_kind[command]
                        self.assertEqual(struct.unpack_from("<I", image, at+8)[0], prefix)
                        self.assertEqual(image[at+prefix:].split(b"\0", 1)[0], wanted)
                    self.assertEqual(struct.unpack_from("<4I", image, by_kind[0x32]+8),
                                     (1, 0xf0000, 0xf0000, 0))
                    signature_offset, signature_size = struct.unpack_from("<II", image, by_kind[0x1d]+8)
                    self.assertEqual(signature_offset % 16, 0)
                    self.assertEqual(signature_offset+signature_size, len(image))
                    self.assertEqual(struct.unpack_from(">5I", image, signature_offset),
                                     (0xfade0cc0, signature_size, 1, 0, 20))
                    directory = signature_offset+20
                    magic, length, version, flags, hash_offset, identifier, special, slots, limit = struct.unpack_from(">9I", image, directory)
                    self.assertEqual((magic, length, version, flags), (0xfade0c02, signature_size-20, 0x20400, 2))
                    self.assertEqual((special, limit, slots), (0, signature_offset, (signature_offset+4095)//4096))
                    self.assertEqual(image[directory+36:directory+40], bytes((32, 2, 0, 12)))
                    self.assertEqual(image[directory+identifier:].split(b"\0", 1)[0], b"org.xen.generated")
                    self.assertEqual(struct.unpack_from(">3Q", image, directory+64), (0, segments[1][4], 1))
                    self.assertEqual(hash_offset+slots*32, length)
                    for i in range(slots):
                        actual = image[directory+hash_offset+32*i:directory+hash_offset+32*(i+1)]
                        expected = hashlib.sha256(image[i*4096:min((i+1)*4096, limit)]).digest()
                        self.assertEqual(actual, expected)
                    # Header/load-command bytes and actual code are sealed too.
                    changed = bytearray(image[:min(4096, limit)])
                    changed[0] ^= 1
                    self.assertNotEqual(hashlib.sha256(changed).digest(), image[directory+hash_offset:directory+hash_offset+32])
                    again = Path(temp) / (architecture+"-again")
                    subprocess.run([str(FIXTURE), architecture, str(again)], check=True)
                    self.assertEqual(again.read_bytes(), image)


if __name__ == "__main__":
    unittest.main(verbosity=2)
