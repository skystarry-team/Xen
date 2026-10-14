# 내 코드 테스트하기

`test fn`으로 작은 동작을 확인하는 함수를 작성합니다. 테스트 함수는 인자가 없고 결과를 반환하지 않습니다. `main` 없이 테스트만 있는 파일은 `xen test`로 검사하고 실행합니다. 일반 `check`·`run`·`build` 명령을 사용하려면 `main`이 필요합니다. 다음을 `testing.xen`으로 저장하세요.

```xen
fn doubled(value: Int) -> Int {
    return value * 2;
}

test fn doubles_a_number() {
    assert(doubled(3) == 6);
}

test fn empty_vector() {
    let values: Vec<Int> = [];
    assert_msg(values.len() == 0, "an empty vector has no items");
}
```

```console
$ xen test testing.xen
PASS testing.doubles_a_number
PASS testing.empty_vector
2 passed; 0 failed
```

`assert`는 조건이 참인지 검사합니다. `assert_msg`는 실패했을 때 보여 줄 설명을 추가합니다. 첫 테스트의 기대값을 7로 바꾸고 실패가 표시되는지 확인해 보세요.

## 테스트 선택하기

```sh
xen test testing.xen --filter doubles
xen test .
xen test std.string
```

파일, 디렉터리, 표준 라이브러리 모듈을 지정할 수 있습니다. 대상 없이 `xen test`를 실행하면 현재 디렉터리에서 찾습니다. `--filter`는 테스트 이름에 포함된 문자열로 선택합니다. 테스트가 없거나 필터와 맞는 이름이 없으면 실패합니다.

디렉터리를 지정하면 그 디렉터리를 기준으로 프로젝트 모듈을 찾습니다. 숨김 디렉터리와 `_build`, `dist`, `stdlib`, 심볼릭 링크는 자동 탐색에서 건너뜁니다. 디렉터리에 `stdlib`이 있어도 `xen test std.string`처럼 명시적으로 선택할 수 있습니다.

## 실행 결과

테스트는 이름 순으로 각각 실행되고, 하나가 실패해도 나머지를 계속합니다. 성공한 테스트의 출력은 숨기고 실패한 테스트의 출력은 보여 줍니다. 테스트 함수에서는 인자가 없고 표준 입력은 비어 있습니다. 작업 디렉터리와 환경은 명령을 실행한 곳을 따릅니다.

파일 입력이 필요한 테스트는 직접 임시 데이터를 준비해야 합니다. 현재 별도 fixture·mock·비동기 테스트 기능이나 자동 시간 제한은 없습니다. 끝나지 않는 테스트는 직접 중단해야 합니다.

필터를 사용해도 같은 프로젝트 안의 다른 함수에 있는 타입 오류는 검사합니다. 모든 선택된 테스트가 통과하면 종료 상태는 0, 오류나 실패가 있으면 1입니다.

---

[목차](README.md) · [이전: 파일의 단어 수 세기](tutorial.md) · [다음: 표준 라이브러리 찾기](stdlib.md) · [English](../en/testing.md)
