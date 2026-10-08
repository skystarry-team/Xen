# File API

## Recoverable one-shot API

새 코드는 handle이 필요하지 않은 경우 Xen 소스 표준 라이브러리를 사용할 수 있다.

```xen
use std.fs;
use std.io;

let loaded = std.fs.read("input.bin");
let saved = std.fs.write("output.bin", "bytes");
let copied = std.fs.copy("input.bin", "copy.bin");
```

- `read(path) -> Result<String, std.io.IoError>`
- `write(path, contents) -> Result<Int, std.io.IoError>`
- `copy(source, destination) -> Result<Int, std.io.IoError>`
- `write_stdout(text)`와 `write_stderr(text)`는 전체 byte sequence를 쓰고 byte 수를
  `Result<Int, IoError>`로 반환한다.

`IoError` variant는 `InvalidPath`, `Open(Int)`, `Read(Int)`, `Write(Int)`,
`WriteZero`, `Close(Int)`다. errno payload는 양수 Linux errno이며
`std.io.describe_error`로 사람이 읽을 문자열을 만들 수 있다. embedded NUL path는
syscall 전에 `InvalidPath`가 된다. read/write/open은 `EINTR`을 재시도하고 partial
write를 끝까지 진행한다. 본 작업 오류가 close 오류보다 우선하며, 작업 성공 뒤
close만 실패하면 `Close(errno)`다.

`std.fs.write`는 기존 파일을 truncate하며 새 파일은 `0644`와 process umask를 쓴다.
`copy`는 현재 source 전체를 메모리에 읽은 뒤 쓴다. 모든 API는 blocking Linux x86-64
I/O이고 String byte를 UTF-8 검증 없이 보존한다.

## Owned `File` compatibility API

`File`은 Linux x86-64의 blocking byte I/O를 제공하는 8바이트 move-only owned
resource다. raw file descriptor는 언어에 노출되지 않는다.

## 열기

```xen
let mut input = open_read("input.bin");
let mut output = open_write("output.bin");
```

- `open_read`는 기존 파일을 읽기 전용으로 연다.
- `open_write`는 `O_WRONLY | O_CREAT | O_TRUNC`를 사용한다.
- 새 파일의 mode는 `0644`이며 process umask를 존중한다.
- path는 String이다. embedded NUL은 runtime error다.

## 읽기

```xen
let mut input = open_read("message.txt");
let contents = input.read();
println(contents);
```

`read()`는 현재 offset부터 EOF까지 모든 byte를 읽어 String으로 반환한다. 호출 후
offset은 EOF에 있으므로 파일이 바뀌지 않았다면 다음 `read()`는 빈 String을 반환한다.
buffer는 overflow를 검사하며 `mmap`으로 성장한다.

## 쓰기

```xen
let mut output = open_write("message.txt");
output.write("hello");
output.write(" world");
```

`write()`는 현재 offset부터 String 전체를 기록한다. partial write와 `EINTR`을
runtime에서 처리한다. append mode와 seek는 아직 지원하지 않는다.

## 닫기와 상태

```xen
let mut file = open_read("message.txt");
println(file.is_open()); // true
file.close();
file.close();          // no-op
println(file.is_open()); // false
```

`close()`는 반복 호출해도 안전하다. scope 종료 시 열린 File은 자동으로 닫힌다.
닫힌 File의 `read()` 또는 `write()`는 runtime error다.

`read`, `write`, `close`는 mutable File local 또는 `&mut File`이 필요하다.
`is_open`은 File, `&File`, `&mut File`에서 호출할 수 있다.

## 전달과 반환

```xen
fn relay(file: File) -> File {
    return file;
}

fn main() {
    let input = open_read("message.txt");
    let mut moved = relay(input);
    println(moved.read());
}
```

by-value 전달 후 원본은 moved 상태다. `File`은 print, equality, `len`, Vec element,
raw integer 변환을 지원하지 않는다.

## 오류

open/read/write/close 실패와 닫힌 handle 사용은 다음 형식으로 stderr에 기록되고
status 1로 종료된다.

```text
source.xen:3:5: xen runtime error: file read failed
```

복구 가능한 새 코드에는 위 `std.fs` API를 사용한다. 이 절의 legacy `File` builtin은
호환성을 위해 runtime-error 동작을 유지한다.
