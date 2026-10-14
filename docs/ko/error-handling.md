# 없을 수 있는 값과 실패

찾는 값이 없거나 사용자가 잘못된 숫자를 입력할 수 있습니다. 이런 상황은 결과를 나타내는 값으로 처리합니다. `Option<T>`와 `Result<T, E>`는 별도로 가져오지 않아도 사용할 수 있습니다.

## 있을 수도 없는 값: Option

`Option.Some(value)`는 값이 있고, `Option.None`은 값이 없습니다. `std.string.find`의 검색 결과가 대표적입니다. `match`로 두 경우를 처리하세요. `std.option.unwrap_or(value, fallback)`으로 기본값을 선택할 수도 있습니다. 기본값은 `Some`인 경우에도 함수 호출 전에 계산하므로, 비용이 크거나 부수 효과가 있으면 `match`를 쓰세요.

## 성공과 실패: Result

`Result.Ok(value)`는 성공, `Result.Err(error)`는 실패입니다. 다음을 `errors.xen`으로 저장하세요.

```xen
use std.convert as convert;

fn double_number(text: String) -> Result<Int, convert.ParseIntError> {
    let number = convert.parse_int(text)?;
    return Result.Ok(number * 2);
}

fn main() {
    println(match double_number("21") {
        Result.Ok(number) => convert.format_int(number),
        Result.Err(_) => "Please enter a decimal integer.",
    });
    println(match double_number("hello") {
        Result.Ok(number) => convert.format_int(number),
        Result.Err(_) => "Please enter a decimal integer.",
    });
}
```

```console
$ xen run errors.xen
42
Please enter a decimal integer.
```

잘못된 입력도 `match`로 처리하면 다른 결과를 출력하거나 다시 시도하는 코드를 작성할 수 있습니다. 예제에서 `hello`를 파싱하는 것은 프로그램을 강제 종료하지 않습니다.

## ?로 실패 전달하기

`parse_int(text)?`는 성공하면 값을 꺼내고, 실패하면 현재 함수에서 같은 오류를 반환합니다. 현재 함수의 반환 타입은 `Result<U, E>`여야 하며 호출 결과의 오류 타입 `E`와 같아야 합니다. `main()`처럼 결과가 없는 함수나 `Option`에는 `?`를 쓸 수 없습니다.

오류 타입이 다르면 먼저 `std.result.map_err(value, convert_error)`로 변환하세요. `convert_error`는 이전 오류를 받아 새 오류를 반환하는 이름 있는 함수입니다. 변환한 뒤 `?`를 붙일 수 있습니다. 예외를 던지거나 `try/catch`로 잡는 문법은 없습니다.

## 프로그램을 끝내야 할 때

`panic(message)`는 오류 메시지를 내고 실패 상태로 프로그램을 종료합니다. `assert(condition)`과 `assert_msg(condition, message)`는 조건이 거짓이면 종료합니다. 예상 가능한 입력 오류나 파일 실패에는 `Result`를 사용하고, 계속 진행할 수 없는 곳에서 종료를 선택하세요.

컴파일 단계의 오류는 `xen check`로 확인합니다. 오류에 표시된 파일·줄·열을 찾아 코드를 고칩니다. 참조 오류의 `note`는 참조가 시작되거나 나중에 사용되는 위치를 보여 줍니다. [자주 만나는 문제](reference.md)에서 수정 예를 확인하세요.

---

[목차](README.md) · [이전: 복사·이동·참조](ownership.md) · [다음: 여러 파일로 나누기](modules.md) · [English](../en/error-handling.md)
