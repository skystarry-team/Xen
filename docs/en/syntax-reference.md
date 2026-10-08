# Syntax reference

This page summarizes the syntax accepted by the current parser. Type and ownership
rules are explained on the linked reference pages; a construct appearing in this
grammar does not mean every type combination is valid.

## Source files and declarations

```text
source          = [module-declaration] { dependency-declaration }
                  [global-mode] { declaration } ;
module-declaration = "module" qualified-name ";" ;
dependency-declaration = ("import" | "use") qualified-name ["as" identifier] ";" ;
global-mode     = "#global" "[" mode { "," mode } "]" ;
mode            = "explc" | "jit" | "bb" ;
declaration     = struct | enum | impl | function ;
```

`module` is optional except when the entry file imports project modules, in which case
it must match the entry file's module path. Project dependencies use `import`;
toolchain dependencies use `use`. A global mode declaration is optional, appears at
most once before all declarations, and must be followed by a declaration on a new line.
Mode lists cannot be empty or repeat a mode. A function mode attribute must be followed
by its declaration on a new line. `jit` is supported in lexical `#scope[jit]` for experimental [scalar runtime compilation](jit.md);
global and function jit modes remain reserved.

```text
struct          = "struct" identifier [type-parameters] "{"
                    [field { "," field } [","]] "}" ;
enum            = "enum" identifier [type-parameters] "{"
                    [variant { "," variant } [","]] "}" ;
field           = identifier ":" type ;
variant         = identifier ["(" type ")"] ;
type-parameters = "<" identifier { "," identifier } ">" ;
impl            = "impl" [type-parameters] named-type "{" { method } "}" ;
function        = { function-mode } ["test"] "fn" identifier
                  [type-parameters] "(" [parameters] ")"
                  ["->" type] block ;
method          = { function-mode } "fn" identifier "(" receiver
                  { "," parameter } ")" ["->" type] block ;
receiver        = "self" | "&" ["mut"] "self" ;
function-mode   = "#!" "[" mode { "," mode } "]" ;
```

Function return types default to `Unit`. A `test fn` must be nongeneric, have no
parameters, and return `Unit`. A struct literal supplies every field exactly once.
An enum variant has at most one payload; use a tuple payload to carry multiple values.

## Types

```text
type            = scalar | named-type | generic-type | tuple-type
                  | reference-type | function-type ;
scalar          = "Int" | "Float" | "I8" | "U8" | "I16" | "U16"
                  | "I32" | "U32" | "I64" | "U64" | "F32" | "F64"
                  | "Bool" | "String" | "File" | "Unit" ;
generic-type    = "Vec" "<" type ">" | "Slice" "<" type ">"
                  | "Ptr" "<" type ">" | named-type "<" type { "," type } ">" ;
tuple-type      = "(" type "," type { "," type } ")" | "(" ")" ;
reference-type  = "&" ["mut"] type ;
function-type   = "fn" "(" [type { "," type }] ")" "->" type ;
named-type      = qualified-name ;
qualified-name  = identifier { "." identifier } ;
```

Function references, references to type parameters, reference-to-reference, and
references to `Unit` are rejected. `Int` and `Float` are compatibility names for
`I64` and `F64`. For generic inference and layout limits, see [language
basics](language-basics.md), [generics and enums](generics-enums-and-match.md), and
[supported features](status-and-limitations.md).

## Statements

```text
statement       = block | scope-block | let | assignment | expression-statement
                  | return | if-statement | while-loop | for-loop
                  | "break" [";"] | "continue" [";"] ;
block           = "{" { statement } "}" ;
scope-block     = "#scope" "[" mode { "," mode } "]" block ;
let             = "let" ["mut"] let-pattern [":" type] "=" expression [";"] ;
let-pattern     = identifier | "_" | "(" let-pattern "," let-pattern
                    { "," let-pattern } ")" ;
return          = "return" [expression] [";"] ;
if-statement    = "if" expression block ["else" (block | if-statement)] ;
while-loop      = "while" expression block ;
for-loop        = "for" pattern "in" expression block ;
assignment      = assignment-target "=" expression [";"] ;
assignment-target = identifier | identifier "." identifier
                    | identifier "." integer-literal
                    | expression "[" expression "]" | "*" expression ;
```

Tuple `let` patterns are irrefutable: only bindings, `_` and nested tuples are
accepted. The RHS is evaluated once; all bindings enter scope afterward. `mut`
applies to all bindings, and the annotation describes the whole RHS. Discarded
fields are cleaned up at declaration end. See [tuple bindings](language-basics.md#tuple-bindings).

Semicolons are optional after ordinary statements. The parser permits assignment to a
local, a direct struct field or tuple element of a local, a vector element, or a
dereference. Other assignment targets are rejected. `#scope` adds a capability to a
normal lexical block; local bindings do not escape the block.

An expression `if` is distinct from an `if` statement: it requires a final `else`, and
each branch contains exactly one expression with the same type.

## Expressions and precedence

From lowest to highest precedence, binary operators group as follows:

```text
range           = logical-or [".." logical-or] ;
logical-or      = logical-and { "||" logical-and } ;
logical-and     = equality { "&&" equality } ;
equality        = comparison { ("==" | "!=") comparison } ;
comparison      = additive { ("<" | "<=" | ">" | ">=") additive } ;
additive        = multiplicative { ("+" | "-") multiplicative } ;
multiplicative  = unary { ("*" | "/" | "%") unary } ;
unary           = ["-" | "!" | "*" | "&" ["mut"]] postfix ;
postfix         = primary { index | field | tuple-index | method-call | "?" } ;
index           = "[" expression "]" ;
field           = "." identifier ;
tuple-index     = "." integer-literal ;
method-call     = "." identifier "(" [arguments] ")" ;
```

The range operator is `Int`-only, half-open, and cannot be chained. Postfix `?` is
restricted to `Result` propagation. Expressions also include literals, names and calls,
generic calls, enum constructors, struct literals, vectors, tuples, expression `if`, and
`match`.

```text
primary         = literal | name | call | generic-call | enum-constructor
                  | struct-literal | vector-literal | tuple-literal
                  | if-expression | match-expression ;
call            = qualified-name "(" [arguments] ")" ;
generic-call    = qualified-name "<" type { "," type } ">" "(" [arguments] ")" ;
enum-constructor = enum-owner ["<" type { "," type } ">"] "." identifier
                  ["(" expression ")"] ;
enum-owner      = qualified-name ;
struct-literal  = named-type ["<" type { "," type } ">"] "{"
                  [field-initializer { "," field-initializer } [","]] "}" ;
field-initializer = identifier ":" expression ;
arguments       = expression { "," expression } ;
vector-literal  = "[" [arguments] "]" ;
tuple-literal   = "(" expression "," expression { "," expression } ")" | "(" ")" ;
if-expression   = "if" expression "{" expression "}" "else"
                  ("{" expression "}" | if-expression) ;
match-expression = "match" expression "{" [match-arm { "," match-arm } [","]] "}" ;
match-arm       = pattern "=>" (expression | match-block) ;
match-block     = "{" { statement } [expression] "}" ;
```

An expression `if` branch contains exactly one expression and no semicolon. A match
block can contain statements and an optional tail expression. Match arms are comma
separated and may end with a trailing comma.

For an enum constructor, the final name is the variant and the preceding qualified
name is its owner; generic arguments follow the owner, as in `Option<Int>.Some(value)`.

## Patterns

```text
pattern         = "_" | binding | literal | tuple-pattern | variant-pattern ;
tuple-pattern   = "(" pattern "," pattern { "," pattern } ")" ;
variant-pattern = qualified-name ["(" pattern ")"] ;
binding         = identifier ;
literal         = integer | float | string | "true" | "false" ;
```

Patterns are used by `match` and `for`. `match` must be exhaustive. Guards, struct
patterns, and destructuring assignment are not supported. `for` accepts bindings,
`_`, and nested tuple patterns.
