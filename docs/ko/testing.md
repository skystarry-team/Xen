# xen test

테스트는 기존 function 선언에 `test`를 붙인다. nongeneric, parameterless Unit 함수만
허용하며 일반 함수 mode attribute도 앞에 둘 수 있다. `assert`, `assert_msg`, `panic`은
기존 builtin을 그대로 사용한다.

```xen
test fn vec_push() {
    let mut xs = [1, 2];
    xs.push(3);
    assert(xs.len() == 3);
}

#![bb]
test fn raw_storage() {
    let p = raw_alloc<Int>(1);
    raw_store(p, 0, 7);
    assert(raw_load(p, 0) == 7);
    raw_free(p);
}
```

```sh
xen test                       # 현재 directory를 project root로 검색
xen test tests.xen              # 이 파일과 project dependency graph의 테스트
xen test src                    # src를 하나의 project root로 재귀 검색
xen test --filter vec           # 전체 표시 이름의 substring 필터
xen test std.fs                 # toolchain loader를 통한 std.fs 자체 테스트
xen test std.fs --filter null
```

Discovery는 sorted `.xen` 파일과 loaded project module을 기준으로 하며 같은 source
함수를 중복 실행하지 않는다. Directory 검색에서는 전체 directory를 source root로
유지하므로 `lib/math.xen`의 `import common.model;`도 root의 `common/model.xen`을 읽는다.
명시적 file 입력은 기존 build/run과 동일하게 그 파일의 directory를 root로 쓴다.
Hidden directory, `_build`, `dist`, `stdlib`과 symlink directory/file은 재귀 검색하지
않는다. Toolchain source는 project entry의 namespace 제한을 우회하지 않고 `std.fs`
같은 module selector로 검사한다. App에 stdlib을 `use`했다고 stdlib 테스트를 함께
실행하지 않는다. 현재 project model에는 manifest나 dependency package search가 없다.
이미 존재하는 file/directory는 module selector보다 우선하므로 `std.xen`, `core.xen`,
`std.tools/` 같은 project 경로도 사용할 수 있다. 선언의 예약 namespace 제한은 유지한다.

각 테스트를 기존 checker·monomorphization·Semantic IR·의미 분석·cleanup·verifier·native
backend로 compile하고 해당 Unit 함수를 entry로 갖는 독립 static ELF process에서 실행한다.
`main` 선언은 필요 없고, 있더라도 test entry 대신 실행하지 않는다. Native encoder나
ELF writer에는 별도 test backend를 추가하지 않았다.

```text
PASS app.vec_push
FAIL app.bad_case (exit 1)
1 passed; 1 failed
```

성공한 테스트의 stdout/stderr는 숨기며 실패한 테스트의 출력은 보존한다. stdin은
`/dev/null`, 인자는 비어 있고 cwd와 환경은 runner에서 상속한다. Assertion/panic의
기존 runtime 문자열과 함께 test 함수의 source 위치를 표시한다. Runtime이 제공하는
연산 위치도 그대로 보존하고 compile 오류의 error/note/help를 기존 형식으로 출력한다.
실패 뒤에도 나머지 테스트를 실행한다. Exit status는 전체 성공 0, 실패·compile/discovery
오류·일치하는 테스트 없음 1, CLI 사용법 오류 2다.

선택된 테스트를 포함한 source graph 전체를 check하므로 filter가 다른 함수의 type
오류를 감추지는 않는다. 첫 버전에는 fixture, mock, snapshot, async, plugin, timeout
framework가 없다. 끝나지 않는 테스트는 현재 `xen run`처럼 직접 중단해야 한다.

`make test`는 기존 compiler/native/property 검사 외에 loader·archive relocation,
stdlib API와 test CLI 회귀를 포함한다. `tests/integration/test_workflow_test.py`는 no-main/필터/순서,
실패 후 계속 실행, 진단, test signature/mode, recursive root와 stdlib selector를 검사한다.
