# 소유권과 reference

## Managed value

`String`과 `Vec`는 compiler가 수명을 관리한다. binding, 함수 경계, temporary와
scope 종료 시점에 필요한 clone, move, drop을 compiler가 삽입한다. 비어 있거나 이미
이동된 descriptor의 drop은 아무 동작도 하지 않는다.

각 lexical block의 owned local은 정상 종료 시 선언 역순으로 drop된다. `return`은
활성 함수 scope 전체를, `break`와 `continue`는 대상 loop body까지의 활성 scope를
inner-first 순서로 정리한다. managed field를 가진 struct도 같은 규칙으로 재귀
정리된다. runtime error와 `panic`에는 unwind가 없다.

Clone 가능한 String·Vec·managed struct/enum은 함수 mode와 관계없이 by-value 전달, binding,
대입에서 clone한다. 함수 반환은 결과 ownership을 caller로 이동한다. `explc`는
reference 연산 권한일 뿐 managed ownership 정책을 바꾸지 않는다.

```xen
#![explc]
fn consume(value: String) {}

fn main() {
    let value = "owned";
    consume(value);
    println(value); // valid: consume received a clone
}
```

## File ownership

`File`은 함수 mode와 관계없이 항상 move-only다. clone이 없으며 binding, assignment,
by-value argument, return에서 ownership이 이동한다. 살아 있는 File이 scope를 벗어나면
자동으로 닫힌다.

File assignment는 새 값을 먼저 준비한 다음 기존 File을 닫고 ownership을 교체한다.
명시적으로 `close()`한 File이나 이동된 File의 자동 drop은 no-op이다.

## Raw pointer

`Box<T>`는 Ptr과 달리 allocation과 내부 값을 단독 소유한다. 항상 move-only이며
scope cleanup에서 내부 값과 allocation을 정리한다. Borrow와 consuming extraction은
[Box 문서](box-and-recursive-aggregates.md)를 따른다.

`Ptr<T>`는 managed/owned 값이 아니다. 대입과 by-value 함수 전달은 descriptor를
복사하며 scope 종료 시 자동 해제하지 않는다. `raw_free_int` 호출과 복사본의 수명
관리는 `#![bb]` 코드가 직접 책임진다.

## Reference

Reference 생성과 reference parameter 선언·전달에는 현재 lexical 영역의 `explc`가
필요하다. 이미 검증된 reference의 `*` 연산 자체에는 별도 capability gate가 없다.
callee가 내부적으로 `explc`를 사용하더라도 값 전용 시그니처라면 caller에는
`explc`가 필요하지 않다.

```xen
#![explc]
fn append(values: &mut Vec<Int>, value: Int) {
    values.push(value);
}

#![explc]
fn main() {
    let mut values = [1];
    let reference = &mut values;
    append(reference, 2);
}
```

`&T`는 shared reference, `&mut T`는 mutable reference다. mutable reference를 만들려면
원본 local도 mutable이어야 한다.

Struct, tuple, enum local도 `&`/`&mut`로 빌릴 수 있다. Struct field와 tuple 원소는
`r.field`, `r.0`처럼 reference를 통해 접근하고, `&mut`이면 같은 문법으로 대입할 수
있다. 명시적 reference parameter·전달에는 기존처럼 `explc`가 필요하다.

```xen
#global[explc]
struct Counter { value: Int }

fn increment(counter: &mut Counter) {
    counter.value = counter.value + 1;
}

fn main() {
    let mut counter = Counter { value: 1 };
    let reference = &mut counter;
    increment(reference);
    println(reference.value);
    counter.value = 3; // reference의 마지막 사용 이후
}
```

`*r`의 값 취득은 POD aggregate를 복사하고 String·Vec을 포함한 clone 가능한
aggregate를 복제한다. `*r = replacement`는 RHS를 준비한 뒤 기존 소유 field를
정리하고 전체 값을 교체한다. File 또는 Ptr wrapper처럼 move-only인 aggregate의
whole-value 취득은 허용하지 않으며, `&mut`를 통한 기존 field 이동·재초기화는
유지한다. `match *r`도 scrutinee를 값으로 취득하므로 borrowed pattern matching은
아니다.

Aggregate 전체를 빌리는 reference는 해당 값 전체의 borrow다. 서로 다른 field에
대한 명시적 borrow, reference 필드 저장, reference 반환, reference-to-reference와
temporary borrow는 이번 지원 범위에 포함되지 않는다. 기존 Slice field의 원본 수명과
Ptr field의 `bb` 경계도 유지한다.

Struct field 초기화·대입에는 기존 enum 기대 타입 추론 제한이 남아 있다. 예를 들어
field 타입이 `Option<Int>`여도 `r.o = Option.None`과 `*r = H { o: Option.None }`에는
`Option<Int>.None`처럼 타입 인자를 명시해야 한다. Reference 없는 `h.o = Option.None`도
같은 제한을 갖는다. Enum 자체의 전체 교체인 `*r = Option.None`에는 referent 기대
타입이 전달된다.

## Shared reborrow와 coercion

Mutable reference의 referent를 `&*r`로 다시 빌리면 새 shared loan이 생긴다.
이미 shared인 reference에서도 `&*s`를 사용할 수 있다. 같은 referent의 `&T` 기대
타입이 있는 binding·인자·조건식·match 문맥에서는 `&mut T`가 같은 shared reborrow로
변환된다. `&T`를 `&mut T`로 바꾸거나 함수 타입 전체를 변환하지는 않는다.

```xen
#global[explc]
fn read(value: &Int) -> Int { return *value; }

fn main() {
    let mut value = 1;
    let parent = &mut value;
    let shared: &Int = parent; // &*parent와 같은 child loan
    println(*shared);
    println(read(parent));
    *parent = 2; // shared child의 마지막 사용 이후
}
```

Shared child가 살아 있는 동안 부모 reference나 그 복사본으로 읽는 것은 가능하지만
변경·이동은 거부된다. 여러 shared child를 만들 수 있고, 각 child의 마지막 사용
이후 부모의 변경 권한을 다시 사용할 수 있다. 기대 타입 없는 `let copy = parent`는
기존 reference 복사이며 mutability를 바꾸지 않는다.

명시적 `&*r`과 reference binding·인자 전달에는 기존 `explc` 규칙이 적용된다.
`&mut self`에서 `self.read()`처럼 shared method를 호출하는 implicit receiver에는
새 `explc` 요구를 추가하지 않는다. `&r`는 reference-to-reference라 거부되며
mutable reborrow 문법 `&mut *r`는 아직 지원하지 않는다.

검사기는 다음 동작을 거부한다.

- 독립된 mutable borrow와 겹치는 shared/mutable borrow; shared reborrow가 살아 있는 동안 부모 변경
- shared borrow를 통해 값 변경
- borrow가 살아 있는 동안 원본 변경 또는 이동
- reference 반환
- reference-to-reference
- temporary에 대한 borrow
- reference를 통한 File ownership 이동

borrow는 reference binding의 마지막 사용 이후 종료되므로 그 뒤에는 원본을 다시
사용하거나 변경할 수 있다.
reference를 복사한 binding과 Slice field를 가진 aggregate의 복사도 같은 원본을
대여한다. 조건식과 loop backedge에서 가능한 원본을 모두 추적하므로, 다음 iteration에
다시 사용할 reference의 borrow는 loop 중간에서 종료되지 않는다.

move-only field는 각각 이동 상태를 갖는다. 한 field를 이동한 뒤 다른 field는 사용할
수 있지만, 이동한 field나 aggregate 전체는 재초기화하기 전에는 사용할 수 없다.
shared receiver를 통한 소유권 이동은 허용하지 않는다.

method가 Slice field를 확정적으로 덮어쓰면 이전 원본의 borrow는 사라진다. 조건부
덮어쓰기라면 두 원본을 모두 대여할 수 있다. callee local의 view를 caller의 field에
저장하는 escape는 거부한다.

## Module 안에 borrow 숨기기

구현 module은 reference를 값 전용 wrapper 안에 캡슐화할 수 있다.

```xen
module metrics;
#global[explc]

fn text_size(value: String) -> Int {
    let view = &value;
    return len(view);
}
```

```xen
module app;
import metrics;

fn main() {
    let text = "hello";
    println(metrics.text_size(text));
    println(text); // valid; app에는 explc가 필요 없다
}
```

`#global[explc]`는 `metrics` 파일의 함수에만 적용되고 import한 `app`으로 전파되지
않는다. 반대로 공개 parameter가 `&T`라면 reference를 생성·전달하는 caller도
`explc` 경계에 참여해야 한다.

## 변경 method의 receiver

Vec의 `set`, `push`, `pop`과 File의 `read`, `write`, `close`는 mutable local 또는
`&mut` receiver가 필요하다. 관찰 method인 Vec의 `len`/`get`과 File의 `is_open`은
shared reference에서도 사용할 수 있다.

implicit mutable receiver는 인자 평가 동안 예약된다. 이때 원본의 clone이나 별개
field의 이동은 가능하지만 receiver를 포함한 원본 전체를 이동할 수는 없다. 실제
호출이나 변경 연산에서 살아 있는 borrow와의 충돌을 검사한다.
