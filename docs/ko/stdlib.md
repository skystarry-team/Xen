# 표준 라이브러리 찾기

필요한 작업에 맞는 모듈을 `use std.name;`으로 가져옵니다. `as`로 별명을 붙일 수 있습니다. 여기서는 프로그램에서 자주 쓰는 API를 정리합니다. `Int`는 정수, `String`은 바이트열이고, `IoError`는 `std.io.IoError`입니다.

## 텍스트와 숫자

| API | 결과와 사용법 |
| --- | --- |
| `std.convert.parse_int(text: String)` | `Result<Int, ParseIntError>`; 부호가 있는 10진 정수 읽기 |
| `std.convert.format_int(value: Int)` | 10진 문자열 |
| `std.string.find(text: String, needle: String)` | `Option<Int>`; 첫 바이트 위치, 없으면 `None` |
| `std.string.contains(text: String, needle: String)` | `Bool`; 포함 여부 |
| `std.string.slice_bytes(text: String, start: Int, end: Int)` | `Result<String, BoundsError>`; 끝을 제외한 구간을 복사 |
| `std.string.split_byte(text: String, separator: U8)` | `Vec<String>`; 구분 바이트로 분리, 빈 항목 유지 |
| `std.string.split_ascii_whitespace(text: String)` | `Vec<String>`; ASCII 공백으로 분리, 빈 항목 제외 |
| `std.string.is_ascii_whitespace(byte: U8)` | 공백 또는 바이트 9~13인지 확인 |

`parse_int`는 앞뒤 공백을 제거하지 않습니다. `+`나 `-` 뒤에 적어도 한 자리 숫자가 필요합니다. 오류는 `ParseIntError.Empty`, `InvalidDigit((위치, 바이트))`, `Overflow`입니다. 표준 라이브러리에는 실수 문자열을 파싱·포맷하는 대응 함수가 없습니다.

문자열 위치와 길이는 바이트 기준입니다. 검색어가 빈 문자열이면 `find`는 `Some(0)`, `contains`는 `true`입니다. `slice_bytes`에는 `0 <= start <= end <= text.len()`이 필요합니다. 잘못된 범위는 `BoundsError.InvalidRange((start, end, length))`입니다. 빈 문자열을 `split_byte`로 나누면 빈 문자열 하나가 나옵니다.

## 인자와 경로

| API | 결과와 사용법 |
| --- | --- |
| `std.env.args()` | `Vec<String>`; 실행 파일 이름을 제외한 프로그램 인자 |
| `std.env.cwd()` | `Result<String, IoError>`; 현재 작업 디렉터리 |
| `std.path.is_absolute(path: String)` | `/`로 시작하는지 확인 |
| `std.path.join(left: String, right: String)` | 경로 연결; 오른쪽이 절대 경로이면 오른쪽을 사용 |
| `std.path.basename(path: String)` | 마지막 경로 요소 |
| `std.path.dirname(path: String)` | 부모 경로; 상대 파일 이름만 있으면 `"."` |
| `std.process.id()`, `std.process.parent_id()` | 현재·부모 프로세스의 ID |

경로 함수는 `/`를 사용하며 파일에 접근하지 않습니다. `.`과 `..`를 정리하거나 심볼릭 링크를 따라가지 않습니다. 환경 변수 읽기, 다른 프로그램 실행, 파이프 생성은 현재 지원하지 않습니다.

## 파일과 입출력

| API | 반환값 |
| --- | --- |
| `std.fs.read(path: String)` | `Result<String, IoError>`; 파일 전체 읽기 |
| `std.fs.write(path: String, contents: String)` | `Result<Int, IoError>`; 생성하거나 덮어쓰고 쓴 바이트 수 반환 |
| `std.fs.append(path: String, contents: String)` | `Result<Int, IoError>`; 뒤에 추가, 없으면 생성 |
| `std.fs.copy(source: String, destination: String)` | `Result<Int, IoError>`; 전체를 읽어 대상에 덮어쓰기 |
| `std.fs.metadata(path: String)` | `Result<std.fs.Metadata, IoError>` |
| `std.fs.read_dir(path: String)` | `Result<Vec<String>, IoError>`; 바로 아래 항목 이름 |
| `std.io.read_stdin()` | `Result<String, IoError>`; 입력 끝까지 읽기 |
| `std.io.write_stdout(text: String)`, `std.io.write_stderr(text: String)` | `Result<Int, IoError>`; 쓴 바이트 수 |
| `std.io.describe_error(error: IoError)` | 오류를 설명하는 문자열 |

쓰는 API는 파일 내용을 바꿉니다. 특히 `write`와 `copy`는 기존 대상 내용을 지웁니다. 경로에는 NUL 바이트를 넣을 수 없습니다. `read`, `copy`, `read_stdin`은 전체 입력을 메모리에 담습니다. 표준 입력을 직접 읽으면 입력이 끝날 때까지 기다립니다. 파일 대신 파이프로 전달하는 방법은 다음과 같습니다.

```xen
use std.io as io;
use std.string as text;

fn main() {
    let contents = match io.read_stdin() {
        Result.Ok(value) => value,
        Result.Err(error) => { panic(io.describe_error(error)); },
    };
    let words = text.split_ascii_whitespace(contents);
    for index in 0..words.len() {
        println(words.get(index));
    }
}
```

```console
$ printf 'one two\nthree\n' | xen run stdin_words.xen
one
two
three
```

`Metadata`에는 `size: Int`, `modified_seconds: Int`, `is_file: Bool`, `is_directory: Bool`이 있습니다. 수정 시간은 Unix 기준 시각부터의 초입니다. 메타데이터 조회는 심볼릭 링크를 따라갑니다. `read_dir`는 하위 디렉터리에 들어가지 않고 `.`과 `..`를 제외하며 결과 순서는 보장하지 않습니다.

`IoError`의 형태는 `InvalidPath`, `Open(Int)`, `Read(Int)`, `Write(Int)`, `WriteZero`, `Close(Int)`, `Metadata(Int)`, `Directory(Int)`, `Cwd(Int)`, `InvalidDirectoryEntry`입니다. 사용자에게 보여 줄 메시지는 `describe_error`로 만드세요.

## 사전: HashMap

문자열 키로 값을 찾을 때는 `std.hashmap.HashMap<V>`를 사용합니다. 다음을 `hashmap.xen`으로 저장하세요.

```xen
use std.hashmap as hashmap;

#![explc]
fn main() {
    let mut prices = hashmap.new<Int>();
    prices.insert("tea", 3);
    prices.insert("coffee", 4);
    let key = "tea";
    println(match prices.get_cloned(&key) {
        Option.Some(price) => price,
        Option.None => 0,
    });
    println(prices.len());
}
```

```console
$ xen run hashmap.xen
3
2
```

| 작업 | API |
| --- | --- |
| 새 사전 | `std.hashmap.new<V>()` |
| 개수·비어 있음 | `map.len()`, `map.is_empty()` |
| 추가·변경 | `map.insert(key, value)`; 이전 값이 있으면 `Some`으로 반환 |
| 검색 | `map.get_cloned(&key)`; 값의 사본을 `Option`으로 반환 |
| 존재 확인 | `map.contains_key(&key)` |
| 제거 | `map.remove(&key)`; 제거한 값을 `Option`으로 반환 |
| 키 목록 | `map.keys()`; 독립적인 `Vec<String>` |
| 비우기 | `map.clear()` |
| 소유권을 넘기고 반복 | `map.into_iter()`; `(String, V)` 항목 |

사전 자체는 이동 전용입니다. `get_cloned`는 `Box`·`File`처럼 복사할 수 없는 값을 읽을 때 쓸 수 없습니다. 그런 값은 `remove`로 꺼내거나 `std.hashmap.with_value<V, R>(&map, &key, inspect)`의 이름 있는 `fn(&V) -> R` 콜백으로 확인하세요. 참조를 직접 넘기는 함수에는 `explc`가 필요합니다. 키 목록과 반복의 순서는 보장하지 않습니다. 사전의 필드를 직접 변경하는 대신 API를 사용하세요.

## 결과·반복·교체 도우미

`std.option.unwrap_or<T>(value, fallback)`은 없는 값의 기본값을 선택합니다. `std.result.map_err<T, E, F>(value, convert)`는 오류만 변환합니다. [오류 처리](error-handling.md)에서 설명합니다.

`use std.iter;`는 `.iter()`, `.into_iter()`, `.map(...)`, `.filter(...)`, `.enumerate()`를 사용할 때 필요합니다. `std.iter.fold<I, T, A>(iterator, initial, step)`은 `fn(A, T) -> A` 콜백으로 순서대로 누적하며, 빈 입력에서는 `initial`을 돌려줍니다. `std.iter.collect<I, T>(iterator)`는 항목을 새 벡터로 모읍니다. 타입을 결정할 수 없으면 모든 타입 인자를 명시하세요. [컬렉션](collections.md)에 실행 예제가 있습니다.

`use std.mem;`의 `std.mem.replace<T>(&mut target, value)`는 이전 값을 반환하며 새 값으로 교체합니다. 명시적 참조를 쓰므로 `explc`가 필요합니다.

## 기존 File API를 읽을 때

`open_read(path)`·`open_write(path)`는 `File`을 만듭니다. `open_write`는 생성하거나 덮어씁니다. 변경 가능한 File의 `read()`는 현재 위치부터 끝까지 읽고 `write(text)`는 현재 위치에 씁니다. `close()`로 닫으며 여러 번 닫아도 됩니다. `is_open()`으로 상태를 확인할 수 있습니다. File은 이동 전용이며 블록을 나가면 자동으로 닫힙니다. 실패하면 프로그램이 종료되므로 실패를 직접 처리하려는 새 코드에는 `std.fs`·`std.io`를 사용하세요. File에는 seek나 append 메서드가 없습니다.

---

[목차](README.md) · [이전: 내 코드 테스트하기](testing.md) · [다음: 명령어 안내](cli.md) · [English](../en/stdlib.md)
