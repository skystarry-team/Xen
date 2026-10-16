# bb의 저수준 기능

`#scope[bb]` 안에서는 원시 메모리, syscall, volatile 접근과 인라인 어셈블리를
사용할 수 있습니다. 함수 전체에는 `#![bb]`, 모듈 전체에는 `#global[bb]`를
사용합니다. `#scope[opt, bb]`에서도 volatile 접근과 asm의 효과가 보존됩니다.

## 주소와 포인터

`Ptr<T>`는 주소와 원소 개수를 가진 포인터입니다. 기존의 `raw_alloc<T>(count)`,
`raw_load(pointer, index)`, `raw_store(pointer, index, value)`, `raw_free(pointer)`,
`ptr_addr(pointer)`를 사용할 수 있습니다. 원소는 raw-safe POD여야 하며
`String` 같은 관리되는 값은 허용하지 않습니다. `core.intrinsics.size_of<T>()`와
`core.intrinsics.align_of<T>()`는 Xen의 레이아웃을 반환하며 C ABI를 뜻하지 않습니다.

`ptr_from_addr<T>(address: Int, count: Int) -> Ptr<T>`는 할당 없이 포인터를
만듭니다. 주소는 `ptr_addr`와 같은 `Int` 비트 패턴으로 받습니다. 음수 개수,
`Int` 양수 범위를 넘는 바이트 크기, 정렬 위반, 원소가 있는 null 포인터,
주소 범위의 unsigned overflow를 거부합니다. 빈 포인터에도 정렬 검사가
적용됩니다. 이후 인덱스로 접근할 때도 경계 검사를 수행합니다.

주소가 실제로 매핑되어 있는지, 읽고 쓸 수 있는지는 검사하지 않습니다.
호출자가 영역의 유효성과 수명을 보장해야 하며 별칭은 수명을 연장하지 않습니다.
`raw_free`는 자신이 소유한 매핑과 크기에 대해서만 호출하세요. 별칭으로 중복
해제하거나, 다른 할당의 내부 주소나 장치 매핑을 해제해서는 안 됩니다.

## Volatile 메모리 접근

```xen
fn main() {
    #scope[bb] {
        let storage = raw_alloc<U32>(1);
        let alias = ptr_from_addr<U32>(ptr_addr(storage), 1);
        volatile_store(alias, 0, u32(42));
        println(volatile_load(alias, 0));
        raw_free(storage);
    }
}
```

`volatile_load<T>(pointer: Ptr<T>, index: Int) -> T`와
`volatile_store<T>(pointer: Ptr<T>, index: Int, value: T) -> Unit`를 제공합니다.
타입 인자를 생략하면 포인터에서 추론합니다. `I8/U8`부터 `I64/U64`, `F32`,
`F64`를 지원하며 `Bool`, 구조체, 관리되는 타입은 제외합니다. 각 연산은 지정한
주소에 타입 폭(1·2·4·8바이트)의 단일 접근을 내보냅니다. 반복해서 읽거나 결과를
사용하지 않아도 접근과 순서를 보존하며, 기존 포인터 경계 검사도 유지합니다.

Volatile은 원자 연산이나 스레드 동기화, CPU 메모리 장벽을 제공하지 않습니다.
장치 메모리는 적절한 매핑과 플랫폼의 순서 규칙도 필요합니다.
CPU 메모리 장벽은 `memory_fence()` 또는 지원하는 asm 명령으로 명시할 수 있습니다.

## CPU 힌트와 메모리 장벽

`cpu_relax() -> Unit`과 `memory_fence() -> Unit`은 `bb` 안에서 사용하는
타깃 공통 내장 함수입니다. 인자나 타입 인자는 받지 않습니다.

| 함수 | x86-64 | AArch64 | 의미 |
| --- | --- | --- | --- |
| `cpu_relax()` | `pause` | `yield` | 반복 대기 중 사용할 수 있는 CPU 힌트 |
| `memory_fence()` | `mfence` | `dmb ish` | 앞뒤의 메모리 읽기·쓰기에 대한 순서 장벽 |

두 함수는 결과를 사용하지 않거나 연속으로 호출해도 횟수와 순서가 보존되며,
컴파일러 최적화 경계로 취급합니다. `cpu_relax()`는 운영체제 스케줄러에
실행권을 넘기거나 일정 시간 대기하는 함수가 아닙니다. `memory_fence()`는
원자 접근을 만들거나 그 자체로 언어 차원의 스레드 간 동기화를 제공하지 않습니다.
AArch64의 장벽 범위는 inner-shareable이며, 장치 메모리의 플랫폼별 순서 규칙이나
장치 작업 완료를 보장하는 장벽을 대신하지 않습니다.

```xen
fn main() {
    #scope[bb, opt] {
        let storage = raw_alloc<Int>(1);
        volatile_store(storage, 0, 42);
        memory_fence();
        cpu_relax();
        println(volatile_load(storage, 0));
        raw_free(storage);
    }
}
```

하드웨어 의미는 [Intel MFENCE 문서](https://www.intel.com/content/www/us/en/docs/fortran-compiler/developer-guide-reference/2025-0/for-mfence.html)와
[Arm 장벽 범위 문서](https://support.arm.com/documentation/102336/0100/Limiting-the-scope-of-memory-barriers?lang=en)를 참고하세요.

## 원자 메모리 연산

원시 `Ptr<T>`에 정수 원자 연산을 수행합니다. `T`는 `I8/U8`부터 `I64/U64`이며
타입 인자는 포인터에서 추론하거나 명시할 수 있습니다. 모든 호출은 `bb`가
필요합니다. 원소 개수에 대한 경계 검사와 자연 정렬 검사를 유지합니다.

| 호출 | 반환값 |
| --- | --- |
| `atomic_load(p, index, order?)` | 읽은 `T` |
| `atomic_store(p, index, value, order?)` | `Unit` |
| `atomic_exchange(p, index, value, order?)` | 교환 전의 `T` |
| `atomic_compare_exchange(p, index, expected, desired, success?, failure?)` | 비교 시 관찰한 이전 `T` |
| `atomic_fetch_add/sub/and/or/xor(p, index, value, order?)` | 변경 전의 `T` |

순서는 문자열 리터럴 `"relaxed"`, `"acquire"`, `"release"`, `"acq_rel"`,
`"seq_cst"`입니다. 생략하면 `seq_cst`입니다. CAS의 순서는 둘 다 생략하거나
둘 다 명시합니다. load에는 release/acq_rel, store에는 acquire/acq_rel을
허용하지 않습니다. CAS 실패 순서는 relaxed/acquire/seq_cst 중에서 성공
순서보다 강하지 않아야 합니다. release 성공의 실패 순서는 relaxed만 가능합니다.

CAS는 strong 연산입니다. 관찰한 값이 `expected`와 같으면 교환에 성공했으며,
ARM에서도 비교 일치 후 store-exclusive가 실패하면 재시도합니다. 산술 fetch는
해당 정수 폭에서 wrap하며 일반 정수 연산의 overflow 오류를 내지 않습니다.
결과를 버려도 접근과 호출 순서를 보존하며, 최적화 경계로 취급합니다.
현재 구현은 모든 순서에 더 강한 장벽을 사용할 수 있습니다. x86은 잠금 명령과
`mfence`, ARM은 acquire/release 접근·exclusive 재시도와 `dmb ish`를 사용합니다.

대상은 일반 공유 메모리이며 장치 메모리의 원자 접근 계약은 제공하지 않습니다.
원자 객체는 공유 전에 초기화하고, 동시에 접근하는 동안에는 Xen 원자 함수나
호환되는 C 원자 연산만 사용해야 합니다. 같은 객체의 release를 관찰한 acquire는
그 전에 게시한 메모리 쓰기를 이후 읽기에 전달합니다. 동기화 없는 일반/volatile
접근과의 충돌, 수명이 끝난 영역 접근은 허용하지 않습니다. 이 API는 스레드 생성
API를 추가하지 않으며, C 스레드와의 원자 접근·release/acquire 교차 검증을 포함합니다.

```xen
fn main() {
    #scope[bb, opt] {
        let counter = raw_alloc<U32>(1);
        atomic_store(counter, 0, u32(1), "release");
        let old = atomic_fetch_add(counter, 0, u32(41), "acq_rel");
        assert(old == u32(1));
        println(atomic_load(counter, 0, "acquire"));
        raw_free(counter);
    }
}
```

## C ABI 외부 함수

`extern_call<Result>("library", "symbol", arguments...)`는 Linux x86-64의
System V ABI 또는 Linux AArch64의 AAPCS64로 외부 함수를 호출합니다.
`bb`, 명시한 결과 타입과 라이브러리·심볼 문자열 리터럴이 필요합니다.

인자는 최대 6개의 고정 인자이며 정수, `F32/F64`, `Ptr<T>`를 지원합니다.
정수와 FP 레지스터는 각 ABI의 별도 인자 뱅크를 따르고 `Ptr<T>`는 주소만
전달합니다. 반환은 정수·FP·`Unit`이며, C 포인터 반환은 `Int`/`U64` 주소로
받아 `ptr_from_addr`로 범위를 구성합니다. 작은 정수는 `i8/u8/i16/u16/i32/u32`로
정확한 C 타입을 지정하세요. `Unit`은 C `void`입니다. 가변 인자, 집계형의 값 전달,
관리되는 값, C 콜백은 지원하지 않습니다. `String`은 자동으로 C 문자열이 되지 않습니다.
문자열은 유효한 NUL 종결 `Ptr<U8>` 영역을 준비해야 합니다.

호출자는 실제 C 함수 시그니처, 포인터 수명, 데이터 레이아웃을 맞춰야 합니다.
Xen 구조체·튜플 레이아웃은 C 구조체 레이아웃 계약이 아닙니다. 같은 심볼을
다른 라이브러리 또는 다른 시그니처로 사용하면 진단합니다. 외부 호출은 메모리를
읽고 쓸 수 있는 부작용으로 보존합니다.

```xen
fn main() {
    #scope[bb] {
        println(extern_call<I32>("libc.so.6", "abs", i32(-42)));
    }
}
```

외부 호출이 있는 프로그램은 glibc 동적 ELF로 생성하며 `__libc_start_main`을
통해 C 초기화·정상 종료와 라이브러리 생성자·소멸자, stdio 정리를 실행합니다.
타깃 로더는 x86-64의 `/lib64/ld-linux-x86-64.so.2`, AArch64의
`/lib/ld-linux-aarch64.so.1`입니다. 외부 호출이 없으면 기존 정적 ELF 경로를 씁니다.
컴파일 시 호스트 assembler/linker나 라이브러리 설치가 필요하지 않으며, 실행 시
타깃 로더와 해당 아키텍처의 공유 라이브러리가 있어야 합니다. 누락된 라이브러리나
심볼은 동적 로더가 실행 오류로 보고합니다. 기본 RUNPATH는 `$ORIGIN`입니다.

`library`는 `DT_NEEDED` 의존성을 지정합니다. 심볼은 로더의 전역 탐색·interposition
규칙을 따르므로 지정한 라이브러리만을 대상으로 하는 `dlsym` 조회와 다릅니다.
자세한 계약은 [ELF 동적 링크](https://refspecs.linuxfoundation.org/elf/gabi4%2B/ch5.dynamic.html),
[AAPCS64](https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst)를 참고하세요.

## 인라인 어셈블리

Linux x86-64 예제입니다.

```xen
fn main() {
    #scope[bb] {
        let answer = asm<Int>("add rax, rcx",
            inout("rax", 17), in("rcx", 25));
        println(answer);
        asm("pause");
    }
}
```

Linux AArch64에서는
`asm<Int>("add x0, x0, x1", inout("x0", 17), in("x1", 25))`를 사용합니다.
프로세서 힌트는 `asm("yield")`로 내보낼 수 있습니다.

템플릿과 레지스터 이름은 문자열 리터럴이어야 합니다. 명령은 타깃의 소문자
이름을 사용하고 `;` 또는 이스케이프한 줄바꿈으로 구분합니다. 입력 표현식은
왼쪽부터 한 번씩 평가한 뒤 레지스터에 배치합니다.

| 제약 | 의미 |
| --- | --- |
| `in("register", value)` | 이름으로 지정한 레지스터 폭 이하의 읽기 전용 정수 입력 |
| `out("register")` | 템플릿에서 초기화할 출력 |
| `inout("register", value)` | 같은 레지스터를 읽고 쓰는 출력 |
| `clobber("register")` | 템플릿에서 덮어쓸 추가 임시 레지스터 |

출력마다 정수 타입 인자를 하나씩 명시합니다.
`asm<U8,U32>(..., out("al"), out("r8d"))`는 출력 선언 순서대로 `(U8,U32)`를
반환합니다. 출력 하나는 스칼라, 출력이 없으면 `Unit`이며 타입 인자를
생략하거나 `Unit`을 명시할 수 있습니다. 출력 타입은 레지스터보다 좁아도 됩니다.
입력은 해당 레지스터 폭 이하여야 하며 배치할 때 부호에 맞춰 확장합니다.
튜플 결과는 인덱스 접근, 구조 분해와 일반적인 제네릭 값 전달을 지원합니다.

제약은 물리 레지스터를 소유합니다. `rax/eax/ax/al`, `x0/w0`는 서로 겹치므로
입력·출력·clobber의 중복과 별칭 충돌을 거부합니다. 입력과 출력의 결합은
`inout`으로 표현합니다. 모든 읽기는 입력 또는 앞선 쓰기로 필요한 비트가
초기화되어야 하며, 모든 쓰기는 출력이나 clobber로 선언해야 합니다.
x86의 8·16비트 쓰기는 상위 비트를 보존하고, x86의 32비트 쓰기와 ARM의 `w`
쓰기는 상위 32비트를 0으로 만듭니다. `al`만 쓴 뒤 `rax`를 읽으면 거부합니다.
`ah` 같은 x86 high-byte 레지스터는 지원하지 않습니다. 모든 출력은 튜플 저장
주소를 계산하기 전에 회수합니다.

플래그는 asm 경계를 넘어 전달되지 않습니다. x86 `setcc`는 같은 템플릿 안의
`cmp/test`가 만든 플래그를 읽습니다. 다른 플래그 변경 산술 연산은 이 보수적인
조건 계약을 무효화합니다. ARM `cset`은 앞선 `cmp/tst/adds/subs`가 필요합니다.
플래그 출력은 정수 `0/1`입니다. 예를 들어
`asm<U8>("cmp r8d,r9d; setl al", in("r8d",i32(-1)), in("r9d",i32(1)), out("al"))`을
사용합니다. ARM에서는 `cmp w8,w9; cset w0,lt`, `out("w0")`, `U32`를 사용합니다.

현재 모든 asm은 volatile이며 Semantic IR에서 알 수 없는 메모리 읽기·쓰기
효과를 가집니다. 결과를 버려도 보존하고 최적화 경계로 취급합니다. `pure`,
`nomem` 등의 옵션은 지원하지 않습니다. asm의 메모리 피연산자는 원시 주소로
접근하므로 포인터 경계 검사를 우회합니다. 유효성과 정렬은 호출자 책임입니다.

| 타깃 | 레지스터 | 명령 |
| --- | --- | --- |
| x86-64 | `rax rcx rdx rsi rdi r8..r11` 및 32·16·8비트 별칭 | `mov movzx movsx movsxd`, `add sub xor and or imul`, `shl shr sar`, `neg not bswap`, `cmp test setcc`, `rdtsc`, `nop pause mfence lfence sfence` |
| AArch64 | `x0..x14`, `w0..w14` | `mov`, `add sub adds subs mul and orr eor`, `lsl lsr asr`, `neg mvn rev`, `sxtb sxth sxtw uxtb uxth`, `cmp tst cset`, `ldr str ldur stur` 및 byte/halfword 명령, `nop yield`, `dmb sy/ish` |

x86 별칭은 `eax/ax/al`, `ecx/cx/cl`, `edx/dx/dl`, `esi/si/sil`, `edi/di/dil`,
`r8d/r8w/r8b`부터 `r11d/r11w/r11b`까지입니다. 확장 명령 외에는 레지스터의
폭이 같아야 합니다. `mov`의 메모리 접근 폭은 레지스터를 따르며,
`byte/word/dword/qword [base+offset]` 또는 `byte ptr ...`로 명시하면 일치해야 합니다.
`movzx/movsx`의 메모리 소스는 byte/word 폭을 명시하며, `movsxd`는 dword 소스와
64비트 목적지를 받습니다. 메모리 base는 64비트 레지스터, 변위는 signed32 바이트입니다.

x86 산술 연산은 레지스터나 상수를 받습니다. 64비트 ALU 상수는 signed32이며
부호 확장합니다. 작은 폭은 해당 폭의 상수 비트 패턴을 받습니다. `imul`은
16·32·64비트만 지원합니다. 즉시 시프트 개수는 `0..폭-1`, 가변 시프트는 `cl`이며,
입력이나 앞선 쓰기로 `cl` 또는 더 넓은 `rcx` 별칭을 초기화해야 합니다.
가변 개수는 64비트 연산에서 하위 6비트, 나머지에서 하위 5비트를 사용합니다.
`bswap`은 32·64비트를 지원합니다. `setcc`의 조건은
`e/z ne/nz l le g ge b/c be a ae s ns o no p np`입니다.

ARM 레지스터 연산은 같은 폭의 `w` 또는 `x`를 받습니다. `mov #integer`는
상수 구성 명령 여러 개로 확장할 수 있습니다. `add/sub/adds/subs`, `cmp`의
마지막 피연산자는 레지스터나 `#0..#4095` 상수입니다. `lsl/lsr/asr`는 레지스터나
`#0..#(폭-1)`을 받으며 가변 개수는 w/x에 따라 하위 5/6비트를 사용합니다.
`cset` 조건은 `eq ne cs/hs cc/lo mi pl vs vc hi ls ge lt gt le`입니다.

ARM `ldr/str`은 `w`로 32비트, `x`로 64비트에 접근합니다. `ldrb/strb`, `ldrh/strh`는
`w` 레지스터로 1/2바이트에 접근하며 읽기는 0으로 확장합니다. 메모리 base는 `x`
레지스터이고 `[base, #byte_offset]`는 접근 폭의 배수인 `0..4095*폭`을 받습니다.
`[base]`는 오프셋 0입니다. `ldur/stur`, `ldurb/sturb`, `ldurh/sturh`는
`-256..255` 바이트 변위를 받습니다. 인덱스 레지스터와 pre/post-index writeback은
지원하지 않습니다.

다음 x86-64 예제는 즉시값 연산과 시프트를 함께 사용합니다.

```xen
fn main() {
    #scope[bb] {
        println(asm<Int>("shl r8, 1; add r8, 8", inout("r8", 17)));
    }
}
```

AArch64의 같은 계산은
`asm<Int>("lsl x8, x8, #1; add x8, x8, #8", inout("x8", 17))`입니다.
`rdtsc`는 `rax`와 `rdx` 모두를 쓰므로 하나를 출력으로, 나머지를 clobber로
선언하거나 둘 다 clobber로 선언해야 합니다.

스택·프레임 및 callee-saved 레지스터, SIMD 피연산자, 레이블, 지시어, 분기,
호출과 지원 목록 밖의 명령은 거부합니다. `asm`은 예약어입니다.
`xen check`는 공통 타입·제약을 검사하고 타깃별 명령과 레지스터는 코드 생성
(`build`, `run`, `test`)에서 검증합니다. 두 백엔드 모두 내부에서 인코딩하므로
호스트 assembler나 linker가 필요하지 않습니다.

[목차](README.md) · [문법](reference.md) · [English](../en/low-level.md)
