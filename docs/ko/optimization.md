# Native 기본 최적화

`build`, `run`, `test`에 `--opt=off|basic`을 지정한다. 기본값은 `off`다.
`check`는 원본 소스 의미 검사만 수행하며 최적화 옵션을 받지 않는다.

```sh
xen run calculation.xen --opt=basic
xen build calculation.xen --opt=basic --opt-report -o calculation
xen test std.string --opt=basic
```

`--opt-report`는 `basic`에서만 허용한다. 영역의 입력·출력 타입, source 위치,
scope·block, 분리 이유, 변환 횟수와 펼친 호출 수를 stderr에 출력한다.
`run`의 compiler 옵션은 `--` 앞에 두며, 그 뒤는 모두 프로그램 인자다.

기존 Semantic IR과 native backend를 그대로 사용한다. 원본 소스 검사·cleanup을
먼저 완료하고, 제한된 leaf 함수 펼치기 → 계산 최적화 → cleanup 재삽입 없는
타입·초기화·storage 수명·borrow 재검증 순서로 진행한다. 최적화 오류는 진단하며
자동 fallback으로 숨기지 않는다.

계산 영역은 고정폭 정수와 Bool의 상수 접기·scalar 복사 전파·동일 입력 중복 계산
제거·미사용 안전 임시 정의 제거를 지원한다. 실행 중 들어오는 값도 참여한다.
Wrapping과 signed/unsigned 비교 의미를 유지한다. Named local 저장과 주소가 취해진
local, scalar 수명·Drop bookkeeping은 보존한다. 정의 버전으로 재대입·storage 종료
뒤 오래된 대표값 재사용을 막는다. CFG·lexical scope, 호출, borrow·projection·메모리
접근, allocation, managed clone/drop, syscall과 오류 가능 연산에서 영역을 나눈다.
Float 계산·나눗셈·나머지·checked conversion은 변환하지 않는다. Ownership 호출
summary를 순수성의 증거로 사용하지 않는다.

Fusion 대상은 concrete 정수·Bool 인자와 반환값, 한 block·한 scope를 가진
straight-line leaf의 직접 호출이다. 계산·취득·저장 연산은 32개 이하이고 호출·참조·
aggregate·메모리 효과·오류 가능 연산이 있으면 제외한다. 호출 위치의 유효 mode가
같아야 한다. 호출자당 추가 IR 연산은 256개, 추가 scalar slot은 정렬 padding을
포함해 256바이트 이하이며 backend에서 각 scalar slot은 최소 8바이트다.
후보 판정과 펼치기는 계산 최적화 전 한 번만 수행한다. 제한을 넘으면 호출을 유지한다.

이미 평가한 인자를 새 parameter storage에 복사하고, 기존 ID와 source span을
유지한다. 반환값을 caller 결과로 복사한 뒤 반환 storage를 종료한다. 함수 값과
간접 호출을 위한 원래 함수는 유지한다. 결과가 불필요해도 논리적 호출 진입·종료
표식은 남는다. 원래 호출 위치에서 활성 함수 frame 4096개 제한을 검사하고
증가시키며, 결과 이전 뒤 감소시킨다.

AOT 기반은 실험적 [scalar scope runtime JIT](jit.md)에서 재사용한다. 실행 메모리·
operand relocation·caller frame ABI·제한된 process cache를 지원한다. Loop fusion·
SIMD·closure·runtime specialization은 지원하지 않는다.
