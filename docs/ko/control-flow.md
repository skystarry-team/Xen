# 함수와 반복

함수는 반복해서 사용할 작업에 이름을 붙입니다. 매개변수에는 타입을 쓰고 결과 타입은 `->` 뒤에 적습니다. 값을 돌려줄 때는 `return`을 사용합니다. 결과가 없는 함수는 `-> Unit`을 생략해도 됩니다.

다음을 `control_flow.xen`으로 저장하세요.

```xen
fn doubled(value: Int) -> Int {
    return value * 2;
}

fn main() {
    let mut total = 0;
    for number in 1..5 {
        total = total + doubled(number);
    }
    let label = if total >= 20 { "enough" } else { "more" };
    println(total);
    println(label);
    let mut remaining = 2;
    while remaining > 0 {
        println(remaining);
        remaining = remaining - 1;
    }
}
```

```console
$ xen run control_flow.xen
20
enough
2
1
```

## 조건에 따라 선택하기

`if 조건 { ... } else { ... }`에서 조건은 `Bool`이어야 합니다. 값으로 쓰는 `if`는 `else`가 필요하며, 모든 갈래에서 같은 타입의 값을 만들어야 합니다. 예제의 `label`처럼 갈래의 마지막 값에는 `;`을 붙이지 않습니다.

작업을 나눠 실행할 때는 각 갈래에 여러 문장을 적을 수 있습니다. 다음 조건을 이어 검사하려면 `else if`를 사용하세요.

## 반복하기

`1..5`는 1부터 4까지입니다. 끝값은 포함하지 않습니다. `for`의 변수는 반복 본문에서만 사용할 수 있습니다. 시작값이 끝값 이상이면 실행하지 않습니다. 범위에 간격이나 역순을 지정하는 문법은 없습니다.

`while`은 조건이 참인 동안 반복합니다. 조건이 바뀌도록 본문을 작성하세요. `break;`는 가장 안쪽 반복을 끝내고, `continue;`는 현재 회차의 나머지를 건너뜁니다. 컬렉션을 반복하는 방법은 [다음 장](collections.md)에서 설명합니다.

## 반환값과 함수 값

결과가 있는 함수는 모든 경로에서 값을 반환해야 합니다. 일반 함수의 마지막 표현식만으로 반환되지 않으므로 `return`을 적으세요. 함수는 자신을 호출할 수도 있습니다. 매개변수는 최대 여섯 개입니다. 재귀 호출에는 깊이 제한이 있으므로 많은 항목을 처리할 때는 반복문을 고려하세요.

일반 이름 있는 함수는 `fn(Int) -> Int` 같은 타입의 값으로 저장하거나 다른 함수에 전달할 수 있습니다. 위 코드에서 `let transform: fn(Int) -> Int = doubled;`로 저장한 뒤 `transform(3)`으로 호출하면 6입니다. 익명 함수와 클로저는 지원하지 않습니다.

## 바꿔 보기

범위를 `1..6`으로 바꾸고 합계가 어떻게 달라지는지 확인하세요. `continue`를 넣어 특정 숫자를 건너뛰는 방법도 시도해 보세요.

---

[목차](README.md) · [이전: 변수와 값](language-basics.md) · [다음: 문자열과 컬렉션](collections.md) · [English](../en/control-flow.md)
