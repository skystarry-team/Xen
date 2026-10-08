# 구현 상태와 제한

## 지원됨

- concrete Typed AST에서 비 SSA typed CFG Semantic IR로 내리는 단일 네이티브 경로
- CFG 고정점 초기화·부분 이동·참조 provenance·liveness 분석과 field별 호출 summary
- 같은 함수 안의 `match`·`for`·`?`·단락 연산, lexical 제어 대상과 독립 임시값 storage
- IR verifier 및 내부 출력기; [Semantic IR 계약](semantic-ir.md)
- 재현 가능한 Semantic IR 생성·source/CFG 변형 검사와 구조적 실패 축소;
  [검증 설계 및 분석의 보수성](semantic-testing.md)

- source-root 기반 재귀 `module`/`import`, qualified 함수·struct 접근과 단일 ELF 생성
- size/alignment 기반 named struct layout, nested field, 직접 갱신, 함수 parameter/return
- 사용된 concrete 타입만 생성하는 generic 함수·struct·payload enum
- 호출 인자의 정적 타입에 기반한 단일·복수 generic 함수 타입 인자 추론과 기존 복합 타입 대응;
  [추론 범위와 명시적 호출 안내](generics-enums-and-match.md)
- 파일별 module alias (`import`/`use ... as ...`)와 원래 qualified name 유지
- binding·`_`·중첩 tuple의 irrefutable `let`, 전체 annotation과 모든 binding에 적용되는 `mut`
- tuple 값, 공개 `.N` 원소 접근·mutable local 대입과 `Option<T>`/`Result<T,E>` prelude
- 동일 오류 타입의 `Result<T,E>` 전용 postfix `?`, generic·조건식·match arm 조기 반환
- eager fallback용 `std.option.unwrap_or`와 concrete named callback을 받는 명시적 오류 변환 `std.result.map_err`
- enum·tuple·Bool의 구조적 exhaustive `match`, scalar literal/catch-all, nested binding과 unreachable arm 진단
- generic body의 알려진 enum·tuple 구조 분해와 typed callback; local·pattern·projection·호출을 거친 symbolic 타입 제한 유지
- compiler-private enum representation과 `__tag`·`__payload_*` source 접근·대입 차단
- move-only payload를 포함한 generic enum의 재귀 clone/move/drop
- struct field와 enum payload의 직접·간접 재귀 값 layout을 compile-time에 거부
- move-only `Box<T>`의 명시적 allocation, 내부 값 borrow·교체·소유 추출과 재귀 drop;
  [Box 문서](box-and-recursive-aggregates.md)
- inherent `impl<T> Type<T>` method와 `self`/`&self`/`&mut self` receiver
- `next(&mut self) -> Option<T>` 기반 구조적 `for`와 binding/`_`/중첩 tuple pattern
- prelude `Range` 기반 `Int` 전용 반개방 `start..end`와 endpoint 단일 평가
- 명시적 `use std.iter;` 기반 Vec/Slice/String/Ptr `.iter()`와 구조적 `.enumerate()`
- concrete named function의 `fn(...) -> ...` 값, 간접 호출, local/인자/반환/struct field 저장
- Ptr/Slice field aggregate, Ptr wrapper move-only 분류와 Slice provenance 전파
- `String.as_bytes()`와 consuming `Vec<U8>.into_string()` byte bridge
- 분리된 project `import`와 toolchain `use`, 예약된 `std.*`/`core.*` namespace
- 실행 파일 기반 bundled stdlib 탐색과 authoritative `XEN_STDLIB_ROOT` 개발 override
- enum identity로 해석되는 `core.intrinsics.size_of<T>()`/`align_of<T>()`
- Xen 소스 `std.convert`의 signed decimal `Int` parse/format, `ParseIntError`와
  전체 I64 범위의 overflow 검사
- Xen 소스 `std.io`의 partial-write/EINTR 처리 stdout·stderr와 양수 errno `IoError`
- Xen 소스 `std.fs`의 binary one-shot read/write/copy, embedded-NUL 검사와 fd cleanup
- Xen 소스 `std.env.args()`의 ordered, byte-preserving argument 수집
- Xen 소스 `std.string`의 ASCII whitespace 판정과 byte-preserving tokenization
- Xen 소스 `std.string`의 `slice_bytes`·`find`·`contains`·`split_byte`, recoverable 범위 오류와 빈 항목 보존
- Xen 소스 `std.path`, `std.env.cwd()`, `std.process` process identity
- binary stdin/fd read, filesystem append/metadata와 eager directory 이름 목록

- Linux x86-64 static non-PIE ELF 직접 생성
- I8/U8/I16/U16/I32/U32/I64/U64/F32/F64, Bool, String, Unit (`Int=I64`, `Float=F64`)
- contextual numeric literal, 폭별 modulo 산술·비교, numeric checked conversion과 scalar ABI
- 실제 element stride를 쓰는 범용 `Vec<T>`와 scalar/String/struct/enum/tuple/nested Vec/File의 재귀 clone/move/drop
- 동일 concrete instance로 되돌아오는 `Box`·`Vec` 경계 struct/enum generic 재귀; 직접 layout·Slice/Ptr 경계·성장형 generic 재귀는 거부
- generic enum의 concrete 기대 타입을 payload와 중첩 `Vec` literal 원소에 재귀적으로 전달; 제약이 없는 생성자는 추론 오류
- read-only `Slice<T>`의 local view, 범용 element indexing, 길이와 direct parameter 전달
- owned move-only File
- `bb` 전용 raw-safe scalar/POD `Ptr<T>`, typed allocation/load/store/free, one-way `ptr_addr`
- Linux x86-64 `syscall0`~`syscall6` primitive와 raw kernel 반환값
- shared/mutable reference와 non-lexical borrow 종료
- `&*r` shared reborrow와 `&mut T → &T` 문맥 coercion, child 수명 동안 부모 변경 제한; mutable reborrow는 미지원
- struct·tuple·enum local의 명시적 `&`/`&mut`, field·tuple projection과 whole replacement; move-only aggregate의 whole dereference 취득은 거부
- 파일·함수·중첩 block 안에서만 합성되고 import/caller로 전파되지 않는
  `#global[...]`/`#![...]`/`#scope[...]` lexical capability
- 함수, 재귀, 최대 6개 argument, entry 함수를 포함한 활성 함수 frame 최대 4096개
  (실제 stack은 frame·인자 크기에 따라 먼저 소진될 수 있음)
- statement `if`/`else if`/`else`와 값 expression `if`/`else if`/`else`, `while`, `break`, `continue`, `return`
- 독립 `{ ... }` lexical block, inner shadowing, 모든 정상·제어 흐름 종료의 lexical cleanup
- 개행 없는 `print`, 개행 있는 `println`, String concatenation과 `int_to_str`
- `zeros`, Int/Float `repeat`, `read_text`, `read_ints`, `read_floats` builtin
- program argument
- runtime error의 stderr와 exit status
- `test fn`, entry 선택과 독립 native ELF 기반 `xen test`, deterministic 검색·substring 필터
- Semantic IR borrow origin·forwarding call·reachable later-use note, partial-move field와 capability 경계
- libc 및 외부 compiler/assembler/linker 없는 build

## Native 최적화

`build/run/test --opt=basic`은 정수·Bool 계산 영역 최적화와 제한된 leaf 함수 fusion을
지원한다. 기본값은 `off`이며 `check`는 원본 의미 검사만 수행한다.
상세 범위·예산·보고서는 [최적화 문서](optimization.md)를 따른다.

`#scope[jit]`는 정수·Bool 영역의 실제 runtime 생성·RX 실행·cache 재사용을 지원하는 실험적 기능이다.
범위·실패 동작·비용은 [runtime JIT](jit.md)를 따른다.

## 아직 지원하지 않음

- generic 함수의 반환 기대 타입·본문 기반 추론, 부분 타입 인자 생략, 공통 타입 탐색과 암묵적 숫자 변환
- pointer arithmetic, address→pointer cast, 임의 address 역참조와 자동 lifetime 관리
- struct equality/destructuring과 static/extension/method-local generic method
- package manifest, re-export/visibility와 별도 module search path
- match guard, struct pattern과 destructuring assignment
- Slice 반환·장기 escape·mutable Slice
- Box 내부의 reference·Slice·Ptr 저장, borrowed Box 내부 field의 부분 이동과 borrowed pattern matching
- String indexing·slicing 문법과 mutation (stdlib의 소유 byte 추출은 지원)
- collection 자동 `for`, consuming `into_iter()`와 `map/filter/fold`
- exception, `Option`의 `?` 전파와 `Result` 오류 타입의 암묵 변환 (`std.result.map_err`를 통한 명시 변환은 지원)
- legacy File seek, permission 선택과 lazy directory iterator
- process spawn/wait/pipe와 환경변수 조회 (envp entry 지원 미구현)
- stdin/stdout File wrapping과 asynchronous I/O
- range step, inclusive range와 역방향 range
- 범용 parsing API, streaming input, locale number와 CSV
- `Int` 이외 고정폭 숫자와 Float의 stdlib parsing/formatting
- global·function JIT mode, runtime specialization과 범용 JIT (scalar `#scope[jit]`는 지원)
- FFI, GPU, 다른 architecture/OS target

## 플랫폼과 ABI

현재 target은 Linux x86-64 하나다. compiler는 `_start`, stack frame, 내부 함수 ABI,
instruction encoding과 ELF layout을 직접 만든다. 출력 ELF는 RX text, read-only data,
RW data segment를 분리한다.

이 문서는 데모의 현재 구현을 설명한다. 문법과 API는 바뀔 수 있다.
