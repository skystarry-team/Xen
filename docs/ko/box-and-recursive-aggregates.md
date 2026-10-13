# Box와 재귀 소유 구조

`Box<T>`는 heap allocation 하나와 그 안의 값 하나를 소유하는 move-only 타입이다.
`box(value)` 또는 `box<T>(value)`로 allocation을 명시한다. Box의 size와 alignment는
내부 타입에 관계없이 각각 8바이트다. Allocation 실패는 기존 managed allocation처럼
runtime error이며 unwind하지 않는다.

```xen
struct Node {
    value: Int,
    next: Option<Box<Node>>,
}

fn main() {
    let tail = Node { value: 2, next: Option<Box<Node>>.None };
    let head = Node { value: 1, next: Option<Box<Node>>.Some(box(tail)) };
    println(head.value);
}
```

직접·상호 inline layout 순환은 계속 거부한다. 모든 layout cycle에 `Box` 또는
`Vec` 경계가 있어야 하며, 다른 필드에 Box가 하나 있어도 inline 순환이 남으면
거부된다. 간접 경계 안의 타입도 유효해야 한다. 동일 concrete instance로 돌아오는
generic 재귀는 허용하지만 타입 인자가 계속 성장하는 재귀는 거부한다.

## 이동과 정리

Binding, assignment, by-value 인자와 반환은 Box의 소유권을 이동한다. 내부 값이
숫자여도 Box 자체는 복사하거나 암시적으로 clone하지 않는다. Box를 포함한
struct·enum·tuple·Vec도 move-only이며, 이동된 값은 다시 사용할 수 없다.

`owned.into_inner()`는 Box를 소비하고 내부 값을 반환하며 allocation을 해제한다.
내부 값을 drop하지 않으므로 반환받은 값이 새 owner가 된다. Box가 정상 scope 종료나
`return`·`break`·`continue`·`?`로 정리되면 내부 소유값도 재귀적으로 drop하고
allocation을 해제한다. 이동된 값과 비활성 enum payload는 중복 정리하지 않는다.

`box(value)`의 인자는 일반 값 전달 규칙을 따른다. String·clone 가능한 Vec는 기존처럼
복제되며, File·Box와 이를 포함한 aggregate는 이동한다. 반환받은 Box는 항상 move-only다.

## 내부 값 borrow

`as_ref()`와 `as_mut()`는 내부 값의 `&T`와 `&mut T`를 만든다. `explc` 안에서
`&*owned`와 `&mut *owned`로도 표현할 수 있다. Borrow에는 local owner 또는 그
필드가 필요하며 temporary Box는 빌릴 수 없다. Reference binding·전달은 기존
`explc` 규칙을 따른다.

```xen
#![explc]
fn main() {
    let mut owned = box(7);
    let shared = owned.as_ref();
    println(*shared);
    let mutable = owned.as_mut();
    *mutable = 9;
    println(owned.into_inner());
}
```

Mutable borrow에는 mutable owner 또는 `&mut` receiver가 필요하다. Shared reference를
통한 변경과 이동, 살아 있는 borrow 중 owner의 이동·교체·해제는 거부한다. 마지막
사용 뒤에는 owner를 다시 사용할 수 있다. 내부 field와 whole-value 교체도 기존
reference 규칙으로 처리한다.

첫 Box는 reference·Slice·Ptr을 내부에 저장하지 않는다. 빌린 Box 내부의 소유 field를
부분 이동하는 연산도 거부한다. 먼저 `into_inner()`로 소유값을 꺼내 local로 만든 뒤
필드를 이동한다. `*owned`의 값 취득은 clone 가능한 내부 값만 복제하며 move-only
내부 값에는 `into_inner()`를 사용한다. Enum을 소비 없이 관찰하려면
`match owned.as_ref()`와 ref payload binding을 사용한다. Reference 반환은 지원하지 않는다.

## 이름과 호환성

해당 파일에서 사용자 정의 `Box`를 선언하지 않았으면 `Box<T>`는 owning 타입이다.
기존 `struct Box<T> { value: T }`는 계속 inline 사용자 타입이며 간접 경계가 아니다.
사용자 함수나 local 함수 값이 `box`라는 이름이면 그 호출을 우선한다. Owning 생성자를
별도로 쓰거나 두 타입이 필요하면 `use core.box;` 뒤 `core.box.Box<T>`와 `core.box.new(value)`를
사용한다. Qualified identity는 항상 owning 타입이다.

```xen
use core.box;
struct Box<T> { value: T }

fn main() {
    let inline = Box<Int> { value: 3 };
    let owned: core.box.Box<Int> = core.box.new(8);
    println(inline.value);
    println(owned.into_inner());
}
```

[재귀 AST 실행 예제](../../examples/recursive_ast.xen)는 자식 expression을 Box로 소유하고
`into_inner()`와 `match`로 평가한다. Arena + NodeId도 계속 유효한 선택이다.
