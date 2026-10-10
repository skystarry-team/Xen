# Modules and structs

## Project modules and toolchain modules

Project modules use `import`; compiler-bundled modules use `use`.

```text
project-root/
  app.xen
  guide/
    model.xen
    view.xen
```

`import guide.model;` loads `guide/model.xen` relative to the entry file's source root.
The imported file must declare exactly `module guide.model;`. An entry that imports a
project module must also declare its matching module path. A module can use its own
declarations unqualified and directly imported declarations by their full qualified
name. Transitive imports are not re-exported.

Use toolchain modules by qualified name, for example `use std.fs;` then
`std.fs.read(path)`, or `use core.intrinsics;` then
`core.intrinsics.size_of<T>()`. `import std.*`, `import core.*`, and project `use`
declarations are errors. Those namespaces are reserved for the toolchain. A single-file
program with only `use` declarations does not need a `module` declaration.

The bundled standard library is found relative to the Xen executable. The development
override `XEN_STDLIB_ROOT` names a directory containing `std/`; an invalid override is
an error and does not fall back to another location. `core.intrinsics` reports concrete
type size and alignment. `core.box` provides the qualified owning `Box<T>` type.

## Module aliases

```xen
use std.convert as convert;
import guide.model as model;
// convert.format_int(42), model.User { ... }, model.Role.Admin
```

An alias applies to the whole module and is local to the declaring file. Calls,
function values, types, constructors and enum patterns accept it; the original
qualified name remains available. Loading, cycles, namespaces and direct dependency
checks use the canonical module name. `use std.iter as iter;` also enables the
existing iterator factories.

Declare each dependency once. Duplicate aliases and aliases conflicting with a
module root, top-level declaration, builtin type or prelude type are rejected at
the alias declaration. Parameters, type parameters and local, `for`, `match` or
`let` pattern bindings cannot reuse an alias, including in unused declarations.
Field and method names can still use those spellings. `as` is contextual in a
dependency declaration and remains an ordinary identifier elsewhere.

## Named structs

Field order in a struct literal is free, but every field must appear exactly once.
Layout respects field size and alignment. A direct field can be updated through a
mutable local or mutable reference; consecutive struct and tuple fields can also
be updated, for example `user.address.city = "Busan"`. The RHS is evaluated before
the old field is dropped. A RHS that returns through `?` does not perform the final
replacement; effects already performed by that RHS are retained.

```xen
struct Address { city: String, zip: Int }
struct User { name: String, address: Address }

fn main() {
    let mut user = User {
        address: Address { zip: 123, city: "Seoul" },
        name: "Mina",
    };
    println(user.name + ": " + user.address.city);
    user.name = "Lee";
    println(user.name);
}
```

```console
$ compiler/dist/xen run struct.xen
Mina: Seoul
Lee
```

Primitive-only structs are copyable values. Structs containing `String`, `Vec`, or
other managed values follow recursive clone, move, and drop rules. Structs with
move-only fields are move-only. Struct equality, destructuring, default fields, and
index or temporary roots in nested field assignments are not supported.

## Methods and function values

An inherent method is declared in `impl Type { ... }` or `impl<T> Type<T> { ... }`.
Its receiver is `self`, `&self`, or `&mut self`; a method call supplies the receiver
implicitly. A mutable receiver requires a mutable owner or mutable reference.

Concrete named functions can be stored as values of type `fn(T1, T2) -> U`, passed,
returned, stored in locals or struct fields, and called indirectly. Generic function
declarations, built-ins, method values, and closures are not function values.

## Multi-file example

Save these files under the project root:

`app.xen`:

```xen
module app;
import guide.model;
import guide.view;

fn main() {
    let user = guide.model.User { name: "Mina", role: guide.model.Role.Admin };
    guide.view.show(user);
}
```

`guide/model.xen`:

```xen
module guide.model;
enum Role { Admin, Guest }
struct User { name: String, role: Role }
```

`guide/view.xen`:

```xen
module guide.view;
import guide.model;

fn show(user: guide.model.User) {
    let role = match user.role {
        guide.model.Role.Admin => "admin",
        guide.model.Role.Guest => "guest",
    };
    println(user.name + ": " + role);
}
```

```console
$ compiler/dist/xen check app.xen
$ compiler/dist/xen run app.xen
Mina: admin
```

Package manifests, visibility, re-exports, and an additional module search
path are not available.
