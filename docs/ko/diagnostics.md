# 의미 진단

기존 `file:line:column: error:` 및 `note:`/`help:` 출력 형식을 유지한다. Compiler의
내부 ID 대신 source의 local/field 이름과 위치를 표시한다.

```text
app.xen:4:5: error: cannot mutate 'data' while it is borrowed
app.xen:3:14: note: shared borrow of 'data' originates here
app.xen:5:9: note: borrow may remain live through this use
```

Borrow origin은 Semantic IR loan identity가 가리키는 원래 source span이다. Reference가
local·branch를 거쳐도 같은 identity를 유지하며 call summary에서 만든 borrow에는
callee 위치와 caller의 forwarding call을 함께 표시한다. Reference parameter의 원본을
현재 함수 안에서 알 수 없는 경우에는 parameter 위치를 설명한다.
Reference parameter의 referent도 내부 음수 ID나 `parameter` placeholder 대신 실제
parameter 이름과 field 경로를 표시한다.

이후 사용 note는 기존 liveness의 place/path 규칙을 재사용한다. 현재 충돌 뒤의
reachable CFG를 제한된 탐색으로 따라가며 재정의는 추적을 끊고 cleanup/drop은 사용으로
세지 않는다. Branch와 loop의 conservative 분석을 반영해 “may remain live”라고 쓴다.
256개 CFG 탐색 지점 안에서 witness를 찾지 못하면 이후 사용 note를 생략한다. 이 탐색은
진단에만 쓰이며 compiler의 허용/거부 판정에는 관여하지 않는다.

Move 오류는 기존 move span을 유지하고, 전체 aggregate 사용이 partial move 때문에
실패하면 `p.left` 같은 실제 unavailable field를 표시한다. Branch별 move 위치가 다르면
확정 원인을 고르지 않으며 primary 오류와 field 정보는 유지한다. 초기 storage 선언을
실제 move처럼 note로 표시하지 않는다.

Capability 오류는 연산 위치, capability가 없는 enclosing 함수·명시적 block/scope와
필요한 최소 `bb` 또는 `explc` 경계를 설명한다. Scope escape는 borrow 위치와 owner의
scope 시작 위치를 표시한다. AST span은 시작 line/column만 보유하므로 종료 range나
scope의 닫는 brace 위치를 만들어내지 않는다.

회귀 검사는 `tests/native_core_test.ml`의 source span·secondary note 검사와 기존
Semantic IR CFG/metamorphic 거부·허용 검사를 함께 사용한다. 진단 개선을 위해 safety
검사를 완화하거나 별도의 path-sensitive checker를 추가하지 않았다.
