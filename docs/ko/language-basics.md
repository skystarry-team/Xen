# 기본 문법과 타입

## 타입

| 타입 | 설명 |
| --- | --- |
| `I8`, `U8` / `I16`, `U16` / `I32`, `U32` / `I64`, `U64` | signed/unsigned fixed-width integer |
| `F32`, `F64` | IEEE-754 float |
| `Int`, `Float` | 각각 `I64`, `F64`의 호환 이름 |
| `Bool`, `Unit` | Boolean 및 반환값 없는 연산 |
| `String`, `Vec<T>`, `Slice<T>`, `File` | managed, owned 또는 borrowed runtime value |

정수 literal의 기본 타입은 `I64`, 실수 literal의 기본 타입은 `F64`다. annotation,
parameter, return, struct field 문맥에서는 해당 숫자 타입으로 literal을 맞춘다. 숫자
타입 사이에는 암시적 변환이 없다.

`i8`, `u8`, `i16`, `u16`, `i32`, `u32`, `i64`, `u64`, `f32`, `f64`는 checked
conversion이며, `int(F64)`와 `float(I64)`도 유지된다. 직접 판별 가능한 범위 오류는
compile error이고, 실행 중 범위 오류 또는 NaN/무한대의 integer 변환은 runtime error다.

## 변수와 대입

```xen
let answer = 42;
let name: String = "xen";
let mut count = 0;
count = count + 1;
```

`let` binding은 immutable이 기본이다. 재대입과 mutable Vec/File method에는 `let mut`가
필요하다. 같은 lexical block에서 이름을 중복 선언할 수 없지만 nested block에서는
shadowing할 수 있다. initializer는 새 binding보다 먼저 검사한다. 따라서
`let x = x + 1`의 오른쪽 `x`는 바깥 binding이다.

## 튜플 binding

```xen
let (number, label) = (42, "xen");
let (first, (_, last)) = (1, (2, 3));
let mut (left, right): (Int, Int) = (1, 2);
left = 4;
let _ = box(0);
```

`let`은 binding·`_`·중첩 tuple pattern을 지원한다. arity와 타입은 정적으로 검사하고
같은 pattern이나 lexical block에서 이름을 중복할 수 없다. `mut`는 모든 binding에
적용되며 annotation은 initializer 전체 타입이다. RHS는 새 이름이 보이기 전에 한 번
평가하므로 같은 이름의 outer binding도 읽을 수 있다. 각 binding은 일반 by-value
copy·clone·move 규칙을 따른다. 버린 field와 숨은 owner는 다음 statement 전에 정리한다.
RHS 안의 `?`·return도 기존 cleanup 규칙을 따른다. literal·enum·struct pattern과
pattern assignment는 지원하지 않으며 기존 tuple element 타입 제한을 유지한다.

## 연산자

- 산술: `+`, `-`, `*`, `/` (같은 numeric 타입), `%` (같은 integer 타입), `+` (`String`)
- 비교: `<`, `<=`, `>`, `>=` (같은 numeric 타입)
- equality: `==`, `!=` (numeric, `Bool`, `String`, 지원되는 Vec)
- 논리: `&&`, `||`, `!` (`Bool`)
- unary negation: `-value` (signed integer, float)

정수 `+`, `-`, `*`는 타입 폭의 modulo 연산이다. `/`와 `%`의 0 divisor, signed
`min / -1`, `min % -1`은 runtime error다. `&&`와 `||`는 short-circuit한다.

## 함수와 제어 흐름

```xen
fn average(total: Float, count: Int) -> Float {
    return total / float(count);
}

fn main() {
    let mut index = 0;
    while index < 10 {
        if index == 5 {
            break;
        }
        index = index + 1;
    }
}
```

반환 타입을 생략하면 `Unit`이다. non-`Unit` 함수의 모든 실행 경로는 값을 반환해야
한다. 함수와 call은 최대 여섯 parameter/argument를 지원하며, 재귀를 포함한 호출은
entry 함수를 포함해 활성 frame 최대 4096개까지 허용한다. stack은 frame과 인자 크기에
따라 더 일찍 소진될 수 있다.

`if`는 statement와 expression으로 쓸 수 있다. expression `if`는 마지막 `else`가
필수이고, 각 branch는 semicolon 없는 단일 값 expression이며 같은 타입을 만들어야 한다.

```xen
let label = if count == 0 { "empty" } else { "present" };
```

독립 `{ ... }`는 lexical block statement다. block의 owned local은 정상 종료와
`break`, `continue`, `return`에서 정리된다. 상세 규칙은 [소유권과 reference](ownership-and-references.md)를 참고한다.

## 기본 builtin

| 호출 | 결과/동작 |
| --- | --- |
| `print(value)`, `println(value)` | 지원되는 scalar, `Bool`, String, Vec 출력 |
| `len(value)` | String byte length 또는 Vec element count |
| `assert(condition)`, `assert_msg(condition, message)` | false이면 runtime failure |
| `panic(message)` | message를 stderr에 기록하고 종료 |
| `arg_count()`, `arg(index)` | 프로그램 인자 개수와 String 인자 |
| `int_to_str(value)` | `Int`를 decimal String으로 변환 |

File I/O는 [File API](file.md), String/Vec builtin은 [String과 Vec](strings-and-vectors.md)를 참고한다.
전체 argument 수집에는 Xen 소스 `std.env.args() -> Vec<String>`을 권장한다.
