# Learn Xen by running programs / 실행하며 배우는 Xen

Each program demonstrates one task from the [English guide](https://github.com/skystarry-team/Xen/blob/main/docs/en/README.md)
or [한국어 문서](https://github.com/skystarry-team/Xen/blob/main/docs/ko/README.md).
Start with `hello.xen` and continue through the table.

`hello.xen`부터 순서대로 실행하며 익힐 수 있습니다. 아래 명령은 저장소 또는
배포본의 루트 디렉터리에서 실행합니다. `xen`을 PATH에 추가하거나, 배포본에서는
`./bin/xen`, 저장소에서는 `compiler/dist/xen`으로 바꾸세요.

Run these commands from the repository or distribution root. Put `xen` on PATH,
or substitute `./bin/xen` for a distribution and `compiler/dist/xen` for a source checkout.

| File | Learn / 배울 내용 | Expected stdout / 예상 출력 (`\n` is a newline) |
| --- | --- | --- |
| `hello.xen` | First program / 첫 프로그램 | `Hello, Xen!\n` |
| `variables.xen` | Names, changes, numbers / 변수와 숫자 | `36\n18.0\n` |
| `control_flow.xen` | Functions and loops / 함수와 반복 | `20\nenough\n2\n1\n` |
| `collections.xen` | Strings, vectors, views / 문자열과 컬렉션 | `green\n3\n[11, 20]\n20\n` |
| `iterators.xen` | Transforming items / 항목 변환 | `4\n6\n` |
| `types.xen` | Structs, enums, tuples / 구조체와 enum | `todo: read the guide\ndue in 2\nanswer: 42\n` |
| `generics.xen` | Reuse with different types / 타입 재사용 | `7\nhello\n` |
| `ownership.xen` | Copies, references, moves / 복사·참조·이동 | `[1, 2, 3]\n[1, 2]\n[1, 2, 3]\n42\n` |
| `recursive_data.xen` | Connected values / 연결된 값 | `30\n` |
| `errors.xen` | Handling failed input / 잘못된 입력 처리 | `42\nPlease enter a decimal integer.\n` |
| `modules/app.xen` | Split a program across files / 파일 나누기 | `tea: 3\n` |
| `hashmap.xen` | Lookup by key / 키로 값 찾기 | `3\n2\n` |
| `word_count.xen` | Read a file / 파일 읽기 | `4\n` with the input below |
| `stdin_words.xen` | Read a pipeline / 파이프 입력 읽기 | `one\ntwo\nthree\n` with the input below |
| `testing.xen` | Test a function / 함수 테스트 | `2 passed; 0 failed` after two PASS lines |
| `demo.xen` | Split and print words / 단어 나누기 | `Hello\nfrom\nXen\n` |
| `arm64_core.xen` | A greeting / 인사말 | `Hello, Xen!\n` |

For the ordinary programs, replace `hello` with a filename from the table:

```sh
xen check examples/hello.xen
xen run examples/hello.xen
xen build examples/hello.xen -o hello
./hello
xen run examples/modules/app.xen
```

파일과 표준 입력 예제 / File and stdin examples:

```sh
printf 'one two\nthree four\n' > input.txt
xen run examples/word_count.xen -- input.txt
printf 'one two\nthree\n' | xen run examples/stdin_words.xen
```

The first command creates or overwrites `input.txt` in the current directory.
첫 명령은 현재 디렉터리의 `input.txt`를 만들거나 덮어씁니다.
`word_count` expects exactly one path; a missing file terminates with an error.
`stdin_words` waits for the end of input if run without a pipeline.
단어 수 예제에는 경로 하나가 필요하며, 없는 파일은 오류가 납니다.
표준 입력 예제를 파이프 없이 실행하면 입력 끝을 기다립니다.

Run the test-only example with `test`:

```console
$ xen test examples/testing.xen
PASS testing.doubles_a_number
PASS testing.empty_vector
2 passed; 0 failed
```

`demo.xen` and `arm64_core.xen` also keep the commands in the installation guide
usable. Every ordinary example can be built for either supported Linux target;
run the resulting executable on a compatible machine.
