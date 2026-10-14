# 문자열과 컬렉션

여러 값을 순서대로 보관하려면 `Vec<T>`를 사용합니다. 텍스트를 나누는 함수는 `std.string`에서 찾을 수 있습니다. 다음을 `collections.xen`으로 저장하세요.

```xen
use std.string as text;

fn main() {
    let words = text.split_ascii_whitespace("red green blue");
    println(words.get(1));
    println("한".len());
    let mut scores: Vec<Int> = [];
    scores.push(10);
    scores.push(20);
    scores[0] = 11;
    println(scores);
    let view = scores.slice(0, 2);
    println(view.get(1));
}
```

```console
$ xen run collections.xen
green
3
[11, 20]
20
```

## 문자열

`String`은 바꿀 수 없는 바이트열입니다. `+`로 이어 붙이면 새 문자열이 만들어집니다. `len()`은 글자 수가 아닌 바이트 수입니다. 예제의 `"한"`은 UTF-8에서 3바이트입니다. 글자 단위 색인이나 문자열 변경 문법은 없습니다.

큰따옴표 안에서는 `\n`, `\t`, `\r`, `\"`, `\\`를 사용할 수 있습니다. 문자열은 UTF-8인지 자동으로 검사하지 않으므로 파일의 원래 바이트를 보존합니다. 바이트 위치로 자르는 작업은 한 글자의 중간을 자를 수 있습니다.

`std.string.split_ascii_whitespace`는 공백·탭·줄바꿈 등 ASCII 공백을 기준으로 나누고 빈 항목을 만들지 않습니다. `split_byte(text, u8(44))`는 쉼표 바이트 하나를 기준으로 나누며 빈 항목도 남깁니다. 이는 따옴표를 해석하는 CSV 파서가 아닙니다. 검색과 부분 추출은 [표준 라이브러리](stdlib.md)를 참고하세요.

## 벡터

`[10, 20]`처럼 만들고, 빈 벡터에는 `Vec<Int>`처럼 원소 타입을 적습니다. 색인은 0부터 시작합니다.

| 작업 | 쓰는 방법 |
| --- | --- |
| 원소 수 | `scores.len()` |
| 읽기 | `scores[0]` 또는 `scores.get(0)` |
| 추가·변경 | `scores.push(30)`, `scores.set(0, 12)` |
| 마지막 원소 꺼내기 | `scores.pop()` |
| 이전 원소를 반환하며 교체 | `scores.replace(0, 12)` |
| 두 원소 교환 | `scores.swap(0, 1)` |

변경 작업에는 `let mut`이 필요합니다. 범위 밖 접근이나 빈 벡터의 `pop()`은 실행 오류입니다. 접근 전에 길이를 확인하세요. `get()`도 실패를 `Option`으로 돌려주지 않습니다. 벡터에는 서로 같은 타입의 값만 넣습니다. 참조·Slice·Ptr는 벡터 원소로 사용할 수 없습니다.

`Box`·`File`처럼 이동 전용인 원소는 색인이나 `get()`으로 복사할 수 없습니다. `pop()`, `replace()`, `.into_iter()`로 소유권을 꺼내거나, `explc`가 있는 함수에서 `&values[index]`로 읽기 참조를 만드세요. 원소 참조를 사용하는 동안에는 벡터 전체를 변경하거나 이동할 수 없습니다. 변경 가능한 원소 참조는 지원하지 않습니다.

`String.as_bytes()`는 읽기 전용 `Slice<U8>`를 만듭니다. `Vec<U8>.into_string()`은 벡터를 소비하고 바이트를 문자열로 넘기며 UTF-8 검사는 하지 않습니다.

## 읽기 전용 구간

`as_slice()`는 전체, `slice(start, end)`는 끝을 제외한 구간을 보여 주는 `Slice<T>`를 만듭니다. 원소를 복사해 새 벡터를 만드는 작업이 아닙니다. 구간을 마지막으로 사용하는 시점까지 원래 벡터를 바꾸거나 이동할 수 없습니다. 구간을 함수 밖으로 반환하거나 벡터에 넣을 수 없으며, 변경 가능한 구간은 지원하지 않습니다. 오래 보관할 값이 필요하면 원소를 새 벡터로 복사하세요.

## 반복과 변환

범위로 색인을 반복하거나, `use std.iter;`를 적고 `.iter()`를 사용합니다. `for value in values`만으로 벡터를 자동 반복하지 않습니다.

```xen
use std.iter;

fn doubled(value: Int) -> Int {
    return value * 2;
}

#![explc]
fn over_two(value: &Int) -> Bool {
    return *value > 2;
}

fn main() {
    let values = [1, 2, 3];
    for value in values.iter().map(doubled).filter(over_two) {
        println(value);
    }
}
```

```console
$ xen run iterators.xen
4
6
```

`.map`은 항목을 변환하고 `.filter`는 조건에 맞는 항목을 남깁니다. 실제 반복할 때 함수가 실행됩니다. 콜백에는 이름 있는 함수를 전달하세요. `.enumerate()`는 0부터의 색인과 값을 튜플로 만듭니다.

벡터와 Slice의 `.iter()`는 복사·복제 가능한 원소에만 사용할 수 있습니다. `.iter()`가 사용하는 원본은 반복을 마칠 때까지 바꿀 수 없습니다. `.into_iter()`는 벡터를 넘겨받아 원소를 순서대로 꺼냅니다. `Box`·`File`처럼 복사할 수 없는 원소에는 `.into_iter()`를 사용하거나 앞에서 설명한 원소 참조로 읽으세요. `.into_iter()`에 넘긴 원래 벡터는 다시 쓸 수 없습니다. [복사와 이동](ownership.md)을 참고하세요.

---

[목차](README.md) · [이전: 함수와 반복](control-flow.md) · [다음: 구조체와 enum](types.md) · [English](../en/collections.md)
