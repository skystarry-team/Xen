# Xen으로 Xen 만들기

이 폴더는 **자기 소스를 컴파일할 수 있는 Xen 부분집합 컴파일러**다.
어휘 분석, 함수 선언 수집, 파싱, 타입 검사, x86-64 기계어 생성, ELF 작성까지
전부 Xen으로 구현한다. 기존 OCaml 컴파일러는 첫 실행 파일을 만드는 데 사용한다.
그 이후 세대는 외부 컴파일러·어셈블러·링커를 호출하지 않는다.

현재 범위는 **Linux x86-64에서 동작하는 스칼라 값과 POD 구조체를 가진 Xen**이다.
기존 Xen 전체나 표준 라이브러리를 컴파일하는 단계까지 구현한 것은 아니다.

## 코드를 읽는 순서

진입점은 `compiler.xen`이다. 구현은 역할에 따라 `src/`로 나눴다.

| 파일 | 역할 |
| --- | --- |
| `compiler.xen` | CLI → 입력 → 컴파일 → 결과 저장의 전체 흐름 |
| `src/compiler.xen` | 입력 읽기, 분석·코드 생성·재배치의 공통 파이프라인 |
| `src/cli.xen` | 인자·파일 경로 처리, build/check, 실행 파일 저장 |
| `src/cli_text.xen` | 도움말과 CLI 오류의 고정 바이트 문구 |
| `src/context.xen` | `Context` 구조체, 버퍼 확보, 공유 카운터의 위치 |
| `src/runtime.xen` | 메모리 읽기·쓰기, mmap, Linux 입출력 |
| `src/lexer.xen` | 토큰 저장, 이동, 어휘 분석 |
| `src/diagnostics.xen` | 컴파일 오류 출력과 종료 |
| `src/keywords.xen` | 키워드와 예약된 내장 이름 |
| `src/records.xen` | 타입·구조체 선언, 크기·정렬, 필드, 순환 검사 |
| `src/symbols.xen` | 함수 시그니처와 지역 변수의 범위 |
| `src/expressions.xen` | 표현식 파싱, 호출, 생성자, 필드 읽기 |
| `src/statements.xen` | 대입, 분기·반복, 함수 진입·반환 |
| `src/intrinsics.xen` | 지원하는 asm 제약과 syscall 시그니처 |
| `src/x86_64.xen` | 명령어 바이트, 프레임, 값 복사, 분기·정수 연산 |
| `src/elf.xen` | ELF64 헤더와 println 런타임 |

현재 파일 분리는 **소스 구성 단위**다. 이름 공간이나 Xen의 `import`를 구현한 것은
아니다. `sources.list`에 명시한 파일들을 `assemble.sh`가 내용 변환 없이 이어 붙여
`build/compiler.xen`이라는 단일 컴파일 단위를 만든다. 파일을 추가할 때는 이 목록을
수정한다. 실제 모듈 로딩·이름 공간 처리는 다음 확장 대상이다.

## 재현

저장소 루트에서:

```sh
./self_hosting/bootstrap.sh
./self_hosting/verify.sh
```

기본 stage0는 `compiler/dist/xen`이다. 다른 Xen 실행 파일을 쓰려면 절대 경로로
`XEN_STAGE0=/path/to/xen ./self_hosting/verify.sh`를 실행한다.
기존 컴파일러가 없으면 먼저 저장소 루트에서 `make build`를 실행한다.
생성물은 Git에서 제외되는 `self_hosting/build/`에 저장한다.

| 세대 | 만든 도구 | 입력 |
| --- | --- | --- |
| stage0 | 기존 OCaml 구현 | 기존 컴파일러 |
| scalar-seed | stage0 | `bootstrap/scalar.xen` — 첫 스칼라 구현 |
| records-seed | scalar-seed | `bootstrap/records.xen` — 스칼라 문법으로 쓴 구조체 지원 구현 |
| driver | records-seed | `bootstrap/driver.xen` 진입점과 현재 `src/` — stdin 전용 전환 드라이버 |
| stage1 | driver | 조립된 `build/compiler.xen` — CLI를 사용하는 현재 구현 |
| stage2 | stage1 | 동일한 `build/compiler.xen` |
| stage3 | stage2 | 동일한 `build/compiler.xen` |

`bootstrap.sh`는 **stage2와 stage3의 바이트 일치**를 확인하고 SHA-256을 출력한다.
stage1은 과거 seed에서 출발한 전환 드라이버가 만들고, stage2·stage3는 새 CLI로
만든다. 고정점 확인의 필수 조건은 stage2·stage3의 일치다.
셸은 소스 파일 연결, 프로그램 실행, 초기 단계의 리다이렉션·실행 권한 설정,
결과 비교를 담당한다. stage1부터는 Xen CLI의 `build`로 다음 세대를 저장한다.
언어 처리와 실행 파일 생성, CLI 인자·파일 처리는 Xen 코드가 수행한다.
`bootstrap/scalar.xen`과 `bootstrap/records.xen`은 확장 경로를 보존하는 과거 구현이며, 일반 개발에서는
현재의 `src/`를 수정한다. 새 기능을 넣을 때 이 스냅샷들을 같이 수정하지 않는다.

## CLI

부트스트랩은 최종 실행 파일을 `self_hosting/build/xen`에도 복사한다.
별도 프로그램을 컴파일하려면:

```sh
./self_hosting/build/xen --help
./self_hosting/build/xen check self_hosting/examples/core.xen
./self_hosting/build/xen build self_hosting/examples/core.xen -o /tmp/xen-core
/tmp/xen-core
```

`build`의 기본 출력은 현재 디렉터리의 `a.out`이다. `-o`는 입력 경로 앞이나 뒤에
둘 수 있다. 출력 파일은 컴파일이 성공한 뒤 같은 디렉터리의 고유 임시 파일에
기록하고, 권한을 `0755`로 설정하고 닫은 뒤 이름 변경으로 교체한다. 컴파일·저장
실패 시 기존 출력 파일은 유지한다. 정상적으로 처리한 저장 오류에서는 임시 파일을
삭제한다. 강제 종료 시 임시 파일이 남을 수 있으며, 디스크 영속성을 위한 fsync는
수행하지 않는다.

`check`는 실행 파일을 저장하거나 실행하지 않는다. 현재는 전체 파이프라인을
사용하므로 코드 생성 단계의 제한과 오류도 적용한다.

입력·출력 경로의 `-`는 stdin·stdout이다. 공백·한글 경로는 셸에서 따옴표로 묶으면
된다. `-`로 시작하는 입력 파일 이름은 `--` 뒤에 둔다.

```sh
./self_hosting/build/xen build '작업 폴더/예제.xen' -o '작업 폴더/예제'
./self_hosting/build/xen check -- -example.xen
./self_hosting/build/xen build - -o - < self_hosting/examples/core.xen > /tmp/xen-core
```

인자가 없으면 `--help`와 동일하게 도움말을 출력하고 0으로 종료한다.
stdin → stdout 컴파일은 `build - -o -`로 명시한다:

```sh
./self_hosting/build/xen build - -o - < self_hosting/examples/core.xen > /tmp/xen-core
chmod +x /tmp/xen-core
/tmp/xen-core
```

완성된 ELF만 stdout으로 전달하고 오류는 stderr로 보낸다. 컴파일 오류가 발생하면
ELF를 출력하지 않는다. `run`, 프로젝트 로딩, 모듈·import는 아직 없다.
도움말과 CLI 오류 문구는 String 지원 전까지 `cli_text.xen`의 고정 바이트로 쓴다.
`arg_count()`·`arg()` 내장 함수는 아직 구현하지 않았다.

## 지원하는 Xen 범위

| 영역 | 지원 |
| --- | --- |
| 값 | `Int`(64비트 부호 정수), `Bool`, 함수 반환형 `Unit` |
| 구조체 | Int·Bool·중첩 구조체 필드, 생성자, 필드 읽기·대입, 값 복사 |
| 함수 | 인자 0~6개, 구조체 인자·반환, 타입 검사, 재귀, 상호 재귀, 전방 호출 |
| 변수 | `let`, `let mut`, 타입 추론·명시, 대입, 블록 범위·이름 가리기 |
| 제어 흐름 | 블록, `if` / `else if` / `else`, `while`, `return` |
| 정수 | 십진 리터럴, `+ - * / %`, 단항 `+ - ~`, `& \| ^ << >>` |
| 비교 | `== != < <= > >=`, 불리언 `== !=` |
| 논리 | `!`, `&&`, `\|\|`; 오른쪽 피연산자의 단락 평가 |
| 출력·검사 | `println(Int)`, `assert(Bool)` |
| 저수준 | 파일 앞의 `#global[bb]`, `syscall0`~`syscall6`, 아래 asm 4종 |
| 기타 | 공백, `//` 주석, 필수 `fn main()` |

일반 함수는 인자를 왼쪽부터 한 번씩 평가한다. syscall은 번호를 포함해 최대
7개의 표현식을 받는다. `main`은 인자가 없고 반환형은 `Unit`이어야 한다.
`#global[bb]` 뒤의 선언은 새 줄에서 시작해야 한다.
`Int`의 덧셈·뺄셈·곱셈·부호 반전은 wrapping이다. 나눗셈은 0 방향으로 버림하고
나머지 부호는 피제수와 같다. 나눗셈·나머지의 0 제수와 `Int.min / -1`,
범위를 벗어난 시프트, 실패한 `assert`는 종료 코드 101로 중단한다.

구조체는 값으로 복사한다. 지역 변수 복사, 대입, 함수 인자·반환 뒤에 한쪽을
변경해도 다른 값은 바뀌지 않는다. 중첩 필드 대입은 `let mut`로 선언한 원본을
수정한다. 필드 배치는 기존 Xen과 동일하게 `Int`는 크기·정렬 8,
`Bool`은 크기·정렬 1이며, 중첩 구조체는 자신의 정렬을 따른다.
생성자의 필드는 **구조체 선언 순서**로 평가한다. 이는 현재 기존 Xen의 동작이다.
필드 누락·중복·잘못된 타입, 빈 구조체, 직접·간접 값 순환은 거부한다.
구조체의 `==`·`!=`는 지원하지 않는다.

지원하는 asm은 다음 **정확한 템플릿과 제약**이다. 문자열은 이 구문에만 사용한다.
함수 이름에 따라 본문을 대체하지 않으며, 메모리 헬퍼도 다른 함수와 동일하게
파싱하고 컴파일한다.

```xen
asm<Int>("mov rax, [rdi]", in("rdi", address), out("rax"))
asm("mov [rdi], rsi", in("rdi", address), in("rsi", value))
asm<Int>("movzx rax, byte [rdi]", in("rdi", address), out("rax"))
asm("mov [rdi], sil", in("rdi", address), in("rsi", value))
```

주소와 매핑은 `Int`로 전달하며 `mmap` syscall로 메모리를 확보한다.
이는 기존 Xen의 `bb`·asm 의미를 사용한다. 메모리 주소의 유효성과 수명은 호출자가
관리한다. `String`이나 `Ptr<T>`의 기존 표현을 다른 의미로 축약하지 않는다.

## 아직 지원하지 않는 것

`String` 값, 벡터, 열거형, 튜플, 제네릭, Box·소유권·참조,
표준 라이브러리, 모듈·import, 부동소수점, `for`, `break`, `continue`,
`match`, 조건식으로 값을 만드는 `if`, 거듭제곱, 일반적인 asm,
`#scope`·함수 속성, 최적화, 다른 CPU·OS는 미구현이다.
블록의 마지막 표현식과 `()` 값도 아직 지원하지 않는다.
지원하지 않는 구문은 오류로 거부하며, stage0에 전달하는 우회 경로는 없다.

고정 상한은 소스 **1MiB 미만**, 토큰 262,142개(EOF 제외), 출력 4MiB,
함수 256개, 함수당 활성 변수 512개, 임시 값·인자를 포함한 프레임 64KiB,
호출 재배치 65,536개다. 구조체는 128개, 필드는 구조체당 32개,
구조체 크기는 32KiB까지다.
파서 재귀 깊이와 실행 스택에 대한 별도 제한·진단은 아직 없다.
오류 문구·종료 코드는 기존 컴파일러와 동일하지 않다.

## 구현 구조

`sources.list`로 조립한 동일 소스를 stage1~stage3의 입력으로 사용한다.
전환 드라이버만 `assemble.sh bootstrap/driver.xen`으로 진입점을 교체해 조립한다.
드라이버도 현재와 동일한 `src/`를 사용하므로 구현 전체를 복제하지 않는다.
과거 records-seed가 만든 실행 파일에는 새 시작 정보가 없으므로, stdin 전용
드라이버가 현재 백엔드로 CLI의 첫 실행 파일을 만드는 단계를 거친다.

1. `lex`: 토큰을 32바이트 레코드로 저장한다.
2. `declarations`: 함수 시그니처와 본문 토큰 위치를 수집한다.
3. `compile_function`: 본문을 파싱하며 타입을 확인하고 코드를 생성한다.
4. `expression`: 우선순위 파싱, 정수 연산, 단락 평가, 호출을 처리한다.
5. `block`·`statement`: 변수 범위, 분기, 반복, 반환을 처리한다.
6. `elf`·`patch`: 정적 ELF64 헤더와 상대 호출·분기 주소를 완성한다.

버퍼 주소는 `Context` 구조체로 전달한다. 공유 카운터와 토큰·심볼 테이블은 아직
원시 메모리에 두며, 카운터는 `state_get`·`state_set`으로 접근한다. 카운터 번호는
`src/context.xen`에 정리했다. `make_context() -> Context`가 실제 컴파일러에서
구조체 반환도 사용하므로 자기 컴파일 과정에서 인자와 반환 규약을 함께 검증한다.

지역 변수와 구조체 임시 값은 `rbp` 기준의 스택 영역에 둔다. 표현식의 스칼라 임시
값은 `push`·`pop`을 사용한다. 일반 함수의 인자 레지스터는
`rdi rsi rdx rcx r8 r9`, syscall은 `rax`에 번호를 두고
`rdi rsi rdx r10 r8 r9`에 인자를 둔다.
구조체 인자는 독립된 스냅샷 주소를 전달하고, 피호출자가 모든 인자 레지스터를
보관한 뒤 자신의 프레임으로 복사한다. 구조체 반환은 호출자가 마련한 임시 영역의
주소를 숨은 `r10` 인자로 전달하고, 반환 전에 결과를 복사한다. 이는 이 컴파일러의
내부 규약이며 C ABI는 아니다.
ELF는 실행 코드용 RX 세그먼트와 시작 정보용 RW 세그먼트를 분리한다.
진입 코드는 첫 함수 호출 전에 Linux의 초기 스택 주소를 `0x800000`에 보관한다.
CLI는 기존 메모리 읽기 함수로 argc와 NUL로 끝나는 argv를 읽으며 procfs에
의존하지 않는다. 코드 세그먼트는 `0x400000`에서 시작해 최대 4MiB이므로 겹치지
않는다. 이 주소는 생성된 실행 파일의 내부 규약이며 일반 포인터·String API가 아니다.
키워드·asm 비교에 쓰는 큰 십진 상수는 해당 ASCII 바이트를 little-endian으로
묶은 값이다. 이름 비교는 원본 바이트 전체를 비교하므로 해시 충돌에 의존하지 않는다.

## 검증과 진척

2026-10-16에 Linux x86-64에서 다음을 실행했다.

- stage1 → stage2 → stage3 자기 컴파일과 stage2/stage3 바이트 일치.
- `core.xen`: 재귀·전방 호출, 6인자·중첩 호출의 평가 순서, 정수 경계,
  부호 있는 나눗셈, 우선순위, 단락 평가, 변수 범위, 분기·반복.
- `memory.xen`: 실제 mmap, asm 4종, syscall. 두 예제 모두 stage0와 stage2의
  실행 출력 일치.
- `records.xen`: 선언 순서에 따른 생성자 평가, 중첩 필드 수정, 복사 독립성,
  구조체 반환 수명·재귀, 구조체와 스칼라를 섞은 6인자, 연속 Bool 필드와
  크기 1·5바이트 구조체의 복사. stage0와 stage2 실행 출력 일치.
- 첫 스칼라 구현 → 구조체 지원 스칼라 구현 → Context 기반 구현으로 이어지는
  확장 경로와 최종 stage2/stage3의 바이트 일치.
- 잘못된 타입·변수·함수·반환·리터럴, bb 없는 syscall, 미지원 구문을 거부하고
  stdout이 비어 있는지 확인.
- 지역 변수에 가려진 함수 호출, 내장 이름의 함수 선언, 반환 이후의 문장은
  stage0와 stage2 모두 거부하는지 확인.
- 잘못된 나눗셈·나머지·시프트와 실패한 assert의 종료 코드 확인.

첫 스칼라 자기 호스팅에 이어 **구조체를 사용하는 컴파일러의 자기 호스팅**까지
확장했다. 다음에는 `String`·동적 버퍼를 추가해 주소 기반 테이블과 숫자 진단을
일반적인 자료형으로 옮길 수 있다. 실제 모듈·표준 라이브러리 지원도 후속 과제다.

CLI 추가 후에는 `bootstrap.sh`를 실행해 새 `build` 명령으로 stage2·stage3를
생성하고 두 파일의 바이트 일치를 확인했다. 위의 전체 회귀 검사는 CLI 변경 후
다시 실행하지 않았다.

## 오류 코드

형식은 `E<코드> <0부터 시작하는 소스 바이트 위치>`다.
컴파일러 자체를 빌드할 때 이 위치는 조립된 `build/compiler.xen`을 기준으로 한다.

| 코드 | 의미 |
| --- | --- |
| 101~103 | 필요한 기호·키워드·표현식이 없음, 또는 미지원 문법 |
| 201~210 | 토큰·숫자·문자열·문자·출력·함수·변수·재배치·소스·입력 오류 |
| 301~302 | 타입 불일치 또는 미지원 타입 |
| 303~305 | 예약 이름, 중복 함수, 인자 수 초과 |
| 306~309 | 없는 변수, 중복 변수, 없는 함수, 불변 변수 대입 |
| 310~312 | 반환 경로 부족, main 없음, main 시그니처 오류 |
| 313~314 | 스칼라 지역 변수 호출, 도달 불가능한 문장 |
| 401~404 | 미지원 asm, 잘못된 레지스터 제약, bb 권한 없음, global 선언 뒤 줄바꿈 없음 |
| 501~506 | 중복 구조체, 잘못된 필드 선언, 없는 필드, 생성자 누락·중복, 값 순환, 구조체 상한 초과 |

메모리 확보 실패는 70, 출력 실패는 74, 컴파일 오류는 1로 종료한다.
CLI 인자 오류는 64, 입력 파일 열기 실패는 66, 출력 파일 생성·게시 실패는 73,
파일 쓰기·닫기 실패는 74다. 파일 시스템 오류에는 경로와 Linux errno를 표시한다.
소스 읽기 실패는 기존 `E210`·종료 코드 1을 유지한다. `--help`와 성공한 `check`는
0으로 종료한다.
