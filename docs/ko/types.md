# 구조체와 enum

구조체는 함께 쓰는 값에 필드 이름을 붙이고, enum은 값의 여러 형태에 이름을 붙입니다. 다음을 `types.xen`으로 저장하세요.

```xen
struct Task { title: String, done: Bool }
enum Priority { Normal, Urgent(Int) }

impl Task {
    fn label(&self) -> String {
        return if self.done { "done: " + self.title } else { "todo: " + self.title };
    }
}

fn main() {
    let task = Task { title: "read the guide", done: false };
    println(task.label());
    let priority = Priority.Urgent(2);
    println(match priority {
        Priority.Normal => "normal",
        Priority.Urgent(days) => "due in " + int_to_str(days),
    });
    let (number, label) = (42, "answer");
    println(label + ": " + int_to_str(number));
}
```

```console
$ xen run types.xen
todo: read the guide
due in 2
answer: 42
```

## 구조체와 메서드

`struct`에는 각 필드의 이름과 타입을 적습니다. 만들 때는 모든 필드를 한 번씩 지정하세요. 필드 순서는 자유롭습니다. `task.title`처럼 읽고, `let mut task`로 선언했다면 `task.done = true;`처럼 바꿀 수 있습니다. 중첩된 구조체 필드도 `user.address.city`처럼 다룹니다.

`impl Task`에는 해당 타입의 메서드를 적습니다. `&self`는 읽기, `&mut self`는 변경, `self`는 값 전달을 받는 메서드입니다. `&mut self` 메서드를 호출할 변수는 변경 가능해야 합니다. 위 코드의 `task.label()`은 메서드 호출입니다. 참조 자체를 직접 만들 때의 규칙은 [소유권 장](ownership.md)에 있습니다.

구조체는 `==`로 비교할 수 없으므로 필요한 필드끼리 비교하세요. 기본 필드 값과 구조체 분해 패턴은 지원하지 않습니다.

## enum과 match

`Priority.Normal`처럼 값이 없는 형태와 `Priority.Urgent(2)`처럼 값을 가진 형태를 선언할 수 있습니다. 한 형태에 여러 값을 넣으려면 `Urgent((Int, String))`처럼 튜플을 사용합니다.

`match`는 `패턴 => 결과`를 차례로 나열합니다. enum의 모든 형태를 처리해야 하며 `_`는 나머지를 받습니다. `_`처럼 언제나 맞는 패턴 뒤에 다른 갈래를 두면 오류가 납니다. 값으로 사용하는 모든 갈래는 같은 결과 타입이어야 합니다. 갈래에서 만든 이름은 해당 갈래 안에서만 사용할 수 있습니다. `match`로 숫자·Bool·문자열·튜플도 구분할 수 있습니다. 추가 조건을 붙이는 match guard는 없습니다.

## 튜플

`(42, "answer")`의 타입은 `(Int, String)`입니다. `pair.0`, `pair.1`처럼 읽거나, `let (number, label) = pair;`로 나눕니다. 중첩된 튜플도 나눌 수 있고 `_`로 필요 없는 값을 버릴 수 있습니다. 기존 변수에 튜플 전체를 분해 대입하는 문법은 없습니다.

---

[목차](README.md) · [이전: 문자열과 컬렉션](collections.md) · [다음: 타입을 재사용하기](generics.md) · [English](../en/types.md)
