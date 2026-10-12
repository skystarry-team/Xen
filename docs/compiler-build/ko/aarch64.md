# AArch64 OCaml 크로스 툴체인

이 절차는 **Linux x86_64에서 실행되며 AArch64 코드를 생성하는 OCaml**을 빌드합니다.
이를 사용해 AArch64에서 실행할 Xen 컴파일러를 만듭니다. AArch64 머신에서는
[네이티브 OCaml과 일반 Xen 빌드](build.md)를 사용합니다.
x86_64 Xen 컴파일러로 AArch64 Xen 프로그램을 생성하는 데는 크로스 OCaml이 필요하지 않습니다.

OCaml 5.5의 크로스 빌드 지원은 실험적이며 네이티브 OCaml과 버전이 정확히 같아야 합니다.
아래 명령은 5.5.0을 사용하며 [공식 크로스 빌드 절차](https://github.com/ocaml/ocaml/blob/5.5.0/INSTALL.adoc)를 따릅니다.

## 호스트 도구 준비

[네이티브 빌드 안내](build.md)에 따라 OCaml 5.5.0과 Dune 3.18 이상을 준비합니다.
일반 `PATH`에는 네이티브 OCaml을 유지합니다.
Ubuntu/Debian에서는 AArch64 C 툴체인·대상 libc·QEMU를 설치합니다.

```sh
sudo apt install build-essential gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
  libc6-dev-arm64-cross qemu-user curl
ocamlc -version
ocamlopt -version
aarch64-linux-gnu-gcc --version
```

이 C 도구는 OCaml을 빌드하고 Xen 컴파일러 실행 파일을 링크합니다.
Xen 프로그램의 코드 생성에는 C 컴파일러나 linker가 필요하지 않습니다.

## 소스에서 크로스 OCaml 빌드

네이티브 OCaml을 빌드한 디렉터리와 별개의 새 소스 디렉터리를 사용합니다.
설치 prefix는 사용자 소유의 영구 경로로 지정합니다.

```sh
XEN_OCAML_SOURCE_ROOT="$HOME/.local/src/xen-ocaml-5.5.0"
XEN_OCAML_AARCH64_PREFIX="$HOME/.local/opt/ocaml-aarch64-5.5.0"
mkdir -p "$XEN_OCAML_SOURCE_ROOT/aarch64"
curl --fail --location https://github.com/ocaml/ocaml/archive/refs/tags/5.5.0.tar.gz \
  --output "$XEN_OCAML_SOURCE_ROOT/ocaml-5.5.0.tar.gz"
tar -xzf "$XEN_OCAML_SOURCE_ROOT/ocaml-5.5.0.tar.gz" \
  -C "$XEN_OCAML_SOURCE_ROOT/aarch64" --strip-components=1
cd "$XEN_OCAML_SOURCE_ROOT/aarch64"
test "$(ocamlc -version)" = "$(head -n 1 VERSION)"
./configure --prefix="$XEN_OCAML_AARCH64_PREFIX" --target=aarch64-linux-gnu \
  --without-zstd CC=aarch64-linux-gnu-gcc CC_FOR_BUILD=gcc
make crossopt -j2
make installcross
```

크로스 prefix를 일반 `PATH`에 추가하지 않습니다. 빌드 중 실행하는 도구는 네이티브
OCaml로 만들어야 하므로 크로스 컴파일러는 절대 경로나 전용 Dune context에서 선택합니다.

설치된 설정을 확인합니다.

```sh
test "$("$XEN_OCAML_AARCH64_PREFIX/bin/ocamlc" -config-var architecture)" = arm64
test "$("$XEN_OCAML_AARCH64_PREFIX/bin/ocamlopt" -config-var system)" = linux
test "$("$XEN_OCAML_AARCH64_PREFIX/bin/ocamlopt" -version)" = "$(ocamlopt -version)"
printf '%s\n' "$XEN_OCAML_AARCH64_PREFIX"
```

`architecture: arm64`는 생성 코드의 CPU를 뜻합니다. 크로스 OCaml 실행 파일 자체는
여전히 x86_64 호스트에서 실행됩니다.

## AArch64 Xen 컴파일러 빌드

Xen 저장소 루트로 돌아와 `.package-toolchains.json`을 작성합니다.
prefix에는 앞에서 출력한 실제 절대 경로를 넣습니다.

```json
{
  "aarch64": {
    "prefix": "/absolute/path/to/ocaml-aarch64-5.5.0",
    "runner": ["qemu-aarch64", "-L", "/usr/aarch64-linux-gnu"]
  }
}
```

JSON은 `$HOME`·환경 변수·`~`를 확장하지 않습니다. 위 QEMU 경로는
`libc6-arm64-cross`의 libc를 사용합니다. 다른 툴체인의 대상 라이브러리를 사용하면
그에 맞는 sysroot를 지정해야 합니다.

```sh
make package-build
aarch64-linux-gnu-readelf -h _build/package_aarch64/compiler/main.exe
qemu-aarch64 -L /usr/aarch64-linux-gnu _build/package_aarch64/compiler/main.exe version
make package
```

ELF 헤더의 CPU는 AArch64이며 machine 번호는 183입니다. 두 Make 명령은 기본으로
x86_64와 AArch64를 모두 요청합니다. `PACKAGE_ARCHS=aarch64`로 AArch64만 선택할 수 있습니다.
크로스 결과는 `_build/package_aarch64/compiler/main.exe`이며 `compiler/dist/xen`을 덮어쓰지 않습니다.

소스 로딩과 생성 프로그램의 실행을 확인합니다.

```sh
qemu-aarch64 -L /usr/aarch64-linux-gnu _build/package_aarch64/compiler/main.exe \
  check examples/arm64_core.xen
qemu-aarch64 -L /usr/aarch64-linux-gnu _build/package_aarch64/compiler/main.exe \
  build examples/arm64_core.xen --jit=off -o app
qemu-aarch64 ./app
```

컴파일러 실행 파일에는 대상 libc가 필요하지만 생성된 Xen 프로그램은 정적 실행 파일이므로
QEMU의 `-L`이 필요하지 않습니다. QEMU-user는 `run`·`test`가 만드는 자식 프로세스에
binary handler를 제공하지 않습니다. 해당 명령은 네이티브 AArch64 호스트나 별도로
설정된 커널 handler가 있어야 실행할 수 있습니다.

`make package` 이후 추출·재배치한 컴파일러를 호스트 테스트로 확인할 수 있습니다.

```sh
XEN_BIN="$PWD/_build/package_aarch64/compiler/main.exe" \
  XEN_HOST_ARCHIVE="$PWD/dist/xen-$(cat VERSION)-linux-aarch64.tar.gz" \
  XEN_HOST_RUNNER='["/usr/bin/qemu-aarch64","-L","/usr/aarch64-linux-gnu"]' \
  python3 tests/integration/host_test.py
```

이 테스트에서 크로스 컴파일러를 QEMU로 실행하면 네이티브 `run`·`test` 검사는 생략합니다.
생성된 AArch64 프로그램은 별도로 실행합니다. 상세 내용은
[호스트 테스트 안내](../../../tests/README.md)에 있습니다.

## 선택적 Dune workspace

[`scripts/dune-workspace.arm64`](../../../scripts/dune-workspace.arm64)는
`host default`인 `arm64` context를 제공합니다. 두 `/opt/ocaml-aarch64` 경로를
설치한 prefix로 바꾸고 설정을 확인한 뒤 실행합니다.

```sh
dune build --workspace=scripts/dune-workspace.arm64 _build/arm64/compiler/main.exe
aarch64-linux-gnu-readelf -h _build/arm64/compiler/main.exe
qemu-aarch64 -L /usr/aarch64-linux-gnu _build/arm64/compiler/main.exe version
```

이 context의 결과는 `_build/arm64/`이며 자동 패키징의 `_build/package_aarch64/`와 다릅니다.
workspace prefix가 잘못되면 `PATH`의 네이티브 OCaml로 대체될 수 있습니다.
`make package-build`는 prefix를 먼저 검사합니다.
[Dune context 문서](https://dune.readthedocs.io/en/stable/reference/dune-workspace/context.html)와
[패키징 안내](packaging.md)에서 단일 context 패키징과 설정 옵션을 확인할 수 있습니다.
