# Bootstrap Snapshots

The current implementation is developed in the parent `src/` directory. The two snapshots below are independent, single-file snapshots preserved to demonstrate that the next language subset can be implemented using only the preceding subset's syntax.

| File | Syntax Used for Implementation | Compilation Capabilities |
| --- | --- | --- |
| `scalar.xen` | Int, Bool, functions, bb | Initial scalar subset |
| `records.xen` | Same scalar subset | Scalar values and POD structs |

The bootstrap sequence is `OCaml stage0 → scalar → records → driver → current sources`.

This path must work without directly compiling the current sources using the existing compiler. The snapshots are not updated to reflect changes to the current implementation. If future language features extend beyond the existing bootstrap subset, a new snapshot will be preserved separately.

`driver.xen` is not a frozen snapshot. It is a stdin-only entry point that uses the current `src/` implementation. It is assembled using `assemble.sh bootstrap/driver.xen`.

Executables produced by the historical records compiler lack the initial stack storage area required by the CLI. This entry point runs the current backend to produce the first CLI executable with the new ELF startup convention.

It introduces no new syntax or asm features and does not modify the historical snapshots.