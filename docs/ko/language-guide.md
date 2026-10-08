# 언어 가이드

## 재귀 소유 구조

`Box<T>`와 `box(value)`는 단일 값을 명시적으로 heap에 소유하는 move-only 간접 타입이다.
`Box`·`Vec` 경계를 통한 재귀 struct·enum은 허용하고 inline layout 순환은 거부한다.
`as_ref()`·`as_mut()`로 내부 값을 빌리고 `into_inner()`로 Box를 소비해 값을 꺼낸다.
기존 사용자 정의 inline `Box`는 유지하며 owning 타입의 qualified identity는
`core.box.Box<T>`다. [Box와 재귀 aggregate](box-and-recursive-aggregates.md)를 참고한다.

## 제어 흐름과 수명

재귀를 포함한 Xen 함수 호출은 entry 함수를 포함해 최대 4096개의 활성 frame을
허용한다. 실제 stack은 함수 frame과 인자 크기에 따라 이보다 먼저 소진될 수 있다.

`match` arm의 `return`은 현재 함수를 종료하고, `break`와 `continue`는 해당
`match`를 감싸는 loop를 대상으로 한다. 종료하는 arm은 match 결과 타입의 합류에서
제외한다. arm에서 바깥 local을 사용하거나 안전하게 변경한 뒤 이동할 수 있다.

borrow는 조건식, 참조·aggregate 복사, 반복의 다음 iteration과 함수의 field 변경을
포함해 검사한다. field를 이동하면 그 field를 재초기화하기 전에는 다시 사용할 수
없으며, 부분 이동된 aggregate 전체도 사용할 수 없다. 서로 다른 field는 별도로
추적한다. 자세한 규칙은 [소유권과 reference](ownership-and-references.md)를 참고한다.

Struct·tuple·enum local도 `explc` 안에서 `&`/`&mut`로 빌릴 수 있다. `r.field`와
`r.0`는 field 접근이며 `*r = value`는 전체 교체다. Reference 필드 저장과 reference
반환은 계속 지원하지 않는다.

`&mut T`는 같은 referent의 `&T` 기대 타입에서 shared reborrow로 변환되고,
`&*r`로도 명시할 수 있다. Shared child가 살아 있는 동안 부모 변경은 거부되며,
child의 마지막 사용 이후 다시 허용된다.

`?`가 조기 반환하면 이미 준비한 인자와 aggregate field의 소유 임시값도 정리한다.
runtime error와 `panic`에는 unwind가 없다.

## Method와 구조적 iterator

Named struct의 inherent method는 `impl` 블록에 선언한다. receiver는 `self`, `&self`,
`&mut self` 중 하나이며 호출 시 receiver reference는 자동으로 만들어진다.

```xen
for index in 0..10 {
    println(index);
}
```

`for PATTERN in EXPR`은 표현식을 한 번 평가하고 mutable iterator의
`next(&mut self) -> Option<T>`를 반복 호출한다. 자동 collection 변환은 하지 않으며
pattern은 binding, `_`, 중첩 tuple을 지원한다.

`start..end`는 `Int` 전용 반개방 범위 `[start, end)`다. 양 endpoint는 왼쪽부터 한
번씩 평가되며 `start >= end`이면 반복하지 않는다. step, inclusive·역방향 range와
chained range는 지원하지 않는다. `Range`와 그 구조적 `next` 구현은 prelude 타입이라
사용자가 같은 이름을 선언할 수 없다.

`use std.iter;` 뒤에는 clone 가능한 element의 `Vec<T>.iter()`와
`Slice<T>.iter()`, byte 단위 `String.iter()`, bounds descriptor를 따르는
`Ptr<T>.iter()`를 사용할 수 있다. 모든 구조적 iterator의 `.enumerate()`는 iterator를
소비하고 `(Int, T)`를 0부터 산출한다. collection 자체를 `for`에 바로 넘기거나
move-only element를 consuming iteration하는 `into_iter()`는 아직 지원하지 않는다.

`String.as_bytes()`는 local-only `Slice<U8>` view를 만들고
`Vec<U8>.into_string()`은 vector를 소비해 byte-preserving String으로 옮긴다.
Bundled module은 `use std.iter;`처럼 명시적으로 가져온다. project module은 `import`를
사용하며 `std.*`/`core.*`는 toolchain 전용 namespace다. `use`만 쓰는 단일 파일은
`module` 선언 없이 지원한다. 실행 파일 주변 stdlib을 자동 탐색하며
`XEN_STDLIB_ROOT`로 개발 root를 override할 수 있다. core layout 질의와 탐색 규칙은
[모듈 문서](modules-and-structs.md)를 따른다.

의미 오류는 source의 borrow origin·이후 사용, move field와 lexical capability 경계를
note로 설명한다. 진단 범위와 conservative witness 규칙은 [의미 진단](diagnostics.md)을
따른다.

## Native 테스트

`test fn name() { ... }`는 native 테스트 선언이다. `xen test`와 `--filter`로 실행하며
`xen test std.fs`는 배송된 stdlib을 검사한다. [테스트 문서](testing.md)를 참고한다.

## `std.convert`

`use std.convert;`는 Xen 소스로 구현된 signed decimal `Int` 변환을 제공한다.

```xen
let parsed = std.convert.parse_int("-42");
let text = std.convert.format_int(-42);
```

`parse_int(String) -> Result<Int, std.convert.ParseIntError>`는 선택적인 선행 `+`/`-`와
하나 이상의 ASCII digit만 받는다. 오류는 `Empty`, byte index와 값을 담는
`InvalidDigit((Int, U8))`, `Overflow` 중 하나다. 앞뒤 whitespace는 허용하지 않으므로
호출자가 token을 먼저 나눠야 한다. `format_int`는 선행 0이나 `+`가 없는 canonical
decimal을 반환하며 `Int` 최솟값과 최댓값을 모두 지원한다.

## `std.env`와 `std.string`

`std.env.args() -> Vec<String>`은 `arg_count()`를 한 번 읽고 프로그램 인자를 원래
순서대로 반환한다. 빈 인자와 UTF-8이 아닌 byte도 그대로 보존하며, 개수 검증과 usage
정책은 CLI가 담당한다.

`std.string.is_ascii_whitespace(U8) -> Bool`은 `0x09`~`0x0D`와 `0x20`만 공백으로
판정한다. `split_ascii_whitespace(String) -> Vec<String>`은 연속·선행·후행 공백을
건너뛰며 빈 token을 만들지 않는다. NUL과 `0x80` 이상을 포함한 다른 byte는 UTF-8
검증 없이 token에 보존한다.

## `std.io`와 `std.fs`

`std.io`는 stdout/stderr 전체 쓰기와 recoverable `IoError`를, `std.fs`는 fd를
노출하지 않는 one-shot `read`, `write`, `copy`를 제공한다. 자세한 계약과 예제는
[File/I/O 문서](file.md)를 참고한다. String은 이 API에서도 UTF-8 검증 없는 byte
sequence다.

`std.path`의 byte 경로 연산, `std.env.cwd()`, `std.process.id()`/`parent_id()`,
`std.io.read_stdin()`과 `std.fs.append()`/`metadata()`/`read_dir()`도 제공한다.
API 계약과 남은 제한은 [표준 라이브러리 문서](stdlib.md)를 참고한다.

Xen 언어 기능은 주제별 문서로 나눠 설명한다. 모든 내용은 현재 `main`에 구현된
동작을 기준으로 하며, 구현 예정 기능은 [상태와 제한](status-and-limitations.md)에서만
다룬다.

## 언어 사용

- [기본 문법과 타입](language-basics.md): 변수, 숫자, 함수, 제어 흐름과 기본 builtin
- [String과 Vec](strings-and-vectors.md): byte string, 벡터, 입력과 출력
- [소유권과 reference](ownership-and-references.md): clone, move, drop과 borrow
- [Box와 재귀 aggregate](box-and-recursive-aggregates.md): 명시적 allocation, 이동과 재귀 drop
- [제네릭, enum, match](generics-enums-and-match.md): 인자 타입 기반 제한적 추론, 단형화, tuple, exhaustive match
- [모듈과 구조체](modules-and-structs.md): 여러 파일, import, named struct
- [저수준 `bb`](low-level-bb.md): typed `Ptr<T>` raw memory, address 추출과 Linux syscall
- [File API](file.md): 파일 생성, 읽기, 쓰기, 닫기와 오류

## 빠른 참고

| 항목 | 현재 지원 |
| --- | --- |
| target | Linux x86-64 static non-PIE ELF |
| scalar | `I8`~`U64`, `F32`, `F64`, `Bool` (`Int = I64`, `Float = F64`) |
| 값 | `String`, `Box<T>`, `Vec<T>`, read-only `Slice<T>`, struct, tuple, enum, `File` |
| 제어 흐름 | `if`, `while`, 구조적 `for`, `Int` `start..end`, `break`, `continue`, `return`, expression `if`, `match` |
| 다중 파일 | source-root 기반 `module`/qualified `import` |

제네릭 함수는 호출 인자의 정적 타입으로 모든 타입 인자를 결정할 수 있으면 생략할 수
있다. 반환값의 기대 타입과 함수 본문은 추론에 사용하지 않으며, 정보가 부족하거나
타입이 충돌하면 모든 타입 인자를 명시해야 한다. 부분 생략과 암묵적 숫자 변환은 없다.

`Result<T,E>`의 postfix `?`는 같은 오류 타입의 `Result<U,E>` 함수에서 Ok payload를
꺼내고 Err를 조기 반환한다. Pointer arithmetic/address 역변환, package manifest 등 아직 제공하지 않는 기능은
[상태와 제한](status-and-limitations.md)을 참고한다.
Concrete 사용자 함수는 `fn(T1, T2) -> U` 타입의 8바이트 함수 값으로 참조할 수 있다.
함수 값은 local, 인자, 반환값, struct field에 저장하고 호출할 수 있다. generic 함수
선언 자체, builtin과 method value, closure는 아직 함수 값으로 만들 수 없다.

`build/run/test --opt=basic`으로 정수·Bool 계산과 제한된 leaf 함수를 최적화한다.
기본값은 `off`이며 `--opt-report`는 `basic`의 영역·분리 이유·변환 횟수를 stderr에
출력한다. 상세 범위는 [Native 기본 최적화](optimization.md)를 참고한다.

`#scope[jit]`는 작은 정수·Bool 영역을 runtime에 컴파일하는 실험적 기능이다. `--jit=off`로 같은 IR의
AOT와 비교하고 `--jit-report`로 compile·cache 통계를 본다. [Runtime JIT](jit.md)를 참고한다.
