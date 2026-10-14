# Working with multiple files

As a program grows, keep related types and functions in separate files. Create these three files and run commands from the directory containing `app.xen`:

```text
project/
  app.xen
  shop/
    model.xen
    view.xen
```

`app.xen`:

```xen
module app;
import shop.model as model;
import shop.view as view;

fn main() {
    let item = model.Item { name: "tea", price: 3 };
    view.show(item);
}
```

`shop/model.xen`:

```xen
module shop.model;

struct Item { name: String, price: Int }
```

`shop/view.xen`:

```xen
module shop.view;
import shop.model as model;

fn show(item: model.Item) {
    println(item.name + ": " + int_to_str(item.price));
}
```

```console
$ xen check app.xen
$ xen run app.xen
tea: 3
```

The same files are in the [modules example directory](../../examples/modules/app.xen). From the repository, run `xen run examples/modules/app.xen`.

## Imports and names

`import shop.model;` loads `shop/model.xen` below the entry file's directory. Each file declares a `module` matching its path. An entry file importing project modules also needs a declaration such as `module app;`. Mismatched names are errors.

`as model` provides a short name local to the importing file. Without an alias, use the full name `shop.model.Item`. Indirectly imported modules are not automatically available; import each module you use directly. Choose aliases that do not conflict with variables, types, or functions.

## Standard library

Bring in the standard library with `use std.string;` or `use std.string as text;`. Use `import` for project files and `use` for bundled `std.*` and `core.*` modules. Do not place project files under the reserved names `std` or `core`. A single file using only standard-library modules does not need a `module` declaration.

Package manifests, visibility declarations, and module re-exports are unavailable. Avoid import cycles. Put shared types in a separate file both modules can import.

---

[Contents](README.md) · [Previous: Missing values and errors](error-handling.md) · [Next: Build a word counter](tutorial.md) · [한국어](../ko/modules.md)
