# 스코프 AOT 최적화

`#scope[opt]` 안의 코드만 컴파일 시점에 최적화한다. `build`, `run`, `test`의
기본값은 `--opt=basic`이며 스코프 밖 연산과 원래 callee 함수는 보존한다.
`--opt=off`로 변환을 끈다. 전역 최적화 CLI는 아직 없으며 `#global[opt]`와
함수 `#![opt]`는 거부한다.

```xen
fn calculate(n: Int, scale: Int) -> Int {
    let mut i = 0;
    let mut total = 0;
    #scope[opt] {
        while i < n {
            let weight = scale * scale + 3;
            total = total + weight + i;
            i = i + 1;
        }
    }
    return total;
}
fn main() { println(calculate(10000, 7)); }
```

```sh
xen run examples/opt_loops.xen
xen run examples/opt_loops.xen --opt-report
xen run examples/opt_loops.xen --opt=off
```

원본 소스 검사와 cleanup을 먼저 완료한다. 지정한 스코프의 적격 leaf 호출을
펼치고, 적격인 인접 루프 퓨전·루프 불변식 이동과 scalar 계산 최적화를 수행한 뒤 타입·초기화·
storage 수명·borrow를 재검증한다. Cleanup을 다시 삽입하지 않는다. 공통 IR에서
수행하므로 Linux x86-64와 ARM64에 함께 적용된다. 최적화 오류는 진단한다.

고정폭 정수와 Bool의 상수 접기·복사 전파·동일 입력 중복 계산 제거·미사용 안전
임시 정의 제거를 지원한다. 실행 중 들어오는 값도 참여하며 wrapping과
signed/unsigned 비교 의미를 유지한다. 내부 일반 block은 `opt`를 상속한다.
CFG·lexical 경계, 호출, borrow·projection·메모리, allocation, managed clone/drop,
syscall과 오류 가능 연산에서 계산 영역을 나눈다. Float·나눗셈·나머지·checked
conversion은 변환하지 않는다. Ownership summary를 순수성의 증거로 쓰지 않는다.

Leaf 펼치기는 한 block·한 scope의 정수·Bool 함수 중 계산·취득·저장 연산이
32개 이하이고 효과와 오류 가능 연산이 없는 직접 호출을 대상으로 한다.
`opt` 안의 호출만 펼치고 원래 함수는 유지한다. 참조·raw memory capability는
일치해야 하지만 `opt` 자체는 capability를 추가하지 않는 최적화 힌트다.
Source 위치와 논리적 호출 진입·종료 및 4096 frame 제한을 보존한다. 호출자당
추가 IR 연산 256개·padding을 포함한 추가 scalar slot 256바이트로 제한한다.

루프 불변식 이동은 `opt` 안의 Bool 조건·직선 scalar 본문·backedge·단일 출구를
대상으로 한다. 본문은 외부 진입이 없는 여러 block일 수 있다. 내부 분기·중첩 루프·
효과·주소가 취해진 local·capability 변경이 있으면 그 루프는 제외한다.
적격인 내부 루프는 독립적으로 최적화할 수 있다. 실제 쓰기와 사용 순서를 확인해
모든 사용보다 먼저 정의되는 단일 정의 private 임시 식만 선택한다. 입력은 루프에서
바뀌지 않거나 먼저 이동한 임시 값이어야 한다. 사용자 저장과 loop-carried 값은 유지한다.

불변 산술과 그 의존 값은 새 preheader의 scalar storage에서 한 번 계산한다.
원래 정의는 그 결과를 읽으며 복사 전파로 불필요한 임시 계산을 줄인다. 원래 storage와
cleanup은 유지하고 새 storage는 단일 출구에서 종료한다. 0회 반복에서도 의미가
같은 순수·비실패 연산만 조건 앞으로 이동한다. 함수당 추가 불변식 storage는
32 scalar slot 이하이며 런타임 encoding 기록·실행 페이지 제한은 없다.

## 구간 분석과 루프 퓨전

공통 IR 위의 분석 표현은 CFG의 predecessor, 루프 header·본문·backedge·출구,
scalar 읽기·쓰기와 주소가 취해진 local을 기록한다. 별칭은 함수명·lexical 경로·
구간 번호로 만든다. CFG block 배열 순서를 실행 순서로 취급하지 않는다.
Leaf 펼치기 이후 루프 퓨전을 계획하고, LICM과 scalar 변환을 이어서 수행한다.
MLIR의 [구조 보존 방식](https://mlir.llvm.org/docs/Rationale/RationaleLinalgDialect/)과
TVM의 [효과 경계와 그래프 분할](https://github.com/apache/tvm/blob/main/docs/arch/fusion.rst)을
참고한 첫 제한적 구현이며 외부 ML 컴파일러 의존성을 추가하지 않는다.

같은 lexical `opt` 구간의 인접한 두 정수 루프가 동일한 상수 초기값·불변 상한·
`<` 조건·증가량 1을 가지면 퓨전 후보가 된다. 두 induction local은 서로 달라야
하고 정수 타입은 같아야 한다. 본문은 직선 scalar 코드여야 하며 한 루프의 쓰기를
다른 루프가 읽거나 덮어쓰면 거부한다. 루프 사이에는 scalar 임시 cleanup만 허용한다.
생략할 조건 블록은 단일 정의 private 임시 계산만 허용하며, 자기 이전 값을 읽는
계산과 사용자 변수 쓰기는 거부한다. 두 번째 header와 연결 구간으로의 외부 진입도
거부한다.
함수당 최대 32쌍을 합친다. 호출·borrow·projection·managed storage·실패 가능 연산·
내부 분기·capability 변경은 경계로 남긴다. 두 반복 변수의 최종값과 원래 storage
cleanup을 유지하고, 두 번째 반복 조건의 반복 평가를 제거한다. 배열 중간 버퍼를
제거하는 producer-consumer 퓨전이나 SIMD는 아직 포함하지 않는다.

```sh
xen run examples/opt_fusion.xen --opt-report
xen run examples/opt_fusion.xen --opt=off
```

## 정확한 prefix 캐시

`--opt-cache=<directory>`는 컴파일 실행 사이에 전방 scalar 분석·변환 결과를
보관한다. 기본 실행은 디스크 캐시를 생성하지 않는다. `build`, `run`, `test`에서
`basic`과 함께 사용할 수 있으며, `check`와 `off`에서는 사용법 오류다.

```sh
xen run examples/opt_fusion.xen --opt-cache=.xen-opt-cache --opt-report
# 같은 명령을 다시 실행하면 cache=hit를 확인할 수 있다.
```

별칭은 추적용이며 캐시 유효성을 증명하지 않는다. 각 항목은 검증한 부모 prefix,
현재 입력 전체와 별칭을 직접 비교한다. 해시는 파일을 찾는 데 사용하고 충돌 시
별도 항목을 만든다. 부모가 없거나 깨졌거나 일치하지 않으면 그 지점과 이후 의존
prefix를 다시 생성한다. 입력 타입·효과 계약만 같다는 이유로 재사용하지 않는다.
현재 계보는 CFG 순회에 따른 보수적인 누적 prefix이므로 독립적인 뒤쪽 갈래도
무효화할 수 있다. 함수의 local/scope·CFG 메타데이터 변경은 전체 함수 context를
무효화할 수 있으며, 선행 입력의 값만 바뀌는 경우에는 그 이전 prefix를 유지한다.

Context에는 최적화 설정, compiler 실행 파일 fingerprint, CLI target, aggregate
layout과 사용한 callee의 원본·ID를 포함한다. 소스 검사는 항상 먼저 수행한다.
캐시에는 안전한 scalar 전방 변환만 저장하고, 뒤쪽 사용에 의존하는 liveness·DCE,
루프 분석·퓨전 계획과 최종 IR 재검증·backend 코드 생성은 매번 수행한다.
따라서 뒤에서 앞쪽 임시 값을 새로 사용해도 오래된 DCE 결과를 재사용하지 않는다.
최종 재검증에 성공한 뒤에만 캐시 항목을 발행한다.
발행 시 부모 항목을 다시 확인하고, 다른 빌드가 같은 파일 슬롯을 먼저 차지했다면
내용 전체가 일치할 때만 인정한다. 불일치한 부모의 자식과 별칭은 발행하지 않는다.

파일은 checksum이 있는 텍스트 형식이고 항목당 최대 1 MiB까지 읽는다.
OCaml 객체를 디스크에서 역직렬화하지 않는다. 형식 오류·checksum 불일치·알 수 없는
scalar 변환은 miss로 처리한다. 캐시 I/O가 불가능하면 정상 분석으로 진행한다.
이력 항목은 보존되며 사용하지 않는 캐시 디렉터리는 지워도 된다.

`--opt-report`는 `basic`에서 영역의 입력·출력 타입, 분리 이유, 변환 횟수,
펼친 호출 수, `opt loop ... hoisted=...`, `opt loop-fusion ... fused|split`,
`opt prefix ... alias=... parent=... cache=hit|miss reason=...`를 stderr에 출력한다.
`run`의 `--` 뒤는 프로그램 인자다.

배열·tile 기반 퓨전·guard 기반 버전 생성·루프 불변 조건 분리는 후속 작업이다.
루프 간 의존성·효과 분석과 코드 크기·수익성 제한이 필요하며, 분기 추가만으로
알 수 없는 효과를 안전하게 만들 수는 없다. SIMD와 런타임 특화는 아직 없다.
실험적 런타임 JIT, `--jit` 옵션과 `jit` 표기는 제거했다. 기존 코드는
`#scope[opt]`로 바꾸고 이전 CLI 옵션을 삭제한다.
