# Linux CLI 표준 라이브러리

모든 module은 `use std.<name>;`로 가져온다. 이 API들은 별도 Xen source로 구현되며
일반 Semantic IR·분석·직접 native backend를 거친다. 아래 high-level 호출은 caller의
`bb`/`explc`를 요구하지 않는다. String과 filename은 UTF-8 검증 없는 byte sequence다.

## 경로

`std.path`는 filesystem을 접근하지 않는 Linux `/` separator 연산이다.

| API | 계약 |
| --- | --- |
| `is_absolute(String) -> Bool` | 첫 byte가 `/`; 빈 경로는 false |
| `join(String, String) -> String` | 오른쪽이 절대 경로면 오른쪽, 빈 쪽은 다른 쪽, 그 외 separator 연결 |
| `basename(String) -> String` | trailing slash 제외 마지막 component; 빈 경로 `""`, root `"/"` |
| `dirname(String) -> String` | 마지막 component 제외; 빈/단일 상대 경로 `"."`, root `"/"` |

`.`/`..`와 symlink를 정규화하지 않는다. 예를 들어 `join("a", "../b")`는
`"a/../b"`다. 이를 지우면 filesystem symlink를 따라가는 의미가 달라질 수 있다.

## 환경과 process identity

`std.env.args()`는 기존 순서의 인자 목록을 반환한다. `cwd() -> Result<String,
std.io.IoError>`는 kernel `getcwd`로 절대 경로를 얻으며 삭제된 cwd, unreachable cwd와
4096-byte kernel 제한 등의 실패를 `IoError.Cwd(errno)`로 반환한다.
[Linux getcwd 계약](https://man7.org/linux/man-pages/man3/getcwd.3.html)을 따른다.

`std.process.id()`와 `parent_id()`는 각각 process ID와 parent process ID를 `Int`로
반환한다. 현재 API는 process identity 지원이다. 실행/spawn/wait/pipe는 아직 없다.
환경변수 조회도 아직 없다. `_start`가 envp를 보존하지 않고 `ptr_addr`는 one-way이므로,
후속 환경 API는 제한된 process-entry primitive 설계를 별도로 검토해야 한다. 이를
우회하는 address-to-pointer 변환이나 unrestricted dereference는 추가하지 않았다.

## Byte I/O와 파일

기존 `Vec<U8>`, `String.as_bytes()`, `Vec<U8>.into_string()`을 buffer로 사용한다.
새 buffer abstraction은 없다. `std.io.read_fd(Int)`와 `read_stdin()`은 EOF까지 binary
String을 읽어 `Result<String, IoError>`로 반환한다. `read_fd`는 caller의 fd를 닫지
않으며 `std.fs.read_open`은 이 API를 재사용하는 호환 wrapper다. 기존 `write_fd`,
`write_stdout`, `write_stderr`는 partial write와 EINTR를 처리한다.

`std.fs`의 `read`, `write`, `copy`와 동일한 error/cleanup 규칙으로 다음 API를 제공한다.

| API | 결과와 계약 |
| --- | --- |
| `append(path, contents)` | `Result<Int, IoError>`; 기존 내용을 보존하고 뒤에 씀; 없으면 생성 |
| `metadata(path)` | `Result<Metadata, IoError>`; symlink를 따라감; open read permission 불필요 |
| `read_dir(path)` | `Result<Vec<String>, IoError>`; dot entry 제외 이름 목록; 재귀 없음 |

`Metadata`는 `size: Int`, `modified_seconds: Int` (epoch 이후 초), `is_file: Bool`,
`is_directory: Bool` field를 갖는다. Linux x86-64 kernel `struct stat` layout을 사용한다.
파일 생성 mode는 `write`와 같은 0644이며 process umask가 적용된다. append syscall
개별 write의 O_APPEND 동작을 사용하고, 전체 여러 write의 원자성은 보장하지 않는다.
embedded NUL은 모든 filesystem pathname API에서 `InvalidPath`다.

Directory 목록은 [Linux getdents64](https://man7.org/linux/man-pages/man2/getdents.2.html)의
순서를 보존하며 정렬·snapshot 안정성은 보장하지 않는다. 기존 `use std.iter;`와
`.iter()`로 순회할 수 있다. `d_type`의 지원 여부에 의존하지 않으며 type은 필요할 때
`metadata`로 조회한다. `decode_directory(Slice<U8>)`는 header, record length/end와
NUL terminator를 검사하는 safe Xen decoder다. 잘못된 record는 `InvalidDirectoryEntry`다.

`IoError`는 기존 variants에 `Metadata(Int)`, `Directory(Int)`, `Cwd(Int)`,
`InvalidDirectoryEntry`를 추가했다. `describe_error`도 이를 처리한다. fd close와 raw
buffer free 뒤에 operation error를 전파하며, operation이 성공한 경우 close 실패를
전파한다. runtime panic/error의 무 unwind 정책은 기존과 같다.

## Byte 문자열 처리

`use std.string;` 아래 다음 API는 NUL·비 UTF-8 byte를 그대로 보존한다.

| API | 계약 |
| --- | --- |
| `slice_bytes(text: String, start: Int, end: Int) -> Result<String, BoundsError>` | `[start,end)`를 새 소유 String으로 복사; `0 <= start <= end <= len(text)` 필요 |
| `find(text: String, needle: String) -> Option<Int>` | 첫 일치의 byte offset; 빈 needle은 `Some(0)`, 미발견은 `None` |
| `contains(text: String, needle: String) -> Bool` | 빈 needle을 포함한 일치 여부 |
| `split_byte(text: String, separator: U8) -> Vec<String>` | 선행·연속·후행 구분자의 빈 항목 보존; 빈 입력은 `[""]` |

잘못된 범위는 `BoundsError.InvalidRange((start,end,length))`, 유효한 빈 범위는
`Ok("")`다. UTF-8 encoding 중간을 잘라도 검증·정규화하지 않는다. 결과는 소유하며
Slice가 escape하지 않는다. 내부 라이브러리 호출을 포함한 일반 by-value String clone
규칙과 allocation 실패의 runtime error를 유지한다. 특별한 borrowed 전달 규칙은 없다.
기존 ASCII whitespace 분해는 연속 공백의 빈 token을 생략하는 기존 계약을 유지한다.

[key-value CLI](../../examples/key_values.xen)는 stdin 또는 파일의 LF 구분 `key=value`를
읽는다. 빈 줄을 무시하고 빈 값·첫 `=` 뒤의 추가 `=`·공백·NUL·비 UTF-8을 보존한다.
`=` 누락·빈 key는 1부터 센 줄 번호를 진단한다. CR은 일반 byte이며 설정 형식이나
CRLF를 정규화하는 parser는 아니다.

## `std.option`과 `std.result`

| API | 계약 |
| --- | --- |
| `std.option.unwrap_or<T>(value: Option<T>, fallback: T) -> T` | `Some`의 값 또는 fallback을 반환 |
| `std.result.map_err<T, E, F>(value: Result<T, E>, convert: fn(E) -> F) -> Result<T, F>` | `Ok`는 보존하고 `Err` payload를 변환 |

두 helper는 일반 by-value 전달을 따른다. clone 가능한 값은 기존 copy/clone 규칙을,
move-only 값은 이동 규칙을 따른다. `unwrap_or`의 fallback은 호출 전에 평가되므로
`Some`이어도 평가되며 사용하지 않은 move-only 값은 정상 정리된다. `map_err`는 concrete
named function 값을 `Err`에서 한 번 호출하고 `Ok`에서는 호출하지 않는다. 오류 payload도
같은 규칙으로 by-value 전달된다. lazy fallback, closure, generic function value, 암묵적
오류 변환을 추가하지 않는다. generic 인자는 기존 추론 규칙을 따르며 정적 인자 타입에서
결정할 수 없으면 명시해야 한다.

오류를 바깥 함수의 오류 타입으로 바꾼 뒤 기존 동일 타입 `?`로 전파할 수 있다.

```xen
use std.fs;
use std.io;
use std.result;

enum AppError { Io(std.io.IoError) }

fn from_io(error: std.io.IoError) -> AppError {
    return AppError.Io(error);
}

fn read_config(path: String) -> Result<String, AppError> {
    let contents = std.result.map_err(std.fs.read(path), from_io)?;
    return Result.Ok(contents);
}
```

[key-value CLI](../../examples/key_values.xen)는 두 helper를 사용해 I/O·byte 범위 오류를
parse 오류와 하나의 `AppError`로 합친다.

## Iterator 변환

`use std.iter;` 뒤에 `Vec<T>.into_iter()`는 cloneable Vec도 소비하고 원래 순서로 owned
element를 반환한다. Iterator 자체는 move-only이며 조기 종료 시 남은 element를 정리한다.
`.map(fn(T)->U)`·`.filter(fn(&T)->Bool)`는 receiver를 소비하는 lazy adapter다.
Concrete named function을 받으며 생성 시 callback을 실행하지 않는다. Map은 by-value,
filter는 받은 item을 predicate 호출 동안만 공유 대여하고 탈락한 item을 drop한다.
Filter는 Unit 등 대여 불가능한 타입을 받지 않는다. 두 adapter는 첫 None 이후 계속 None이다.
Borrowed iter chain은 마지막 사용까지 원래 source의 loan을 유지한다.

```xen
use std.iter;
fn twice(value: Int) -> Int { return value * 2; }
#![explc]
fn large(value: &Int) -> Bool { return *value > 2; }
fn main() {
    let values = [1, 2, 3];
    for value in values.iter().map(twice).filter(large) { println(value); }
}
```

결과는 `4`, `6`이다. 같은 이름의 inherent method가 있으면 그것을 우선하며 iterator import를
요구하지 않는다. Predicate는 자신의 explc를 제공하고 adapter 생성은 caller의 explc를
요구하지 않는다. Collection 자체를 for에 넘기는 자동 변환은 없다.

`std.iter.fold<I,T,A>(iterator,initial,step:fn(A,T)->A)->A`는 순서대로 left fold하며 빈
iterator는 initial을 반환한다. Iterator·accumulator·callback 인자에 일반 copy/clone/move
규칙을 적용한다. `std.iter.collect<I,T>`는 순서를 보존하는 eager Vec을 만든다. T를 인자에서
추론할 수 없으면 `std.iter.collect<std.iter.IntoIter<Int>,Int>(values.into_iter())`처럼 모든
타입 인자를 명시한다. For는 move-only iterator를 loop owner로 이동시킨다. 바깥 iterator의
next를 호출하는 수동 while loop는 break 후 그 iterator를 이어서 사용할 수 있다.

## HashMap과 소유값 교체

`use std.hashmap;`의 `std.hashmap.HashMap<V>`는 String byte key를 쓰는 move-only map이다.
빈 key·NUL·invalid UTF-8을 허용하고 byte equality로 collision을 구분한다. 순회와 key snapshot
순서는 보장하지 않는다. Hash table의 expected amortized probe 수는 상수지만 hash는 key byte
길이에 비례하며 collision에서는 전체 table을 검사할 수 있다.

| API | 동작 |
| --- | --- |
| `new<V>()`, `len()`, `is_empty()` | 생성·entry 수 조회 |
| `insert(key:String,value:V)->Option<V>` | 중복 value 교체 후 이전 값 반환; 길이 유지 |
| `remove(key:&String)->Option<V>` | 삭제한 값의 소유권 이전; 없으면 None |
| `contains_key(key:&String)` | Key/value 복제 없이 존재 확인 |
| `get_cloned(key:&String)->Option<V>` | Owned copy/clone; move-only 값은 거부 |
| `with_value<V,R>(&HashMap<V>,&String,fn(&V)->R)->Option<R>` | 존재할 때 callback 동안만 대여; reference escape 금지 |
| `keys()->Vec<String>`, `clear()` | Owned key snapshot·entry 정리 |
| `into_iter()` | Map을 소비하고 owned `(String,V)` entry 반환 |

명시적 reference 인자는 explc가 필요하다. File·Box의 삽입/교체/삭제/consuming 순회는 값을
clone하지 않는다. 반환한 이전/삭제 값을 버리면 정상 cleanup이 정리한다. Unit은 저장과
owned 조회를 지원하지만 reference callback과 `(String,Unit)` entry 순회는 기존
referability/tuple 제한으로 지원하지 않는다. Reference 반환 get/get_mut는 없다.
Struct field는 private이 아니므로 table invariant를 유지하려면 map API를 사용한다.

```xen
use std.hashmap;
#![explc]
fn main() {
    let mut map = std.hashmap.new<Int>();
    map.insert("answer", 42);
    let key = "answer";
    println(match map.get_cloned(&key) { Option.Some(value) => value, _ => 0 });
}
```

`use std.mem;`의 `std.mem.replace<T>(&mut T,T)->T`는 준비한 새 값을 설치하고 이전 owned
값을 반환한다. `Vec.replace(index,value)->T`도 같은 동작이며 길이를 유지한다.
`Vec.swap(left,right)`는 element를 clone/drop 없이 교환한다. Invalid index는 runtime error다.

## 검사

`python3 tests/integration/stdlib_test.py`는 API 계약, binary stdin/append, symlink metadata,
cwd 성공/실패, 여러 directory batch, malformed record와 제한된 fd 아래 반복 cleanup을
검사한다. `make test`에도 포함된다. low-level syscall 번호·stat layout은 Linux x86-64
UAPI header를 기준으로 하며 다른 platform abstraction은 도입하지 않았다.
