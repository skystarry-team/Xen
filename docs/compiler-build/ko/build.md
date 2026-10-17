# Xen 컴파일러 빌드

Xen 컴파일러는 OCaml 실행 파일입니다. 컴파일러가 실행되는 CPU와 Xen 프로그램의
출력 타깃은 별개입니다.

배포된 컴파일러의 `.deb`·tar.gz 설치는 [설치 안내](installation.md)를 참고하세요.
이 문서는 컴파일러를 소스에서 빌드하는 절차를 설명합니다.

| 빌드 환경 | 필요한 OCaml |
| --- | --- |
| Linux x86_64에서 x86_64 컴파일러 빌드 | x86_64 네이티브 OCaml |
| Linux AArch64에서 AArch64 컴파일러 빌드 | AArch64 네이티브 OCaml |
| Windows x86_64에서 `xen.exe` 빌드 | Windows x64 네이티브 OCaml (MinGW) |
| Apple Silicon macOS에서 `xen` 빌드 | macOS arm64 네이티브 OCaml |
| Linux x86_64에서 AArch64 컴파일러 빌드 | x86_64 네이티브 OCaml과 AArch64 크로스 OCaml |

크로스 OCaml은 빌드 호스트에서 실행되며 다른 CPU의 코드를 생성합니다.
AArch64에서 실행되는 네이티브 OCaml을 x86_64에 설치하는 것과는 다릅니다.
크로스 툴체인 준비는 [AArch64 안내](aarch64.md)를 참고하세요.

## 요구 사항

- `PATH`에서 실행할 수 있는 네이티브 `ocamlc`와 `ocamlopt`. 기준 버전은 OCaml 5.5.0입니다.
- Dune 3.18 이상. 기준 빌드 버전은 Dune 3.24.2입니다.
- Linux 저장소 명령에 사용하는 GNU Make. Windows에서는 Dune을 직접 실행합니다.
- 패키징·테스트 스크립트에 사용하는 Python 3.10 이상. `.deb` 생성에는 `dpkg-dev`도 필요합니다.

크로스 OCaml과 네이티브 OCaml의 버전은 정확히 같아야 합니다. 컴파일러 테스트에는
Python 3.10 이상과 binutils도 필요합니다. 상세 내용은 [테스트 안내](../../../tests/README.md)에 있습니다.
Linux용 Xen 프로그램은 정적 런타임을 사용합니다. macOS용 Mach-O는 dyld와 libSystem을
로드합니다. 생성된 프로그램 실행에는 C 컴파일러·assembler·linker가 필요하지 않습니다.
OCaml 자체를 소스에서 빌드할 때는 네이티브 C 툴체인이 필요합니다.

## 네이티브 OCaml 설치

opam이 초기화된 환경에서는 네이티브 switch를 만들고 Dune을 설치할 수 있습니다.

```sh
opam switch create xen-native 5.5.0
eval "$(opam env --switch=xen-native)"
opam install 'dune>=3.18'
```

공식 소스에서 직접 설치하는 경우 Ubuntu/Debian의 네이티브 빌드 도구를 준비합니다.

```sh
sudo apt install build-essential pkg-config libzstd-dev curl
```

소스는 새 디렉터리에 풀고 사용자 소유의 영구 경로에 설치합니다.

```sh
XEN_OCAML_SOURCE_ROOT="$HOME/.local/src/xen-ocaml-5.5.0"
XEN_OCAML_NATIVE_PREFIX="$HOME/.local/opt/ocaml-native-5.5.0"
mkdir -p "$XEN_OCAML_SOURCE_ROOT/native"
curl --fail --location https://github.com/ocaml/ocaml/archive/refs/tags/5.5.0.tar.gz \
  --output "$XEN_OCAML_SOURCE_ROOT/ocaml-5.5.0.tar.gz"
tar -xzf "$XEN_OCAML_SOURCE_ROOT/ocaml-5.5.0.tar.gz" \
  -C "$XEN_OCAML_SOURCE_ROOT/native" --strip-components=1
cd "$XEN_OCAML_SOURCE_ROOT/native"
./configure --prefix="$XEN_OCAML_NATIVE_PREFIX"
make -j2
make install
export PATH="$XEN_OCAML_NATIVE_PREFIX/bin:$PATH"
```

Dune은 [공식 설치 안내](https://github.com/ocaml/dune#installation)에 따라 별도로 설치합니다.
Xen을 빌드하기 전에 `PATH`가 선택하는 도구를 확인합니다.

```sh
ocamlc -version
ocamlopt -version
dune --version
```

네이티브 OCaml 빌드 절차는 [공식 설치 문서](https://github.com/ocaml/ocaml/blob/5.5.0/INSTALL.adoc)를 따릅니다.
다른 버전을 선택하면 해당 버전의 소스를 사용해야 합니다.

## Xen 빌드

Xen 저장소 루트에서 실행합니다.

```sh
make build
compiler/dist/xen version
compiler/dist/xen check examples/demo.xen
compiler/dist/xen run examples/demo.xen
```

`make build`는 `dune build @release`를 실행합니다. Dune의 빌드 결과는
`_build/default/compiler/main.exe`이며 release 실행 파일은 `compiler/dist/xen`에 생성됩니다.
Linux AArch64의 네이티브 빌드도 크로스 workspace 없이 같은 명령을 사용합니다.
CLI 기본 타깃은 컴파일러의 OCaml 빌드 아키텍처를 따릅니다.
두 Linux 타깃은 스코프 AOT 최적화를 사용합니다.

## Windows x86_64 (실험적 지원)

OCaml 5.5.0과 Dune 3.24.2를 갖춘 Windows x64 네이티브 opam switch를 사용합니다.
`ocamlc -config`에 `architecture: amd64`, `system: mingw64` 또는 `win64`,
`os_type: Win32`가 나와야 합니다. Cygwin 타깃 OCaml은 이에 해당하지 않습니다.
저장소 루트에서 PowerShell로 실행합니다.

```powershell
opam exec -- ocamlc -config
opam install dune.3.24.2
opam exec -- dune build '@release'
.\compiler\dist\xen.exe version
.\compiler\dist\xen.exe run examples\demo.xen
opam exec -- python scripts/test.py --suite windows
opam exec -- python -m packaging.cli --platform windows --formats zip
```

PowerShell의 `'@release'`는 따옴표로 감쌉니다. 배포 실행 파일은
`compiler/dist/xen.exe`이며, 기본 생성 타깃은 `x86_64-windows`, 출력은 `a.exe`입니다.
Windows Server 2022 네이티브 CI에서 컴파일러·PE/로더·런타임·표준 라이브러리 검사를
통과했습니다. Windows 데스크톱 실 하드웨어 검증은 추가로 필요합니다.
Windows ARM64·원시 syscall·`extern_call`은 미지원입니다.
Python은 패키징과 검증에 필요하며, 설치한 컴파일러를 사용할 때는 필요하지 않습니다.

## Apple Silicon macOS 15 이상 (실험적: 실기기 검증 전)

arm64 네이티브 OCaml 5.5.0 switch와 Dune 3.24.2를 사용합니다. `ocamlc -config`에
`architecture: arm64`, `system: macosx`가 나와야 합니다. 저장소 루트에서 실행합니다.

```sh
opam install dune.3.24.2
opam exec -- dune build @release
opam exec -- python3 scripts/test.py --suite macos
```

이 검증은 생성된 프로그램 실행과 재배치한 macOS tar.gz를 확인합니다.
macOS 15 네이티브 CI가 통과했으며 Intel macOS는 미지원입니다.

## 컴파일러 버전

기본 버전은 `VERSION` 파일에서 읽습니다. Make에 버전을 지정하면 실행 파일에 포함됩니다.

```sh
make build VERSION=v0.1.0-demo.5
compiler/dist/xen version
```

직접 실행하는 Dune 빌드는 `VERSION` 또는 `XEN_BUILD_VERSION`을 사용합니다.
바이너리·소스 패키지의 버전 설정은 [패키징 안내](packaging.md)를 참고하세요.

## 테스트와 패키징

`make test`와 개별 실행 방법은 [테스트 안내](../../../tests/README.md)에 있습니다.
AArch64 호스트 검증은 `python3 scripts/test.py --suite host`와 `--suite arm64`를 사용합니다.
전체 테스트에는 x86_64 실행·스코프 AOT 검사도 포함됩니다.
네이티브 빌드를 패키징할 때는 현재 호스트 CPU를 선택합니다.

```sh
make package-deb PACKAGE_ARCHS=x86_64
make release-package PACKAGE_ARCHS=x86_64
```

AArch64 호스트에서는 `PACKAGE_ARCHS=aarch64`를 사용합니다. 첫 명령은 `.deb`만,
두 번째는 `.deb`와 tar.gz를 만듭니다. CPU를 지정하지 않으면 `make package`,
`make package-deb`, `make release-package`가 두 CPU를 모두 요청하므로 다른 CPU의
크로스 툴체인이 필요합니다. 데비안 크로스 패키징에는 대상 라이브러리 메타데이터도
필요합니다. 디렉터리 구조·버전 변환·glibc 기준·GitHub 릴리스 절차는
[패키징 안내](packaging.md)를 참고하세요.
