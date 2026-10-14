# 타입을 재사용하기

값을 담거나 전달하는 코드를 여러 타입에 사용하려면 `<T>`로 타입 매개변수를 선언합니다. 다음을 `generics.xen`으로 저장하세요.

```xen
struct Pair<T> { first: T, second: T }

fn identity<T>(value: T) -> T {
    return value;
}

fn main() {
    let pair = Pair<Int> { first: identity(7), second: 9 };
    println(pair.first);
    println(identity<String>("hello"));
}
```

```console
$ xen run generics.xen
7
hello
```

`identity(7)`에서는 인자의 타입으로 `T`를 결정합니다. `identity<String>("hello")`는 타입을 직접 지정합니다. 여러 타입이 있으면 `<A, B>`처럼 모두 적습니다. 구조체와 enum도 타입 매개변수를 가질 수 있습니다. 제네릭 타입의 메서드는 `impl<T> Pair<T> { ... }` 형태로 선언합니다.

## 타입을 결정할 정보가 없을 때

빈 벡터나 `Option.None`은 그것만으로 항목 타입을 알 수 없습니다. `let items: Vec<Int> = [];`, `let missing: Option<String> = Option.None;`처럼 적으세요.

제네릭 함수의 타입 추론은 인자 타입을 사용하며, 결과를 받을 변수의 타입으로 결정하지 않습니다. `let n: I32 = identity(1);`은 인자 `1`로부터 `Int`를 선택하므로 실패합니다. `identity<I32>(1)` 또는 `identity(i32(1))`로 바꾸세요. 타입 인자를 일부만 적는 방식은 지원하지 않습니다.

## 어떤 작업을 재사용할 수 있나

제네릭 함수는 값을 보관·전달·반환하고 이미 모양이 알려진 `Option<T>`, `Vec<T>` 등을 다룰 수 있습니다. 그러나 아무 타입이나 뜻하는 `T`에 바로 `+`, 비교, 임의의 필드나 메서드를 사용할 수는 없습니다. 예를 들어 `fn add<T>(a: T, b: T) -> T` 안에서 `a + b`는 오류입니다. 숫자 계산에는 `Int` 같은 구체적인 타입을 쓰거나, 필요한 작업을 수행하는 이름 있는 함수를 콜백으로 전달하세요. trait·제약·연산자 오버로딩은 지원하지 않습니다.

이미 알려진 enum이나 튜플은 제네릭 함수 안에서도 `match`로 나눌 수 있습니다. 아직 타입을 모르는 `T`를 숫자 리터럴이나 특정 enum으로 구분할 수는 없습니다.

---

[목차](README.md) · [이전: 구조체와 enum](types.md) · [다음: 복사·이동·참조](ownership.md) · [English](../en/generics.md)
