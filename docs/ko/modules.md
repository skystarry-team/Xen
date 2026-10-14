# 여러 파일로 나누기

프로그램이 커지면 관련된 타입과 함수를 파일별로 나눕니다. 다음 구조로 세 파일을 만드세요. `app.xen`이 있는 디렉터리에서 실행합니다.

```text
project/
  app.xen
  shop/
    model.xen
    view.xen
```

`app.xen`:

```xen
module app;
import shop.model as model;
import shop.view as view;

fn main() {
    let item = model.Item { name: "tea", price: 3 };
    view.show(item);
}
```

`shop/model.xen`:

```xen
module shop.model;

struct Item { name: String, price: Int }
```

`shop/view.xen`:

```xen
module shop.view;
import shop.model as model;

fn show(item: model.Item) {
    println(item.name + ": " + int_to_str(item.price));
}
```

```console
$ xen check app.xen
$ xen run app.xen
tea: 3
```

같은 파일은 [예제의 modules 디렉터리](../../examples/modules/app.xen)에 있습니다. 저장소에서는 `xen run examples/modules/app.xen`으로 실행하세요.

## 가져오기와 이름

`import shop.model;`은 시작 파일의 디렉터리 아래 `shop/model.xen`을 가져옵니다. 각 파일은 파일 경로에 맞는 `module`을 선언해야 합니다. 프로젝트를 가져오는 시작 파일도 `module app;`처럼 선언합니다. 이름이 맞지 않으면 오류가 납니다.

`as model`은 현재 파일에서 쓸 짧은 이름을 정합니다. 별명이 없으면 `shop.model.Item`처럼 전체 이름을 사용하세요. 간접적으로 가져온 파일은 자동으로 사용할 수 없으므로, 직접 사용하는 모듈마다 `import`를 적습니다. 별명은 변수·타입·함수 이름과 겹치지 않게 정하세요.

## 표준 라이브러리

표준 라이브러리는 `use std.string;` 또는 `use std.string as text;`처럼 가져옵니다. 프로젝트 파일에는 `import`, 함께 제공된 `std.*`와 `core.*`에는 `use`를 씁니다. 프로젝트 파일을 `std`나 `core` 이름 아래 두지 마세요. 표준 라이브러리만 사용하는 단일 파일에는 `module`이 필요하지 않습니다.

현재 패키지 관리 파일, 공개·비공개 선언, 모듈 재공개 기능은 없습니다. 서로 가져오는 순환 관계도 피하세요. 공통 타입은 두 파일이 함께 가져올 수 있는 별도 파일로 옮기는 것이 좋습니다.

---

[목차](README.md) · [이전: 없을 수 있는 값과 실패](error-handling.md) · [다음: 파일의 단어 수 세기](tutorial.md) · [English](../en/modules.md)
