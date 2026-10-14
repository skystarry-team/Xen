# Structs and enums

Structs name fields that belong together. Enums name alternative forms a value can take. Save this as `types.xen`:

```xen
struct Task { title: String, done: Bool }
enum Priority { Normal, Urgent(Int) }

impl Task {
    fn label(&self) -> String {
        return if self.done { "done: " + self.title } else { "todo: " + self.title };
    }
}

fn main() {
    let task = Task { title: "read the guide", done: false };
    println(task.label());
    let priority = Priority.Urgent(2);
    println(match priority {
        Priority.Normal => "normal",
        Priority.Urgent(days) => "due in " + int_to_str(days),
    });
    let (number, label) = (42, "answer");
    println(label + ": " + int_to_str(number));
}
```

```console
$ xen run types.xen
todo: read the guide
due in 2
answer: 42
```

## Structs and methods

A `struct` declares field names and types. Supply every field exactly once when constructing a value; field order is free. Read with `task.title`. With `let mut task`, change a field using `task.done = true;`. Nested fields work too, as in `user.address.city`.

An `impl Task` block defines methods. A receiver of `&self` reads, `&mut self` changes, and `self` takes a value by the ordinary passing rules. A variable used for an `&mut self` call must be mutable. `task.label()` above is a method call. The [ownership chapter](ownership.md) explains explicitly creating references.

Structs cannot be compared with `==`; compare the relevant fields instead. Default fields and struct destructuring patterns are unavailable.

## Enums and match

Declare a form without data, such as `Priority.Normal`, or with data, such as `Priority.Urgent(2)`. Use a tuple payload such as `Urgent((Int, String))` when a variant needs several values.

`match` lists `pattern => result` arms. Cover every variant; `_` covers remaining values. An arm after a pattern that always matches is an error. All arms of a value-producing match must have the same result type. Names introduced by an arm are available only inside that arm. Match also handles numbers, booleans, strings, and tuples. Match guards are unavailable.

## Tuples

`(42, "answer")` has type `(Int, String)`. Read elements as `pair.0` and `pair.1`, or unpack them with `let (number, label) = pair;`. Nested tuples can be unpacked, and `_` discards an unwanted value. Destructuring assignment to existing variables is unavailable.

---

[Contents](README.md) · [Previous: Strings and collections](collections.md) · [Next: Reusing types](generics.md) · [한국어](../ko/types.md)
