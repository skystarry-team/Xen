# String과 Vec

## String

`String`은 UTF-8 문자 단위가 아닌 immutable byte sequence다. `len("é")`는 UTF-8 encoding의 길이인 `2`를 반환한다. String literal은 newline, tab, carriage return, double quote, backslash escape를 지원한다.

```xen
let text = "hello\n";
let label = "bytes: " + int_to_str(len(text));
println(label);
println(text == "hello\n");
```

`String + String`은 operand를 변경하거나 이동하지 않고 새 String을 만든다. embedded NUL을 포함한 모든 byte를 보존한다. indexing과 mutation은 지원하지 않는다.

`String.as_bytes()`는 local-only `Slice<U8>` view를 만들고 `Vec<U8>.into_string()`은
vector를 소비해 byte를 그대로 String으로 옮긴다. `use std.string;`은
`is_ascii_whitespace(byte)`와 `split_ascii_whitespace(text)`를 제공한다. 공백은
ASCII `0x09`~`0x0D`, `0x20`만 해당하며 연속·선행·후행 공백은 빈 token을 만들지
않는다. NUL과 `0x80` 이상 byte는 검증이나 변환 없이 token에 남는다.

`std.string.slice_bytes`는 범위를 검사해 소유 String을 복사하며 `find`·`contains`와
`split_byte`는 byte 검색·분해를 지원한다. [stdlib 계약](stdlib.md#byte-문자열-처리)을
따른다. String indexing·slicing 문법과 mutation은 여전히 지원하지 않는다.

## Vec

`Vec<T>`는 concrete sized element type을 받는다. 숫자 scalar, `Bool`, `Unit`,
`String`, `File`, concrete struct/enum과 중첩 Vec를 표현할 수 있다. reference,
`Slice`, `Ptr`, 미해결 type variable은 element로 사용할 수 없다.

```xen
let mut values: Vec<Int> = [];
values.push(10);
values.push(20);
values[0] = 11;
values.set(1, 21);
println(values.get(0));
println(values.len());
println(values.pop());
```

빈 literal은 element type을 추론할 수 없으므로 annotation이 필요하다. 음수 또는 범위를 벗어난 index와 빈 Vec의 `pop()`은 runtime error다. `set`, `push`, `pop`에는 mutable receiver가 필요하고 `len`, `get`은 shared reference에서도 호출할 수 있다. move-only element는 `get`/index로 복제할 수 없고 `push`/`set`/`pop`에서 ownership을 이동한다.

storage는 element의 실제 size/alignment에서 계산한 packed stride를 사용한다. String,
struct, enum, tuple과 중첩 Vec는 조회·Vec 복제 때 재귀적으로 deep clone되며 교체와
scope 종료 때 owned field가 정확히 한 번 drop된다. `Vec<File>`과 File을 포함한
aggregate는 move-only다.

## Slice

`Vec<T>.as_slice()`와 `Vec<T>.slice(start, end)`는 read-only `Slice<T>`를 만든다.
Slice는 `len()`, `get(index)`, indexing과 전역 `len(slice)`를 지원한다. 범위는
`0 <= start <= end <= len`이어야 한다. Slice가 마지막으로 사용되기 전에는 source
Vec를 변경하거나 이동할 수 없다. Slice local·direct function parameter와 local struct
field를 지원하며 aggregate 복사·field 교체도 원래 owner의 borrow를 보존한다.
Slice 및 이를 포함한 aggregate의 반환·owner 밖 escape와 Vec 저장은 허용하지 않는다. Slice도
같은 packed stride와 clone 규칙을 사용하며 move-only element 조회는 compile-time error다.

| 호출 | 결과/동작 |
| --- | --- |
| `zeros(count)` | 0으로 채운 새 `Vec<Int>` |
| `repeat(value, count)` | `Int` 또는 `Float`을 반복한 새 Vec |
| `read_text(path)` | 파일의 모든 byte를 새 String으로 읽음 |
| `read_ints(path)` | whitespace로 구분된 decimal Int를 새 Vec로 읽음 |
| `read_floats(path)` | whitespace로 구분된 decimal Float를 새 Vec로 읽음 |

`zeros`와 `repeat`의 음수 길이는 runtime error이며 0 길이는 빈 Vec를 반환한다. `read_ints`/`read_floats`는 ASCII space, tab, CR, LF를 separator로 사용한다. 경로, 숫자, allocation, file 오류는 source location을 포함해 stderr에 기록되고 status 1로 종료된다.

Vec equality는 숫자, Bool, String과 그 중첩 Vec에 재귀적으로 제공된다. File 및
struct/enum element는 compile-time error다. Vec 출력은 기존 `Vec<Int>`와
`Vec<Float>` 범위를 유지한다.

## 공유 element 접근과 consuming iteration

Explc에서 `let item = &values[index];`는 File·Box를 포함한 Vec element를 clone 없이
대여한다. Bounds를 검사하며 마지막 사용까지 다른 index의 변경도 포함한 Vec mutation과
move를 금지한다. Mutable element reference는 지원하지 않는다. String.as_bytes는
stable String field·검사된 &String에서도 view를 만들며 원본 loan을 유지한다.

`use std.iter;` 뒤에 values.into_iter는 Vec을 소비하고 원래 순서로 owned element를
반환한다. Vec.swap(left,right)는 clone/drop 없이 교환한다. Vec.replace(index,value)는
길이를 유지하고 이전 owned element를 반환하며, 반환값을 버리면 정상 cleanup이 정리한다.
