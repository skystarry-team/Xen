# Xen 한국어 문서

영어 사용자 문서와 현재 구현 기준의 참조서는 [English documentation](../en/README.md)을
참고한다.

- [Linux CLI 표준 라이브러리](stdlib.md): path, cwd, process identity, binary I/O, metadata와 directory
- [의미 진단](diagnostics.md): borrow origin/later use, partial move와 capability 경계
- [xen test](testing.md): native 테스트 선언, 검색과 실행

이 문서는 현재 `main` 브랜치에 구현된 기능을 기준으로 한다. 계획 중인 문법은
별도로 표시하며, 아직 구현되지 않은 기능을 언어 사양처럼 설명하지 않는다.

- [시작하기](getting-started.md): 빌드, 검사, ELF 생성과 실행
- [언어 가이드](language-guide.md): 기능별 문서의 시작점과 빠른 참고
- [기본 문법과 타입](language-basics.md): 변수, 숫자, 함수, 제어 흐름과 기본 builtin
- [String과 Vec](strings-and-vectors.md): byte string, Vec API와 파일 읽기 builtin
- [소유권과 reference](ownership-and-references.md): clone, move, drop, borrow 규칙
- [Box와 재귀 aggregate](box-and-recursive-aggregates.md): 명시적 owning indirection과 재귀 tree
- [제네릭, enum, match](generics-enums-and-match.md): 단형화, tuple, exhaustive match
- [모듈과 구조체](modules-and-structs.md): source-root import와 named struct
- [저수준 `bb`](low-level-bb.md): lexical capability와 raw memory
- [File/I/O API](file.md): recoverable std.fs/std.io와 owned File 호환 API
- [구현 상태와 제한](status-and-limitations.md): 지원 범위와 아직 없는 기능
- [Semantic IR](semantic-ir.md): CFG·provenance·cleanup의 구현 계약
- [Semantic IR 검증](semantic-testing.md): 생성·변형·축소와 재현 명령

`build/run/test --opt=basic`으로 정수·Bool 계산과 제한된 leaf 함수를 최적화한다.
기본값은 `off`이며 `--opt-report`는 `basic`의 영역·분리 이유·변환 횟수를 stderr에
출력한다. 상세 범위는 [Native 기본 최적화](optimization.md)를 참고한다.

`#scope[jit]`는 작은 정수·Bool 영역을 runtime에 컴파일하는 실험적 기능이다. `--jit=off`로 같은 IR의
AOT와 비교하고 `--jit-report`로 compile·cache 통계를 본다. [Runtime JIT](jit.md)를 참고한다.
