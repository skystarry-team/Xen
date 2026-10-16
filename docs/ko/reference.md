# 문법과 자주 만나는 문제

코드를 작성하다 문법이 기억나지 않을 때 찾아보는 페이지입니다. 각 주제의 상세한 설명과 실행 코드는 연결된 장에 있습니다.

## 문법 빠르게 찾기

| 원하는 작업 | 쓰는 형태 | 읽을 장 |
| --- | --- | --- |
| 값 이름 붙이기 | `let name: Type = value;` | [변수와 값](language-basics.md) |
| 바꿀 수 있는 변수 | `let mut name = value;` | [변수와 값](language-basics.md) |
| 함수 선언 | `fn name(x: Int) -> Int { return x; }` | [함수](control-flow.md) |
| 조건 값 | `if condition { yes } else { no }` | [함수와 반복](control-flow.md) |
| 범위 반복 | `for item in start..end { ... }` | [함수와 반복](control-flow.md) |
| 조건 반복 | `while condition { ... }` | [함수와 반복](control-flow.md) |
| 배열처럼 값 나열 | `[first, second]`, `Vec<T>` | [컬렉션](collections.md) |
| 구조체 선언·생성 | `struct User { name: String }`, `User { name: "Mina" }` | [타입](types.md) |
| 여러 형태의 값 | `enum State { Idle, Ready(Int) }` | [타입](types.md) |
| 형태별로 선택 | `match value { Pattern => result, ... }` | [타입](types.md) |
| 튜플 나누기 | `let (left, right) = pair;` | [타입](types.md) |
| 제네릭 | `fn identity<T>(value: T) -> T { return value; }` | [제네릭](generics.md) |
| 원본 참조 | `&value`, `&mut value`, `*reference` | [소유권](ownership.md) |
| 실패 전달 | `fallible_call()?` | [오류 처리](error-handling.md) |
| 프로젝트 파일 사용 | `module app;`, `import folder.module as short;` | [모듈](modules.md) |
| 표준 모듈 사용 | `use std.string as text;` | [표준 라이브러리](stdlib.md) |
| 테스트 선언 | `test fn name() { assert(condition); }` | [테스트](testing.md) |

함수·구조체·enum·impl은 파일 최상위에 선언합니다. 값과 문장은 함수 안에 씁니다. 문장에는 `;`을 붙이고 값으로 쓰는 `if`·`match`의 마지막 표현식은 붙이지 않습니다. 주석은 `//`만 지원하며 블록 주석은 없습니다. 이름과 문자열은 대소문자를 구분합니다.

## 숫자와 연산자

정수는 `I8`~`I64` 및 `U8`~`U64`, 실수는 `F32`, `F64`입니다. `Int = I64`, `Float = F64`입니다. 숫자 리터럴은 10진수이며 실수는 `1.25`, `1e3`처럼 쓸 수 있습니다. 숫자 사이의 `_`와 16진수 리터럴 문법은 없습니다.

우선순위는 높은 것부터 호출·필드·색인·`?`, 단항 `-`·`!`·`&`·`*`, `* / %`, `+ -`, `< <= > >=`, `== !=`, `&&`, `||`입니다. 헷갈리면 괄호를 사용하세요. 문자열에는 `+`, `==`, `!=`를 사용할 수 있습니다. 벡터의 비교는 비교 가능한 숫자·Bool·String·중첩 벡터 원소에 한해 지원합니다. 구조체와 enum에는 `==`가 없습니다.

## 흔한 오류와 수정

| 상황 | 수정 |
| --- | --- |
| 빈 벡터의 타입을 알 수 없음 | `let values: Vec<Int> = [];`처럼 타입 추가 |
| 변경할 수 없는 변수 | 변경해야 한다면 `let mut`으로 선언 |
| 서로 다른 숫자 타입 | `i32(...)` 등으로 명시적으로 변환 |
| 빠진 match 갈래 | 빠진 enum 형태를 추가하거나 적절한 `_` 사용 |
| 제네릭 타입 추론 실패 | 인자에 타입 정보를 주거나 모든 타입 인자 명시 |
| 빌린 값 변경 | 참조의 마지막 사용 이후 변경 |
| 이미 이동한 값 사용 | 새 소유자를 사용하거나 이동 전에 필요한 정보 읽기 |
| 모듈을 찾을 수 없음 | 시작 파일 기준 경로와 `module` 이름 확인 |
| 범위 밖 원소 읽기 | 접근 전 길이 검사 |

이동한 값을 사용하는 다음 코드는 의도적인 오류입니다.

```xen
fn main() {
    let original = box(42);
    let transferred = original;
    println(original.into_inner());
}
```

```sh
xen check move_error.xen
```

`moved`를 포함하는 오류가 납니다. 마지막 줄을 `println(transferred.into_inner());`로 바꾸면 42를 출력합니다.

## 기능을 찾을 수 없을 때

현재 클로저·trait·예외·async·FFI·패키지 관리 기능은 없습니다. 참조 반환, 가변 Slice, 문자열 색인, match guard도 지원하지 않습니다. 다른 언어의 문법을 그대로 쓰기보다는 해당 장에서 설명한 함수·반복·`Result`를 사용하세요.

[`bb` 저수준 기능](low-level.md)은 원시 메모리, 운영체제 호출, 범위가 있는 주소, volatile·정수 원자 접근, CPU 힌트·장벽, 다중 출력 인라인 `asm`, 스칼라 C ABI `extern_call`을 지원합니다. 일반적인 파일·입출력·경로 작업은 표준 라이브러리 API를 사용하세요.

---

[목차](README.md) · [이전: 명령어 안내](cli.md) · [English](../en/reference.md)
