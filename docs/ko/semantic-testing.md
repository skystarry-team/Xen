# Semantic IR 생성·변형 검증

검증 경로는 현재 Xen 구현의 AST → 단형화 → Typed AST → 비 SSA CFG → 의미 분석·cleanup
→ native backend를 그대로 사용한다. 별도의 Rust/LLVM 의미 모델이나 새 compiler
backend를 두지 않는다. 새 문법이 기존 IR 연산으로 내려가면 공통 분석 속성을 재사용하고
lowering 회귀만 추가하는 것이 기준이다.

## 실행과 재현

```bash
make test QUICKCHECK_MODE=sweep QUICKCHECK_DEPTH=standard QUICKCHECK_SEED=20261006
make semantic-test QUICKCHECK_DEPTH=standard QUICKCHECK_SEED=20261006
python3 tests/property/runner.py --mode semantic --seed 20261006 --case 0
```

`make test`는 기존 native 회귀와 전체 언어 QuickCheck 그룹을 먼저 실행한다. 이어서
semantic 생성 그룹과 OCaml IR 속성을 실행한다. `all`/`sweep`에는 semantic 그룹이
포함된다. depth별 case 예산은 기존 runner와 같다. seed와 case index는 시작 시
출력하며 한 case만 재현할 수도 있다.

2026-10-06 검증: 위 전체 기준 명령이 통과했다. 새 semantic 그룹은 seed `20261006`의
200개 시나리오·950개 source 형태, 85개 raw CFG 형태 및 초기화/parent-child negative
control과 multi-destination store/call overwrite를 검사했다. 추가로 seed `20261007`,
deep 예산의 1,000개 시나리오·4,750개 source 형태가 통과했다.
생성기 자체의 일곱 unit property도 통과했다.

## 생성 모델

`tests/property/semantic.py`는 세 owner와 세 Bool 입력으로 구성된 작은 reference
DAG를 만든다. owner는 scalar 또는 `Cell { value: Int }` aggregate이며 같은 원본·충돌
모델로 직접 dereference와 aggregate field 접근을 검증한다. leaf는 borrow 또는 직전 reference local의 복사이고, branch는 중첩
`if`다. 이전 합류 값을 다시 새 borrow와 합류시키는 과정을 반복한다. 독립 oracle은
가능한 owner 집합과 실제 실행에서 선택된 owner만 계산한다. compiler의 loan identity,
liveness, summary 코드를 복제하지 않는다. 세 Bool의 여덟 값 조합을 평가해 위험 경로가
실제로 존재하는 경우에만 unsound acceptance라고 판정한다.

일부 mutable parent DAG는 shared child로 다시 빌린다. 명시적 `&*parent`와 `&T`
문맥 coercion을 forwarding·분기 변형으로 대조하며 child를 통한 읽기, 원본 변경과
loop 재사용을 같은 독립 oracle로 검사한다. 부모와 alias의 변경 제한·child 권한은
별도 raw IR 24개 block/edge 변형으로도 검증한다.

수락/거부 짝은 owner 변경을 마지막 사용 전후로 옮기거나, shared/mutable borrow를
바꾸거나, 마지막 사용을 loop의 다음 iteration에 다시 두어 만든다. mutable reference
사용과 간접 호출도 포함한다. 이외에는 지원되는 Slice field struct 복사, definite/conditional
method summary와 재귀 호출, File의 부분 이동·sibling 사용·양쪽 분기의 재초기화,
owner scope escape, module/capability 경계와 금지된 borrowed Vec element를 생성한다.
family/action을 순환시켜 작은 예산에서도 허용과 거부 경계를 탐색한다.

File 실행은 `/dev/null`을 사용한다. fd 한도를 32로 낮춘 상태에서 반복 호출해 정상
종료·`break`·`continue`·`?`의 pending 인자/field cleanup, 교체·move·중복 close·fd 재사용을
검사한다. runtime failure와 panic에는 unwind를 요구하지 않는다. Ptr의 수동 해제
정책도 바꾸지 않는다.

## 정당화한 변형

- reference/Slice를 fresh local 여러 개에 전달: 이 타입의 binding은 clone/move가 아닌 복사다.
- 같은 reference/Slice 값을 양쪽 `if`/Bool `match` arm에서 선택: 새 owner를 생성하지 않는다.
- reference DAG의 borrow leaf를 같은 borrow를 생성하는 양쪽 branch로 변형: 선택된
  origin은 같지만 loan 생성 위치가 달라져 provenance 합류를 직접 검증한다.
- 분기 조건 `c`를 `c && true`로 변경: 부작용 없는 Bool에서 같은 값을 만들며 단락 CFG를 거친다.
- reference read를 `&&`/`||`의 RHS에 추가: 같은 initialized reference의 scalar 관찰을
  기존 마지막 사용 앞에 추가한다. owner 변경·move·새 borrow를 만들지 않는다.
- 모든 선언과 사용을 redundant block 또는 `if true` 내부에 함께 배치: 외부로 흐르는
  definite assignment나 owner lifetime을 바꾸지 않는다.
- raw CFG block/edge 분할과 ID·entry·edge를 일관되게 바꾼 block 순서 반전: 연산 순서,
  local ID, scope와 경로를 보존한다.

managed String/Vec에 일반적인 intermediate binding을 추가하면 clone 의미가 달라지고,
File에서는 move와 cleanup 순서가 달라진다. 이런 변형은 범용 metamorphism으로 쓰지 않는다.
unconditional overwrite를 else 없는 `if true`로 감싸는 것도 사용하지 않는다. 분석이
상수 조건을 제거하지 않아 must-overwrite가 conditional effect로 바뀔 수 있기 때문이다.
reference 반환·재대입·reference field·reference-to-reference 등 현재 금지된 문법은
생성하지 않는다. implicit receiver와 explicit borrow의 capability 차이를 보존한다.

`tests/semantic_ir_test.ml`은 실제 프런트엔드에서 raw IR을 얻어 분석 전 CFG를 변형한다.
cleanup이 들어간 checked IR을 다시 분석하지 않는다. 수락/거부가 유지되는지 비교하고,
성공한 결과는 기존 verifier로 검사한다. `Storage_dead`와 `Replace`의 실제 Local/Place
ID를 따라 삽입된 Drop을 비교한다. 별도의 verifier 대신 기존 verifier에 잘못된 ID,
parameter/declaration/scope, projection, 취득, operator, call 및 layout을 넣어 거부를 검사한다.

## 실패 분류와 축소

`unsound_acceptance`는 실제 가능한 위험 경로나 명시된 타입/capability 제한을 compiler가
수락한 경우다. `conservative_rejection`은 독립 모델상 안전한 프로그램의 의미 분석 거부다.
둘을 동등한 실패로 취급하거나 거부를 없애기 위해 안전 검사를 완화하지 않는다.
parser/static type 실패는 명시적인 제한 검사가 아닌 경우 `generator_error`로 분류한다.
compiler crash/timeout, runtime mismatch, source 형태 간 disagreement도 별도로 기록한다.

실패 시 `tests/property/found_bugs/semantic_<seed>_<index>_<variant>/`에 원본/변형 source,
모델 parameter, diagnostics와 재현 명령을 저장한다. 최대 40번의 구조적 축소를 통해
branch/forwarding depth와 loop 등 모델 node를 줄인다. 각 후보의 기대값을 다시 계산하고,
원래 실패 분류, 변형과 base/변형의 수락·거부 방향을 유지하는 후보만 채택한다.
재현되지 않는 timeout도 최초 diagnostics를 보존해 artifact를 저장한다.
구 mixed 문자열 축소기를 재사용하지
않는다. 이 directory는 생성 artifact이므로 git에서 제외한다. 실제 compiler 결함은
축소된 source 또는 IR을 영구 OCaml 회귀로 옮긴다.

현재 abstraction은 Bool 값의 관계를 추적하지 않는다. 같은 조건의 반복에서 실제
도달 불가능한 origin도 합류될 수 있고, dereference 뒤의 aggregate liveness와 dynamic
index도 보수적이다. 이런 이유의 safe rejection을 해결하려고 symbolic/path-sensitive
분석을 도입하지 않는다. 생성 oracle의 조건 열거는 오분류 방지를 위한 테스트 쪽 계산이다.

`Place.Element`의 타입과 index operand 초기화는 검사하지만, collection descriptor와
element의 초기화 상태는 아직 별개 cell로 연결하지 않는다. initialized `Vec<Int>`와
index의 Element-place read도 현재 보수적으로 거부된다. positive control로 이 제한을
명시적으로 고정했다. 현행 source indexing은 `Index`/`Vec_get`/`Slice_get` rvalue로
내려가며 생성 실행에서 수락·동작을 검사한다. 새로운 lowering에서 Element place를
사용하려면 이 분석 경계를 먼저 구현해야 한다. rejection-only 검사로 전체 projection
지원이 검증됐다고 간주하지 않는다.

## 이번에 확인한 결함

### Borrowed Vec element 제한 누락: unsound acceptance

```xen
struct V { s: Slice<Int> }
fn main() {
    let mut a = [1];
    let v = [V { s: a.as_slice() }];
    a.push(2);
    println(v[0].s[0]);
}
```

기대: `Vec<V>`의 borrowed element 타입을 거부한다. 이전 실제 동작: inferred 및
`let v:Vec<V>` 모두 check 성공. 시그니처에서는 같은 타입을 거부했다. 일차 원인은
checker의 타입 제한 검증이 값 생성/local 경계에 적용되지 않은 것이다. Vec를 leaf로
다루는 provenance 분석에서는 이 unsupported element의 loan이 전달되지 않았다.
공통 expression type validation과 field declaration 검증으로 기존 제한을 일관되게
적용하며, Vec의 borrowed element 지원을 추가하지 않는다.

### 초기화되지 않은 reference projection: IR unsound acceptance

```text
locals: l0: &Int, l1: Int
b0:
  live l0
  live l1
  v1 = copy l0.*
  return
```

기대: l0의 초기화되지 않은 read를 거부한다. 이전 실제 동작: verifier와 의미 분석 모두
수락했다. public source는 initialized binding을 요구하므로 이 사례는 내부 IR 경계의
결함이다. `Semantic_analysis.resolve`가 빈 loan 집합을 빈 접근 경로로 변환해 검사할
referent가 없어진 것이 원인이다. Deref/Element operand의 초기화를 공통 place 해석
경로에서 검사한다. `test_initialization`에 최소 IR을 고정했다.

생성기 자체에서는 Slice 조건식/전달 local의 type annotation 누락을 수정했다. Xen의
현재 inference 제약이며 provenance 결함으로 보고하지 않는다. `repeat`도 numeric 전용이므로
borrowed aggregate 제한 생성에는 사용하지 않는다.

### 같은 owner의 배타적 mutable loan: conservative rejection

```xen
#global[explc]
fn exercise(c: Bool) {
    let mut a = 1;
    let r = if c { &mut a } else { &mut a };
    println(*r);
}
fn main() { exercise(true); }
```

기대: 한 branch만 실행하므로 reference 사용을 수락한다. 이전 실제 동작:
`cannot access 'a' while it is borrowed`로 거부했다. `Semantic_analysis`는 합류된
reference의 loan을 하나씩 접근할 때 다른 배타적 loan을 독립된 충돌로 판단했다.
같은 ancestry/mutability/reservation을 가진 대체 loan만 해당 값의 접근 권한에 포함한다.
parent와 child의 ancestry가 다르면 계속 보수적으로 검사한다. live child를 복사해
유지하면서 parent/child 중 하나를 합류시킨 뒤 변경하는 raw IR은 반드시 거부하는
negative control로 고정했다. 독립 Slice, overlapping mutable call arguments도 거부한다.
이 규칙은 deref, builtin receiver, direct/indirect call에 공통으로 적용한다. call summary의
strong update 여부는 loan identity 수가 아닌 서로 다른 실제 destination 수로 판단한다.

### 여러 destination을 통한 대입: IR unsound acceptance

```text
struct P { file: File }
a, b: P       // 각각 initialized File로 시작
move a.file
move b.file
r = if flag then reserved-mut-borrow a else reserved-mut-borrow b
replace r.*.file <- initialized File
read a.file
read b.file
```

기대: 하나만 재초기화되므로 양쪽 read를 수락할 수 없다. 이전 실제 동작: 이 최소 IR을
의미 분석이 수락했고, 새 회귀가 수정 전 실패했다. `Initialize`/`Replace`가 가능한 모든
destination에 `definite:true`로 쓰면서 이동 상태와 summary의 must-write를 제거했다.
공통 store transfer에서 실제 destination이 하나일 때만 strong update와 must-write를
기록한다. 여러 대상이면 이전 provenance를 병합하고 moved/uninitialized 상태를 유지한다.
CFG 분할/반전에서도 거부를 검사한다. 호출 summary에도 같은 실제 field의 여러 loan과
서로 다른 field의 loan을 구별하는 수락/거부 control을 추가했다.

### 종료된 storage를 Eval로 복구: IR lifetime 결함

```text
live x
x = 1
dead x
x = 2       // Eval; Storage_live 없음
read x
```

기대: storage 종료 뒤의 definition/read를 거부한다. 이전 `Eval` transfer는 storage
상태를 검사하지 않고 initialized cell을 새로 썼으므로 이 경로를 복구할 수 있었다.
정상 parameter는 처음부터 live이며, 반복 cleanup의 Storage_dead/Drop은 계속 허용한다.
의미 read/write/definition은 기존 forward state의 storage 집합을 검사한다.
`dead x; live x; x=2; read x`와 initialized reference는 positive control로 수락하고,
Storage_live 없는 정의는 거부한다. 이 사례도 source가 아닌 내부 IR 경계 회귀다.
