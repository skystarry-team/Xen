# Your first program

This chapter prints one line and then turns the program into an executable you can run directly.

## Prepare Xen

You need Xen on Linux. Follow the [installation guide](../compiler-build/en/build.md). Add the distribution's `bin` directory to `PATH` to use `xen` from any directory. Commands in this guide assume `xen` is available on your path.

From an extracted distribution, you can replace `xen` with `./bin/xen`. From the repository root, use `compiler/dist/xen`. Keep `bin` and `stdlib` together when moving a distribution.

```sh
xen version
```

## Write a file

Create `hello.xen` in a working directory and save this code:

```xen
fn main() {
    println("Hello, Xen!");
}
```

`fn main()` is where execution begins. Statements go inside braces. `println` prints a value followed by a newline. Put strings in double quotes and end statements with `;`.

Run this command from the directory containing your file:

```console
$ xen run hello.xen
Hello, Xen!
```

## Check and build

```sh
xen check hello.xen
xen build hello.xen -o hello
./hello
```

`check` finds errors without running the program. Success produces no output. `build` creates an executable. `./hello` also prints `Hello, Xen!`; running that file does not require Xen.

If Xen cannot find your file, check the working directory and filename. Executables need a compatible Linux system. macOS and Windows are unsupported.

## Try a change

Replace the greeting with your own name and run it again. The next chapter gives names to values and uses them in calculations.

---

[Contents](README.md) · [Next: Variables and values](language-basics.md) · [한국어](../ko/getting-started.md)
