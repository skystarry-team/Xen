# 모듈과 구조체

## Module, import와 use

여러 파일 프로그램은 entry file의 디렉터리를 source root로 사용한다. 선언 순서는 선택적 `module`, 0개 이상의 `import`/`use`, 선택적 `#global`, struct/enum, function이다. module과 dependency 선언에는 세미콜론이 필요하다.

```xen
module app;
import util.text;

fn main() {
    let message = util.text.Message { value: "hello" };
    util.text.show(message);
}
```

`import util.text;`는 source root의 `util/text.xen`을 읽으며 그 파일은 정확히 `module util.text;`를 선언해야 한다. import를 쓰는 entry file도 path와 일치하는 module 선언이 필요하다. 각 파일은 자기 선언을 unqualified name으로, 직접 import한 module의 공개 함수와 struct를 전체 qualified name이나 명시적 module alias로 참조한다. transitive import는 재노출되지 않는다.

`import`는 project module 전용이다. toolchain module은 `use std.fs;`, `use std.io;`,
`use core.intrinsics;`, `use core.box;`로 가져온다. `import std.*`/`import core.*`와 다른 namespace의
`use`는 오류다. 두 예약 namespace는 project 파일로 덮어쓸 수 없다. `use`만 쓰는
단일 파일에는 `module` 선언이 필요하지 않다. API는 `std.fs.read(...)`처럼 기존의
전체 qualified name으로 접근하며 transitive dependency는 재노출하지 않는다.
자기 module의 선언은 그대로 사용할 수 있다. 따라서 `std.iter` 자체의 source와 test는
자기 iterator factory를 위해 금지된 self-use 선언을 할 필요가 없다.

`use std.convert as convert;`, `import guide.model as model;`처럼 module 전체에
별칭을 줄 수 있다. 별칭은 선언 파일에서만 유효하며 함수 호출·함수 값·타입·생성자·
enum pattern에 쓸 수 있다. 원래 qualified name도 유지한다. 파일 탐색·cycle·예약
namespace·직접 dependency 검사는 정식 모듈 이름을 사용한다.
`use std.iter as iter;`도 기존 iterator factory의 의존을 충족한다.

같은 module의 의존 선언은 한 번만 허용한다. 중복 alias와 module root·top-level
선언·내장 타입·prelude 타입 이름과의 충돌은 alias 선언 위치에서 거부한다.
parameter·type parameter·local과 `for`·`match`·`let` pattern binding도 alias 이름을
다시 쓸 수 없으며 미사용 선언도 검사한다. field·method 이름은 사용할 수 있다.
`as`는 의존 선언에서만 contextual keyword이고 다른 위치에서는 일반 identifier다.

`std`는 별도 Xen 소스로서 일반 Semantic IR·native pipeline을 통과한다. `core`는
compiler registry이며 `core.intrinsics.size_of<T>()`와 `align_of<T>()`를 제공한다.
두 함수는 실제 concrete layout의 byte size/alignment를 `Int` 상수로 반환한다.
generic aggregate, tuple, enum도 Xen 자체의 layout을 따른다. 별도의 capability는
필요하지 않으며 type/value argument 오류는 호출 위치에서 진단한다.
`core.box.Box<T>`와 `core.box.new(value)`는 명시적 owning indirection의 qualified
identity와 생성 API다. [Box 문서](box-and-recursive-aggregates.md)를 참고한다.

배포본의 `bin/xen`은 함께 배송된 `stdlib/std/`를 실행 파일 위치에서 자동 탐색한다.
설치형 `lib/xen/std/`도 지원한다. 현재 작업 디렉터리는 탐색하지 않는다.
`XEN_STDLIB_ROOT`는 `std/`를 포함하는 root를 지정하는 개발 override이며, 잘못된
override는 자동 fallback 없이 오류를 낸다. core-only 사용은 stdlib 파일이 필요 없다.
stdlib 내부 `bb`/`explc`는 caller로 전파되지 않는다. selective/wildcard use,
visibility, re-export, package manifest와 별도 일반 module search path는 아직 없다.

## Named struct

`struct`는 `#global` 뒤, 모든 함수 앞에 선언한다. field 타입은 뒤에서 선언되는 struct를 참조할 수 있다. Box·Vec 경계의 재귀는 허용하지만
직접·간접 inline 값 layout 순환은 거부한다.

```xen
struct Address { city: String, zip: Int }
struct User { name: String, address: Address }

fn main() {
    let mut user = User {
        address: Address { zip: 123, city: "Seoul" },
        name: "Kim",
    };
    println(user.address.city);
    user.name = "Lee";
}
```

literal은 모든 named field를 정확히 한 번 지정해야 하며 순서는 자유다. field는 타입 alignment에 맞춰 배치되고 struct size는 최대 field alignment의 배수다.
Mutable local 또는 mutable reference에서 `user.address.city = "Busan"`처럼 연속된
struct·tuple field를 갱신할 수 있다. RHS를 평가한 다음 이전 field를 drop하고 교체한다.
RHS의 `?`가 반환하면 최종 교체는 수행하지 않지만 RHS가 이미 수행한 변경은 되돌리지 않는다.
중첩 field 대입의 index·temporary root는 지원하지 않는다.

primitive-only struct는 copy value다. String/Vec 또는 이를 포함한 struct는 owned value로
재귀 clone/move/drop된다. managed field 읽기는 부분 move 대신 clone한다. inherent
`impl` method와 `self`/`&self`/`&mut self`, `Vec<Struct>`, File/Ptr field를 지원한다.
struct equality와 destructuring/default field는 아직 없다.
