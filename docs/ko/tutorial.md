# 파일의 단어 수 세기

이제 파일 경로를 받아 그 파일의 단어 수를 출력하는 프로그램을 만듭니다. 변수·함수·문자열·오류 처리를 한 프로그램에서 사용합니다.

## 입력 준비하기

작업 디렉터리에서 테스트할 파일을 만드세요.

```sh
printf 'one two\nthree four\n' > input.txt
```

이 명령은 해당 디렉터리의 `input.txt`를 만들거나 덮어씁니다. 다음 코드를 `word_count.xen`에 저장하세요.

```xen
use std.env as env;
use std.fs as fs;
use std.io as io;
use std.string as text;

fn count_file(path: String) -> Result<Int, io.IoError> {
    let contents = fs.read(path)?;
    return Result.Ok(text.split_ascii_whitespace(contents).len());
}

fn main() {
    let arguments = env.args();
    if arguments.len() != 1 {
        panic("usage: word_count <path>");
    }
    match count_file(arguments.get(0)) {
        Result.Ok(count) => println(count),
        Result.Err(error) => { panic(io.describe_error(error)); },
    };
}
```

```console
$ xen run word_count.xen -- input.txt
4
```

## 코드 읽기

`env.args()`는 프로그램에 전달된 인자만 돌려줍니다. 실행 파일 이름은 포함하지 않습니다. `--` 뒤의 `input.txt`가 첫 번째 인자입니다. 경로에 공백이 있으면 셸에서 큰따옴표로 감싸세요.

`count_file`은 `fs.read`로 파일 전체를 읽고, 실패하면 `?`로 오류를 전달합니다. 성공하면 ASCII 공백으로 나눈 항목 수를 반환합니다. `main`에서는 성공한 개수를 출력하거나 읽기 오류를 설명하고 종료합니다.

이 프로그램의 '단어'는 ASCII 공백으로 구분된 바이트열입니다. 문장부호를 없애거나 언어별 단어를 분석하지 않습니다. 파일 전체를 한 번에 읽으므로 매우 큰 파일에는 적합하지 않습니다.

## 실패도 실행해 보기

존재하지 않는 경로를 전달해 보세요.

```sh
xen run word_count.xen -- missing.txt
```

파일 열기 오류가 표시되고 실패 상태로 종료합니다. `--` 뒤에 경로를 주지 않으면 `usage: word_count <path>` 메시지가 표시됩니다. 정확한 파일 오류 숫자는 실행 환경에 따라 다릅니다.

## 독립 실행 파일 만들기

```sh
xen build word_count.xen -o word-count
./word-count input.txt
```

결과는 역시 4입니다. 직접 실행할 때는 Xen 명령의 구분자였던 `--`가 필요하지 않습니다.

## 다음 작업

여러 경로를 받아 각 파일의 개수를 출력하도록 바꿔 보세요. 오류가 나도 다른 파일을 계속 처리하려면 `main`의 오류 갈래를 변경하세요. 표준 입력에서 읽는 버전은 [stdin_words 예제](../../examples/stdin_words.xen)에 있습니다. 단어 수 계산을 별도 함수로 나누면 [다음 장](testing.md)의 테스트를 붙이기 쉬워집니다.

---

[목차](README.md) · [이전: 여러 파일로 나누기](modules.md) · [다음: 내 코드 테스트하기](testing.md) · [English](../en/tutorial.md)
