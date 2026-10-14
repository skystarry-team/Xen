# 복사·이동·참조

변수를 넘겨주거나 새 변수에 대입했을 때 원래 값을 계속 쓸 수 있는지는 타입에 따라 다릅니다. Xen에서는 다음 구분이 중요합니다.

| 값 | 다른 변수·함수에 값으로 전달하면 |
| --- | --- |
| 숫자·Bool 등 단순한 값 | 복사하며 원래 값도 사용 가능 |
| `String`, 복사 가능한 원소의 `Vec` | 내용이 독립적으로 복제되며 원래 값도 사용 가능 |
| `Box`, `File`, 이 값을 포함한 구조체·벡터 | 소유권이 이동하며 원래 값은 사용 불가 |

구조체·enum·튜플도 구성 요소의 규칙을 따릅니다. 모든 구성 요소가 복사·복제 가능하면 전체 값도 복사·복제되고, 이동 전용 값이 하나라도 포함되면 전체 값도 이동 전용입니다. 예를 들어 `String` 필드만 있는 구조체를 함수에 값으로 전달해도 원래 구조체를 계속 사용할 수 있습니다.

함수의 반환값은 호출한 쪽으로 전달됩니다. 다음을 `ownership.xen`으로 저장하세요.

```xen
fn append_copy(values: Vec<Int>) {
    let mut copy = values;
    copy.push(3);
    println(copy);
}

#![explc]
fn append_shared(values: &mut Vec<Int>) {
    values.push(3);
}

#![explc]
fn main() {
    let mut values = [1, 2];
    append_copy(values);
    println(values);
    append_shared(&mut values);
    println(values);
    let original = box(42);
    let transferred = original;
    println(transferred.into_inner());
}
```

```console
$ xen run ownership.xen
[1, 2, 3]
[1, 2]
[1, 2, 3]
42
```

`append_copy`에서는 독립적인 벡터를 변경하므로 호출한 쪽의 값은 그대로입니다. `append_shared`는 호출한 쪽의 벡터를 변경합니다. 이 차이를 알면 함수가 원본을 바꾸는지 판단할 수 있습니다.

## 참조로 원본 사용하기

`&value`는 읽기 참조, `&mut value`는 변경 참조를 만듭니다. 참조 매개변수 타입은 `&T`, `&mut T`이며 `*reference`로 값을 읽습니다. 변경 참조의 원본에는 `let mut`이 필요합니다.

직접 참조를 만드는 함수와 명시적 참조 매개변수가 있는 함수에는 예제처럼 선언 바로 앞 줄에 `#![explc]`를 적습니다. 특정 블록에서만 만들려면 `#scope[explc] { ... }`를 쓸 수 있습니다. 호출하는 함수의 표시가 호출자에게 적용되지는 않습니다.

읽기 참조가 사용 중이면 원본을 변경하거나 이동할 수 없습니다. 변경 참조가 사용 중이면 다른 참조나 원본으로 같은 값을 동시에 사용할 수 없습니다. 제한은 참조의 마지막 사용 이후 끝납니다. 다음 코드는 의도적인 오류입니다.

```xen
#![explc]
fn main() {
    let mut value = 1;
    let shared = &value;
    value = 2;
    println(*shared);
}
```

```sh
xen check borrow_error.xen
```

`while it is borrowed`라는 오류가 납니다. `value = 2;`를 `println(*shared);` 뒤로 옮기면 됩니다. 참조를 구조체 필드에 넣거나 반환할 수 없으며 임시값에 바로 참조를 만들 수도 없습니다. 먼저 지역 변수에 값을 저장하세요.

## Box로 값을 소유하기

`box(value)`는 값을 담는 `Box<T>`를 만듭니다. `as_ref()`로 읽고 `as_mut()`로 변경하며 `into_inner()`로 Box를 소비하고 값을 꺼냅니다. Box는 내부가 숫자여도 복사되지 않습니다. 예제의 `original`은 `transferred`로 이동한 뒤 사용할 수 없습니다.

서로 연결된 값에는 `Option<Box<Node>>`처럼 Box를 넣습니다. 다음을 `recursive_data.xen`으로 저장하세요.

```xen
struct Node { value: Int, next: Option<Box<Node>> }

fn sum(node: Node) -> Int {
    let rest = match node.next {
        Option.Some(next) => sum(next.into_inner()),
        Option.None => 0,
    };
    return node.value + rest;
}

fn main() {
    let last = Node { value: 20, next: Option<Box<Node>>.None };
    let first = Node { value: 10, next: Option.Some(box(last)) };
    println(sum(first));
}
```

```console
$ xen run recursive_data.xen
30
```

직접 `next: Node`로 선언하면 크기를 정할 수 없어 오류가 납니다. 재귀 구조에는 연결 고리마다 `Box`나 `Vec`가 필요합니다. Box 안에는 참조·Slice·Ptr를 넣을 수 없습니다.

## 값의 수명이 끝날 때

블록을 벗어나거나 `return`, `break`, `continue`, `?`로 나가면 소유한 값이 정리됩니다. 열린 `File`도 자동으로 닫힙니다. `panic`과 실행 오류는 프로그램을 즉시 종료하며 이 정상 정리 과정이 실행되지 않습니다. [오류 처리](error-handling.md)에서는 예상 가능한 실패를 값으로 다룹니다.

---

[목차](README.md) · [이전: 타입을 재사용하기](generics.md) · [다음: 없을 수 있는 값과 실패](error-handling.md) · [English](../en/ownership.md)
