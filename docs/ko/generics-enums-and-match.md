# 제네릭, enum, match

## 제한적 단형화 generics

함수·struct·enum은 comma-separated type parameter를 가질 수 있다. 함수 호출의 type argument는 전부 생략해 인자 타입으로 추론시키거나 전부 명시한다. concrete instance는 canonical type별로 한 번만 생성되어 native backend로 전달된다.

```xen
fn identity<T>(value: T) -> T { return value; }
struct Pair<T,U> { first: T, second: U }

fn main() {
    let pair = Pair<I32,String> { first: 7, second: "x" };
    println(identity(pair.second));
}
```

generic body에서는 binding, assignment, move, return, aggregate 생성, generic 호출과
signature가 알려진 함수 값 callback을 사용할 수 있다. 알려진 tuple·enum 구조의
`match` 분해, concrete field 연산과 알려진 container 형태의 연산도 지원한다.
element 제한은 concrete instance에서 계속 검사한다. unconstrained `T`의 산술·비교·
builtin·field·method·indexing은 추론 local, pattern binding, projection과 호출 결과를
거쳐도 거부된다. annotation이나 명시적 타입 인자로 `T`를 concrete 타입으로 바꿀 수 없다.

기존 구조적 iterator 호출은 예외다. abstract iterator의 `iterator.next()`는 concrete
타입의 `next(&mut self) -> Option<Item>` 계약을 요구한다. partial type argument,
overload, trait/bound와 method-local type parameter는 없다. `impl<T> Type<T>`의
기존 inherent method는 지원한다.
canonical builtin 호출은 같은 이름의 local이 있어도 기존 builtin 우선순위를 따른다.
local callback의 signature로 builtin의 타입 요구를 바꿀 수 없다. `box`의 기존 사용자
함수·local 함수 shadowing 규칙은 유지한다.

```xen
fn unwrap_or<T>(value: Option<T>, fallback: T) -> T {
    return match value {
        Option.Some(item) => item,
        Option.None => fallback,
    };
}
```

일반 함수 호출이므로 두 인자는 호출 전에 평가된다. move-only 값은 소유권을
이동하고 선택되지 않은 값은 정리한다. 이 예제는 새 prelude API가 아니다.

### 함수 호출의 제한적 타입 인자 추론

인자의 확정된 정적 타입으로 모든 타입 매개변수를 유일하게 결정할 수 있으면
타입 인자를 생략할 수 있다. 추론은 컴파일 시점에 수행하며 명시적 호출과 같은
단형화·타입 검사·코드 생성 경로를 사용한다.

```xen
fn identity<T>(value: T) -> T { return value; }
fn first<A, B>(a: A, b: B) -> A { return a; }

fn main() {
    let x: I64 = 42;
    let y: String = "hello";
    let a = identity(x);       // T = I64
    let b = identity<I64>(x);  // 기존 명시적 호출
    let result = first(x, y);  // A = I64, B = String
    let narrow = identity(i32(7)); // T = I32
}
```

같은 타입 매개변수에 `I32`와 `I64`가 대응하면 충돌 오류가 발생한다. 공통 타입
선택이나 암묵적 숫자 변환은 하지 않는다. 문맥 없는 정수·실수 literal의 기본 타입은
각각 `I64`·`F64`이며 `Int`·`Float` 호환 이름은 canonical 타입과 동일하게 취급한다.

인자에서 결정되지 않는 타입 매개변수는 오류 메시지에 이름을 표시하고 명시적 호출을
안내한다. 예를 들어 `fn create<T>() -> T`에 대한 `create()`는 다음 진단을 낸다.

```text
error: cannot infer type parameter 'T'
help: specify all type arguments explicitly, for example: create<I64>()
```

안내의 타입은 예시이므로 실제 필요한 타입을 지정해야 한다. 반환값의 기대 타입이나
함수 본문은 추론 근거로 사용하지 않는다. `let value: I32 = identity(1)`은 인자에서
`I64`를 추론해 타입 불일치가 되고, `identity<I32>(1)`은 명시적 인자의 기존 literal
문맥을 사용한다. `let value: Option<I32> = identity(Option.None)`도 추론할 수 없으므로
`identity<Option<I32>>(Option.None)`으로 작성한다. 반환 annotation으로 타입 인자를
결정하던 호출은 이처럼 명시적 호출로 바꿔야 한다.

tuple을 포함한 concrete 복합 타입 전체도 `T`에 직접 대응할 수 있다. 기존의
`Vec<T>`, struct·enum, reference, 함수 타입 내부 대응 추론은 유지한다.
tuple 내부 타입 매개변수의 재귀적 추론은 지원하지 않는다. 알려진 인자 타입의 구조를
대응하는 기능이며 범용 제약 해결기가 아니다.
타입 매개변수를 전부 결정할 수 없거나 빈 collection·payload 없는 생성자만 있어
정보가 부족하면 명시적 타입 인자가 필요하다. 부분 타입 인자 생략은 지원하지 않는다.

## enum과 tuple

`Option<T>` (`None`, `Some(T)`)와 `Result<T,E>` (`Ok(T)`, `Err(E)`)는 자동 prelude에 포함된다. 같은 이름의 사용자 타입은 선언할 수 없다.

enum 생성자에 같은 enum의 concrete 기대 타입이 있으면 payload 검사 전에 제네릭
인자를 확정한다. 선언 타입, 함수의 parameter·return 타입 등으로 전달된 기대 타입은
variant payload와 `Vec` literal의 각 원소에 재귀적으로 전달된다. 따라서 다음 코드는
중첩 생성자에 `Tree<Int>`를 반복해서 명시하지 않아도 된다.

```xen
enum Tree<T> {
    Leaf(T),
    Branch(Vec<Tree<T>>),
}

fn main() {
    let tree: Tree<Int> = Tree.Branch([
        Tree.Leaf(3),
        Tree.Branch([Tree.Leaf(4), Tree.Leaf(5)]),
    ]);
    let options: Vec<Option<I32>> = [Option.Some(1), Option.None];
}
```

기대 타입이 없으면 기존 payload 제약으로 추론한다. 예를 들어 `Tree.Leaf(1)`은
`Tree<Int>`로 추론되지만 `Option.None`이나 `Tree.Branch([])`만으로는 타입 인자를
정할 수 없다. 이런 경우에는 annotation 또는 명시적 type argument가 필요하다.
다른 enum의 기대 타입에서 타입 인자를 가져오거나 미확정 인자를 기본값으로 채우지 않는다.

`Result<T,E>` 뒤의 postfix `?`는 `Ok(value)`에서 `value: T`를 만들고 `Err(error)`에서 현재 함수를 즉시 반환한다. 현재 함수는 반드시 `Result<U,E>`를 반환해야 하며 오류 타입은 정확히 같아야 한다. 일반 postfix 표현식이므로 `call()?.field`, 함수 인자, 조건식과 match arm에서도 사용할 수 있다. `Option`, 암시적 오류 변환과 `Unit` 함수에서의 전파는 지원하지 않는다.

Tuple value/type은 각각 `(a, b)`, `(I64, String)`이며 `()`는 Unit이다. 원소는 0부터 시작하는 `.0`, `.1` 문법으로 읽고 mutable local의 직접 원소는 같은 문법으로 대입할 수 있다. `__item_N` layout field는 compiler-private이다. Singleton tuple과 tuple equality는 제공하지 않는다. Tuple은 값 생성·전달·반환, generic instantiation, match pattern에 사용할 수 있다.

enum payload는 고정 크기 값 layout에 직접 포함된다. 따라서 enum 자신, 또는 enum/struct를 통해 되돌아오는 직접·간접 순환은 허용하지 않는다.

오류 타입을 명시적으로 바꾸려면 concrete named callback을 받는 `std.result.map_err`를
`?` 앞에서 사용한다. `std.option.unwrap_or`는 eager fallback을 제공한다.

## Exhaustive match

```xen
let option = Option.Some("xen");
let text = match option {
    Option.Some(value) => value,
    Option.None => "none",
};
println(text);
```

Variant, tuple, Bool match는 내부 constructor까지 재귀적으로 exhaustiveness를 검사한다. 숫자, Float, String은 열린 값 집합이므로 binding 또는 `_` pattern이 필요하다. 앞 arm에 완전히 가려진 pattern은 오류다. match arm은 expression 또는 tail expression을 가진 block이다.

Pattern에는 variant, tuple, 타입이 맞는 literal, binding, `_`를 임의 깊이로 조합할 수 있다.
guard, struct pattern과 destructuring assignment는 아직 지원하지 않는다. generic body의
알려진 enum·tuple 구조는 분해할 수 있다. abstract `T`에는 binding·wildcard만 허용하며
concrete literal·constructor pattern으로 타입을 제한할 수 없다.

Generic aggregate는 동일한 concrete instance로 돌아오는 재귀가 `Box` 또는 `Vec` 경계
아래에 있을 때 허용된다. `Node<T> { next: Option<Box<Node<T>>> }`,
`Node<T> { children: Vec<Node<T>> }`와 상호 재귀는 유한하게 단형화된다.
직접 value-layout 재귀와 `Growing<T> { children: Box<Growing<(T,T)>> }`처럼 타입
인자가 계속 성장하는 재귀는 거부된다. `Slice`와 `Ptr`은 이 재귀 허용 경계가 아니다.
Owning 타입과 사용자 정의 inline `Box`의 구분은 [Box 문서](box-and-recursive-aggregates.md)를 따른다.

enum의 tag와 inactive payload는 compiler 내부 표현이며 field API가 아니다. 따라서
`value.__tag`와 `value.__payload_Some`처럼 representation field에 직접 접근하거나
대입할 수 없고 variant 판별에는
반드시 `match`를 사용한다.

match arm은 statement 위치가 아니라 expression 위치다. 여러 동작이 필요하면 block의
마지막에 결과 expression을 둔다. `break`/`continue`로 바깥 loop를 제어하는 용도로는
쓸 수 없다.

```xen
let value = match option {
    Option.Some(x) => {
        println(x);
        x + 1
    },
    Option.None => 0,
};
```
