# 저수준 `bb` (일명 블랙바스)

`bb`는 raw memory를 허용하는 lexical capability다. IR basic block이나 optimization
mode가 아니다. `Ptr<T>` binding·시그니처·전달, raw pointer builtin, syscall은
lexical 영역에 `bb`가 있을 때만 사용할 수 있다. callee의 `bb`는 값 전용 호출의
caller로 전파되지 않는다.

```xen
#global[explc]

fn main() {
    let value = 7;
    let reference = &value;
    #scope[bb] {
        let pointer = raw_alloc_int(1);
        raw_store_int(pointer, 0, 42);
        println(raw_load_int(pointer, 0));
        raw_free_int(pointer);
    }
    println(*reference);
}
```

파일 첫 선언에 `#global[...]`을 한 번 둘 수 있고, 함수의 `#![...]` 및 block의
`#scope[...] { ... }`로 capability를 추가한다. 함수 몸체의 유효 capability는 그
파일의 global, 함수, enclosing scope의 합집합이며 `explc`, `jit`, `bb` 순서로
정규화된다. import한 module의 global/function capability는 caller에 합쳐지지 않는다.
`#scope[jit]`는 별도의 실험적 [scalar runtime compiler](jit.md)다. Global·function jit는 예약 상태다.

`#scope[bb]`는 일반 lexical block에 capability만 더한다. scope의 local과 capability는 밖으로 유출되지 않지만 바깥 owned value의 move/재초기화 상태는 이후 흐름에 반영된다.

| 호출 | 결과/동작 |
| --- | --- |
| `raw_alloc_int(count)` | 0으로 초기화된 Int `count`개를 anonymous `mmap`으로 할당 |
| `raw_load_int(pointer, offset)` | bounds check 뒤 Int 읽기 |
| `raw_store_int(pointer, offset, value)` | bounds check 뒤 Int 쓰기 |
| `raw_free_int(pointer)` | `munmap`으로 해제 (`count == 0`이면 no-op) |

기존 Int API는 다음 typed API의 `I64` 호환 이름이다.

| 호출 | 결과/동작 |
| --- | --- |
| `raw_alloc<T>(count)` | 0으로 초기화된 `T` element를 할당 (`T` 명시는 필수) |
| `raw_load(pointer, index)` / `raw_load<T>(...)` | bounds check 뒤 `T` 값 복사 |
| `raw_store(pointer, index, value)` / `raw_store<T>(...)` | bounds check 뒤 `T` 값 복사 |
| `raw_free(pointer)` / `raw_free<T>(...)` | descriptor의 전체 mapping 해제 |
| `ptr_addr(pointer)` / `ptr_addr<T>(...)` | address word만 `I64`로 추출 |
| `syscall0(number)` … `syscall6(number, a1, …, a6)` | raw Linux syscall 결과를 `I64`로 반환 |

`T`는 모든 숫자 scalar, `Bool`, 또는 이 타입들만 재귀적으로 포함하는 named POD
struct여야 한다. concrete generic POD struct도 허용한다. String, Vec, Slice, File,
reference, Ptr, tuple, enum, Unit 및 drop/move가 필요한 struct는 거부한다. load/store/free와
`ptr_addr`는 pointer에서 `T`를 추론하며 명시한 타입은 pointer element와 정확히 같아야 한다.
element stride는 `align_up(size, alignment)`이고 struct padding도 그대로 복사한다.

`Ptr<T>`는 address와 element count를 함께 가진 16-byte copyable descriptor이며 compiler는
clone, move, drop, automatic `free`를 삽입하지 않는다. descriptor 복사 뒤 double-free,
free 뒤 접근, memory leak은 `bb` 코드 작성자의 책임이다. 0개 allocation은 null descriptor다.
pointer equality/arithmetic, address에서 pointer로의 역변환과 임의 address 역참조는 지원하지
않는다. `ptr_addr`는 syscall에 넘기기 위한 one-way escape hatch다.

syscall 인자와 번호·반환은 모두 I64이고 왼쪽부터 한 번씩 평가한다. Linux x86-64의
`rax/rdi/rsi/rdx/r10/r8/r9` 순서를 사용하며 kernel의 음수 errno를 변환하지 않는다.
현재 target은 Linux x86-64 static non-PIE 하나다. errno의 Result 변환과 OS wrapper는
후속 Xen 표준 라이브러리 범위다.

## Module 안에 raw memory 숨기기

```xen
module raw_math;
#global[bb]

fn answer() -> Int {
    let pointer = raw_alloc_int(1);
    raw_store_int(pointer, 0, 42);
    let value = raw_load_int(pointer, 0);
    raw_free_int(pointer);
    return value;
}
```

```xen
module app;
import raw_math;

fn main() {
    println(raw_math.answer()); // app에는 bb가 필요 없다
}
```

pointer가 wrapper 안에서 해제되고 일반 `Int`만 반환되므로 capability가 module 밖으로
노출되지 않는다. 공개 시그니처가 `Ptr<Int>`를 받거나 반환하면 이를 수신·보관·전달하는
caller에도 `bb`가 필요하다.
