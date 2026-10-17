# 첫 프로그램 실행하기

이 장에서는 화면에 한 줄을 출력하고, 만든 프로그램을 직접 실행합니다.

## Xen 준비하기

Linux, Windows x86-64 또는 Apple Silicon macOS용 Xen이 필요합니다. [설치 안내](../compiler-build/ko/installation.md)를 따라 준비하세요. 배포본의 `bin` 디렉터리를 `PATH`에 추가하면 어디서든 `xen` 명령을 쓸 수 있습니다. 이 문서의 명령은 `xen`을 찾을 수 있다는 전제로 작성했습니다.

배포본을 풀어 놓은 디렉터리에서는 `xen` 대신 `./bin/xen`을, 저장소 루트에서는 `compiler/dist/xen`을 사용해도 됩니다. 배포본을 옮길 때는 `bin`과 `stdlib`을 함께 옮기세요.

```sh
xen version
```

## 파일 작성하기

원하는 작업 디렉터리에 `hello.xen`을 만들고 다음 코드를 저장하세요.

```xen
fn main() {
    println("Hello, Xen!");
}
```

`fn main()`은 프로그램의 시작점입니다. 중괄호 안에 실행할 문장을 적습니다. `println`은 값을 출력한 뒤 줄을 바꿉니다. 문자열은 큰따옴표로 감싸고 문장 끝에는 `;`을 붙입니다.

파일을 저장한 디렉터리에서 실행하세요.

```console
$ xen run hello.xen
Hello, Xen!
```

## 검사하고 실행 파일 만들기

```sh
xen check hello.xen
xen build hello.xen -o hello
./hello
```

`check`는 실행하지 않고 코드의 오류를 찾습니다. 오류가 없으면 아무것도 출력하지 않습니다. `build`는 실행 파일을 만듭니다. `./hello`도 `Hello, Xen!`을 출력하며, 이 파일을 실행할 때는 Xen이 필요하지 않습니다.

파일을 찾을 수 없다는 오류가 나오면 현재 디렉터리와 파일 이름을 확인하세요. 실행 파일은 호환되는 OS와 CPU에서 실행해야 합니다. Windows x86-64는 실험적 지원입니다. Windows Server 2022 네이티브 CI는 통과했으며 Windows 데스크톱 실 하드웨어 검증이 추가로 필요합니다. PowerShell에서는 `xen build hello.xen -o hello.exe`와 `.\hello.exe`를 사용합니다. Apple Silicon macOS 15 이상에는 사용자 실기기 검증이 남아 있어 실험적 표기가 붙습니다. macOS 15 네이티브 CI는 실행과 패키지를 검사합니다. Windows ARM64와 Intel macOS는 미지원입니다.

## 바꿔 보기

인사말을 자신의 이름으로 바꾸고 다시 실행해 보세요. 다음 장에서는 같은 값에 이름을 붙이고 계산에 사용합니다.

---

[목차](README.md) · [다음: 변수와 값](language-basics.md) · [English](../en/getting-started.md)
