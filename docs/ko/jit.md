# 실험적 scalar 런타임 JIT

데모의 실험적 기능이며 인터페이스와 구현이 바뀔 수 있다. 최적화된 AOT 대비
성능 이득은 입증되지 않았고, 측정 샘플의 반복 실행은 약 5.8% 느렸다.
`--jit=off`로 AOT 기준 동작을 선택할 수 있다.

`#scope[jit] { ... }`는 고정폭 정수·Bool 계산을 실행 중 컴파일한다. 원본 소스 전체의
타입·초기화·storage 수명·borrow·cleanup을 먼저 검사한다. 호출·분기·ownership과
cleanup은 기존 native 경로에서 실행한다.

```xen
fn calculate(x: Int) -> Int {
    #scope[jit] {
        let a = x * x;
        let b = x * x;
        return a + b;
    }
}
fn main() { println(calculate(3)); println(calculate(7)); }
```

```sh
xen run calculation.xen --opt=basic
xen run calculation.xen --opt=basic --jit=off
xen run calculation.xen --opt=basic --jit-report
```

`build/run/test`의 `--jit=on|off` 기본값은 `on`이다. 명시한 jit scope에만 적용하며
일반 소스는 AOT로 실행한다. `off`는 같은 소스·checked IR을 기존 AOT emitter로
실행하는 비교 기준이다. `--opt=off|basic`은 encoding 이전의 공통 최적화 패스를
독립적으로 선택하며 기본값은 계속 `off`다. `check`는 소스 검사만 하고 JIT 옵션이나
runtime compiler 실행을 받지 않는다.

대상은 scalar literal·복사·저장, 정수 wrapping 산술·signed/unsigned 비교와 Bool이다.
주소가 취해진 local, borrow·projection·메모리 효과·allocation·managed clone/drop·
호출·syscall·Float·나눗셈·나머지·checked conversion에서 영역을 나눈다. CFG·lexical
scope를 넘지 않는다. Exact mode fusion 계약을 유지하므로 jit scope에서 일반
leaf를 호출하면 AOT 호출 경계로 남는다. `#global[jit]`와 함수 `#![jit]`는 계속 예약 상태다.

영역당 실제 encoding 연산은 32개 이하이고 진입·종료를 포함해 4096바이트 한 페이지에
들어가야 한다. Process cache는 최대 64개 영역·256KiB code mapping이다. 큰 계산은
제한된 영역으로 나누고, 예산을 넘는 영역은 build 시점에 AOT로 남긴다. Runtime의
mmap·mprotect 실패는 원래 영역 위치에서 `JIT compilation failed`를 출력하고 종료
상태 1을 낸다. 실행 중 실패를 AOT fallback으로 숨기지 않는다.

ELF에는 기존 native emitter가 만든 타입별 encoding recipe와 불변 연산 기록이
들어간다. 첫 실행에서 각 연산을 emit하고 frame operand·literal을 재배치한 뒤 RW를
RX로 바꾸고 code pointer를 cache에 공개한다. 이후 현재 caller frame으로 같은 코드를
호출하므로 다른 인자·재귀 frame·간접 함수 호출에서도 값이 맞는다. Cache에는 실제
frame 주소나 입력값을 저장하지 않는다. 인프라 호출은 source frame에 포함하지 않으며
4096 frame 제한과 오류 위치를 유지한다. Code mapping은 process 종료까지 보존한다.
외부 compiler/process가 필요하지 않고 RWX code mapping을 만들지 않는다.

`--jit-report`는 선택적 runtime 통계를 ELF에 넣는다. Entry 함수의 정상 반환 뒤
컴파일 횟수·cache hit·총 컴파일 nanoseconds를 stderr 세 줄로 출력한다. 시간은
allocation·encoding·relocation·RX protection과 timer overhead를 포함한다. `build`는
보고서를 실행 파일에 넣고, `run`과 성공한 `test`는 runtime 출력까지 보여준다.
오류·panic 종료에는 최종 보고서가 없다. 통계를 켜면 cache hit 측정에도 비용이 추가된다.

실험적 JIT는 실제 코드 생성·재사용을 지원한다. Runtime 값 specialization과 AOT 대비
성능 개선을 보장하지 않는다. Loop fusion·SIMD·closure·background compilation·
eviction·process 간 cache와 다른 target은 제외한다.
[benchmarks/jit_benchmark.py](https://github.com/skystarry-team/Xen/blob/main/benchmarks/jit_benchmark.py)로 현재 환경의
첫 컴파일·반복 실행 비용을 측정할 수 있다.
