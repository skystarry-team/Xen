# Low-level `bb` capability

`bb` is a lexical capability for typed raw memory and Linux syscalls. It is not an
optimization mode or an IR basic block. A function's capability combines file-level
`#global[...]`, function-level `#![...]`, and enclosing `#scope[...]` declarations.
Capabilities do not cross imports or value-only calls. `#scope[jit]` is a separate experimental [scalar runtime compiler](jit.md);
global/function `jit` modes remain reserved.

`#scope[bb] { ... }` adds the capability to an ordinary lexical block. Locals and the
capability do not escape that block; move and cleanup rules remain the same.

```xen
struct Pair { tag: U8, value: I64 }

fn main() {
    #scope[bb] {
        let pointer: Ptr<Int> = raw_alloc_int(2);
        raw_store_int(pointer, 0, 21);
        raw_store_int(pointer, 1, 21);
        println(raw_load_int(pointer, 0) + raw_load_int(pointer, 1));
        raw_free_int(pointer);

        let pair = raw_alloc<Pair>(1);
        raw_store(pair, 0, Pair { tag: u8(7), value: 35 });
        println(raw_load(pair, 0).tag + u8(0));
        raw_free(pair);
    }
}
```

```console
$ compiler/dist/xen run memory.xen
42
7
```

## Pointer API

`Ptr<T>` is a 16-byte copyable descriptor containing an address and element count. It
does not own or automatically free the allocation. `raw_alloc<T>(count)` allocates
zeroed elements; `raw_load`, `raw_store`, and `raw_free` check or use that descriptor's
bounds. The compatibility functions `raw_alloc_int`, `raw_load_int`,
`raw_store_int`, and `raw_free_int` operate on `Int` (`I64`). `ptr_addr` extracts an
address word as `I64` for syscall use.

`T` must be a numeric scalar, `Bool`, or a named POD struct recursively containing only
those fields. Generic concrete POD structs are allowed. Managed values, references,
tuples, enums, `Unit`, and types requiring drop are rejected. Element stride is the
aligned size of `T`, including struct padding.

Descriptor copies share one allocation. Double free, access after free, and leaks are
the responsibility of the `bb` code. Zero-element allocation returns a null
descriptor. Pointer arithmetic, address-to-pointer conversion, and arbitrary address
dereferencing are not available.

## Linux syscalls

`syscall0` through `syscall6` accept a syscall number and up to six `I64` arguments,
evaluated left to right, and return the raw Linux result as `I64`. The ABI uses
`rax/rdi/rsi/rdx/r10/r8/r9`. Negative kernel errno values are not converted to
`Result`; wrappers that need recoverable errors belong in Xen standard-library code.
The only target is Linux x86-64.

## Capability error

```xen
fn main() {
    let pointer = raw_alloc_int(1);
    raw_free_int(pointer);
}
```

```console
$ compiler/dist/xen check raw_error.xen
raw_error.xen:2:19: error: raw_alloc_int requires #![bb]
raw_error.xen:1:1: note: enclosing function or scope does not provide bb
help: add bb only to the function or #scope that needs this operation
$ echo $?
1
```

Wrap the operation in `#scope[bb]` or place it in a function whose lexical capability
includes `bb`.
