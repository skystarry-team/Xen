# Semantic IR 구현 계약

컴파일 경로는 AST → 단형화된 Typed AST → Semantic IR → 의미 분석·cleanup·검증
→ 선택적 최적화·재검증 → 기존 x86-64 encoding·runtime·ELF 생성이다. `Checker.check/check_project`는
`Semantic_ir.checked_program`을 반환하고 `Native_backend.generate`는 이 타입만
받는다. Typed AST는 이름·타입·method 해석을 위한 프런트엔드 내부 표현이다.

Semantic IR의 function/local/value/block/scope ID는 함수 내에서 조밀하며 분석과
cleanup 삽입 뒤에도 바뀌지 않는다. 각 local은 타입, span, 선언 scope, 소유 여부,
parameter/temporary 여부를 기록한다. scope tree에는 effective capability와 선언
Local ID가 남는다. `Place`는 local 및 field/index/deref projection이다.

CFG는 비 SSA다. 모든 rvalue operand는 storage ID이고 중첩 expression이나 statement
tree를 포함하지 않는다. `Branch`, `Jump`, `Return`, `Stop`으로 block을 종료한다.
조건식·단락 연산·match 결과는 숨겨진 local에 기록하며 종료하는 arm은 합류하지
않는다. `?`의 오류 경로는 같은 함수의 반환 경로다.

`Read`는 관찰용 취득, `Copy`는 복사 가능한 값의 취득, `Clone`은 소유 값 복제,
`Move`는 소유권 이전이다. File과 Ptr wrapper의 선형성 및 명시적 consuming 연산은
layout의 trivial-copy 속성과 별도로 처리한다. borrow 생성과 receiver 예약,
초기화·교체, storage 종료와 cleanup을 operation으로 기록한다.

의미 분석은 reachable CFG의 초기화·부분 이동·field provenance와 역방향 liveness를
고정점까지 계산한다. 집합은 내부 트리 모양이 아닌 의미적 동등성으로 비교한다.
참조 복사는 loan identity를 보존한다. 새 대여는 생성 위치와 호출 위치를 구분하고
부모 대여 관계를 유지한다.
명시적 shared reborrow와 mutable-to-shared coercion은 모두 기존 `Borrow(Deref(place))`로
정규화해 새 shared identity를 생성한다. Referent 복사나 타입만 바꾸는 cast는 하지 않는다.
중첩된 mutable parameter 원본은 호출 경계에서 거부한다.
호출 summary의 입력과 반환 원본은 호출 전 snapshot에서 해석한다. 가능한 effect와
확정 덮어쓰기·초기화의 수렴을 나누어 재귀 호출도 검사한다. 정적 field별 liveness를
보존하고 dynamic index와 참조 뒤의 저장소는 보수적으로 추적한다.
호출 summary는 mutable parameter의 field별 변경,
정상 반환 경로에서의 확정 덮어쓰기와 provenance 입력 origin을 기록한다.

cleanup은 inner scope부터 local 선언·temporary 생성 역순이다. RHS를 독립 storage에
준비한 뒤 기존 값을 drop하고 교체한다. pending 인자·부분 aggregate와 반복 조건의
임시값도 수명 경계에서 정리한다. backend는 명시적 Drop과 이동 상태를 소비하고
소유 field의 drop flag를 사용한다. 호출 summary가 변경하는 caller field의 drop 상태도
명시적으로 갱신한다. File close는 초기화된 closed 값을 남기며 Ptr는
자동 해제하지 않는다. runtime error와 panic은 unwind하지 않는다.

`Semantic_ir.verify`는 ID·scope·edge, place projection, operand·operation 타입과
취득 정책, parameter metadata, 선언의 유일성, builtin call contract와 raw capability를
검사한다. 초기화·move·live loan 충돌은 의미 분석이 검사한다.
`Semantic_ir.dump`는 내부 분석·테스트용 CFG 출력기다. 공개
CLI와 언어 문법은 변경하지 않는다.

생성 모델, source/CFG metamorphism, 구조적 실패 축소 및 분류는
[Semantic IR 생성·변형 검증](semantic-testing.md)을 참고한다.

## Owning Box 경계

`Box<T>`는 concrete move-only resource이며 8바이트 GP 값이다. `Box_new`는 준비한
값의 소유권을 allocation으로 옮기고, `Box_take`는 내부 소유값을 결과 storage로
옮긴 뒤 allocation을 해제한다. Borrow의 `Deref` projection은 reference뿐 아니라
Box의 내부 값도 가리킬 수 있다. Reference·Slice·Ptr을 포함한 Box는 source에서 거부한다.

분석은 Box를 ownership leaf로 유지하고 실제 접근한 내부 경로만 `$box` 아래에서
추적한다. 내부 값은 owner와 함께 초기화되며 borrow를 통한 부분 이동은 거부한다.
호출 summary는 owning 경계에서 보수적으로 끝나므로 재귀 순회가 무한히 긴 field 경로를
생성하지 않는다. Borrow identity·parent authority와 owner의 이동·교체 충돌 검사는
기존 규칙을 재사용한다. 호출 summary는 최종 초기화 상태와 별도로 중간 이동 경로를
보존하므로, callee가 필드를 다시 채워도 borrowed Box 내부의 부분 이동은 거부한다.
Verifier도 `Box_new`의 managed 인자와 `Box_take`의 Box 인자가 소유값인지 검사한다.
Cleanup은 Box leaf의 drop flag와 타입별 재귀 drop helper를
사용하며 helper 요청을 concrete type별로 한 번만 처리한다.

## 최적화 계약

`Semantic_opt`는 checked 입력의 leaf를 한 번 펼친 뒤 block·scope 안의 계산 영역에
정방향 값 전파·중복 제거와 역방향 안전 임시 제거를 수행한다. 실행 IR이나 backend를
추가하지 않는다. 영역 metadata는 입력·출력 Local ID/타입, scope·block·span과 분리
이유를 기록한다. 비 SSA 정의 버전과 대표 storage의 현재 버전을 함께 검사하며,
주소가 취해진 root는 함수 전체에서 전파·제거 대상에서 제외한다.

원래 ID·span을 유지하고 펼친 Local/Scope ID는 뒤에 추가한다. 복제 parameter는
`parameter=None`인 일반 local이며 별도 live/init을 갖는다. 반환 storage는 caller에
결과를 복사한 뒤 dead 처리한다. `Logical_call_enter/exit(function_id)`는 제거할 수
없는 경계이고, 원래 호출 위치의 깊이 검사·증가와 결과 복사 뒤 감소를 backend에
전달한다. Verifier는 target·mode와 block 안의 표식 짝·scope를 검사하며 terminator까지
표식이 모두 닫혀야 한다.

`Semantic_analysis.check`는 원본 분석 뒤 cleanup을 삽입한다.
`Semantic_analysis.revalidate`는 동일 분석을 수행하되 cleanup을 재삽입하지 않는다.
최적화 결과는 이 경로의 타입·초기화·storage·borrow 검사 뒤 backend에 전달한다.
사용 범위와 예산은 [최적화 문서](optimization.md)를 따른다.

## 실험적 JIT runtime encoding

공통 `calculation_chunks`는 최적화 후 checked IR의 operation 시작·끝을 제공한다.
Backend는 jit scope의 안전한 scalar 연산을 최대 32개씩 묶고 기존 `emit_operation`의
타입별 recipe를 사용한다. `Machine_ir.frame32/literal64`는 encoding 시점의 재배치
위치·폭·종류를 기록한다. 불변 연산 기록에서 runtime이 코드를 emit/relocate하고
RW → RX 성공 뒤 cache에 공개한다. 별도 실행 IR은 없으며 compiler는 값을 해석해
계산하지 않는다. 계산은 생성한 native code가 현재 caller frame에서 수행한다.
Calls·논리적 frame 표식·borrow·memory·cleanup·CFG terminator는 AOT에 유지한다.
사용 범위와 예산은 [실험적 runtime JIT](jit.md)를 따른다.
