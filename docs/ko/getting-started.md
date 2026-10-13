# 시작하기

Native 테스트는 `test fn name() { assert(true); }`로 선언하고 `xen test`로 실행한다.
`main` 없이도 지원하며 [테스트 가이드](testing.md)에 검색·필터·stdlib 검사 규칙이 있다.

## 컴파일러 준비

설치와 소스 빌드 절차는 별도의 [컴파일러 빌드 안내](../compiler-build/ko/build.md)에 있다.
소스 빌드 결과는 `compiler/dist/xen`이며 바이너리 배포본은 `bin/xen`, stdlib와 예제를 제공한다.
배포본을 옮길 때 `bin/`과 `stdlib/`의 구조를 유지해야 한다.
아래 명령에서 소스 빌드 경로 대신 `<package>/bin/xen`이나 `PATH`의 `xen`을 사용할 수 있다.

Xen 프로그램은 Linux x86_64 또는 AArch64에서 실행되며 기본 타깃은 컴파일러의 빌드
아키텍처를 따른다. 프로그램 생성에는 C 컴파일러·assembler·linker·libc가 필요하지 않다.
`xen version` 또는 `xen --version`으로 실행 중인 컴파일러의 버전을 확인할 수 있다.

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

Xen 프로그램의 테스트는 `test fn`과 `xen test`를 사용한다.
[테스트 가이드](testing.md)에서 선언·검색·필터 사용법을 확인할 수 있다.
컴파일러 개발 테스트는 [별도 안내](../../tests/README.md)에 있다.

`#scope[opt]` 안에서 정수·Bool 계산과 제한된 leaf 호출, 루프 불변식을 AOT로
최적화한다. `build/run/test`의 기본값은 `basic`이며 `--opt=off`로 끈다.
`--opt-report`로 영역·분리 이유·변환 횟수를 확인한다. 스코프 밖 코드는 보존한다.
상세 범위는 [스코프 AOT 최적화](optimization.md)를 참고한다.
