# Diagnostics and runtime errors

Compiler errors are written to stderr in this form:

```text
file.xen:line:column: error: message
file.xen:line:column: note: additional context
help: suggested action
```

Locations refer to the beginning of a source span. A compiler error exits 1. The
checker reports the source name involved in borrow conflicts, partial moves, and
capability violations rather than an internal compiler identifier.

## Compile-time error: moved value

```xen
fn take(file: File) {}

fn main() {
    let file = open_read("input.txt");
    take(file);
    println(file.is_open());
}
```

```console
$ compiler/dist/xen check moved.xen
moved.xen:6:13: error: use of moved File 'file' (or uninitialized value)
moved.xen:5:10: note: value moved here
$ echo $?
1
```

`File` is move-only. After passing it to `take`, the caller cannot use the old binding.
Use a returned owner or keep using the binding in the function that owns it.

## Runtime error

`panic(message)` writes the supplied message to stderr and exits 1. It does not include
a source location. Runtime checks such as vector bounds failures include a source
location. Runtime errors do not unwind the stack:

```xen
fn main() {
    panic("invalid input");
}
```

```console
$ compiler/dist/xen run panic.xen
invalid input
$ echo $?
1
```

`panic`, failed assertions, invalid vector bounds, division by zero, and legacy `File`
operation failures use runtime errors. New standard-library file and output APIs return
`Result` for recoverable I/O failures. See [file APIs](file.md).
