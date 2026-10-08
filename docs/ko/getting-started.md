# 시작하기

Native 테스트는 `test fn name() { assert(true); }`로 선언하고 `xen test`로 실행한다.
`main` 없이도 지원하며 [테스트 가이드](testing.md)에 검색·필터·stdlib 검사 규칙이 있다.

## 요구 사항

Xen compiler 자체를 빌드하려면 OCaml과 Dune 3.18 이상이 필요하다. Xen이 생성한 프로그램은
Linux x86-64에서 실행된다. 생성 과정에는 C compiler, assembler, linker 또는
libc가 필요하지 않다.

전체 개발 테스트에는 Python 3.10 이상과 binutils의 `objdump`가 필요하다.
별도의 Python 패키지 설치는 필요하지 않다.

```sh
dune build @release
```

release executable은 `compiler/dist/xen`에 생성된다.

`compiler/dist/xen version` 또는 `compiler/dist/xen --version`으로 컴파일러 버전을
확인한다. 기본값은 저장소의 `VERSION` 파일에 있고 `make build VERSION=...`나
`make package VERSION=...`로 지정한 버전은 실행 파일에 포함된다.

## 첫 프로그램

`hello.xen`을 만든다.

```xen
fn main() {
    println("hello, Xen");
}
```

모든 프로그램에는 parameter가 없고 `Unit`을 반환하는 `main`이 필요하다.

```sh
compiler/dist/xen check hello.xen
compiler/dist/xen build hello.xen -o hello
./hello
```

`check`는 parsing과 type/ownership 검사를 수행한다. `build`는 static non-PIE ELF를
직접 생성한다.

개발 중에는 한 번에 build하고 실행할 수도 있다.

```sh
compiler/dist/xen run hello.xen
compiler/dist/xen run args.xen -- first second
```

`--` 뒤의 값은 Xen 프로그램의 `arg_count()`와 `arg(index)`에서 접근한다. 일반 CLI는
`use std.env;` 뒤 `std.env.args()`로 전체 인자를 `Vec<String>`으로 받을 수 있다.

현재 기능을 주제별로 실행해 보려면 [예제 안내](../../examples/README.md)를 참고한다.
`examples/errors/`의 파일은 진단을 설명하기 위한 입력이므로 `check` 실패가 정상이고
`run` 대상으로 사용하지 않는다.

## 테스트

```sh
make test
```

테스트는 checker 진단과 생성된 ELF의 실제 실행뿐 아니라 Python 의미 모델과 생성된
Xen 프로그램의 결과도 비교한다. property test만 선택해 실행할 수 있다.

```sh
make quickcheck QUICKCHECK_MODE=mixed QUICKCHECK_DEPTH=smoke
make quickcheck QUICKCHECK_MODE=all QUICKCHECK_DEPTH=deep QUICKCHECK_SEED=1234
```

mode는 `regress`, `mixed`, `pairs`, `kitchen`, `illtyped`, `nocrash`, `explore`,
`semantic`, `sweep`, `all` 중 하나고 depth는 `smoke`, `standard`, `deep`, `massive` 중 하나다.
`all`은 고정 회귀, 혼합 프로그램, 잘못된 프로그램과 crash 입력, 의미 변형을 검사한다.
`sweep`은 여기에 모든 emitter pair와 kitchen-sink 조합도 더한다. 실패 시 재현 seed와
축소할 source를 출력한다.

`build/run/test --opt=basic`으로 정수·Bool 계산과 제한된 leaf 함수를 최적화한다.
기본값은 `off`이며 `--opt-report`는 `basic`의 영역·분리 이유·변환 횟수를 stderr에
출력한다. 상세 범위는 [Native 기본 최적화](optimization.md)를 참고한다.

`#scope[jit]`는 작은 정수·Bool 영역을 runtime에 컴파일하는 실험적 기능이다. `--jit=off`로 같은 IR의
AOT와 비교하고 `--jit-report`로 compile·cache 통계를 본다. [Runtime JIT](jit.md)를 참고한다.
