# 컴파일러 배포 패키징

`make package`는 기본으로 **Linux x86_64와 AArch64 컴파일러를 모두** 빌드하고 패키징합니다.

```text
dist/xen-<version>-linux-x86_64.tar.gz
dist/xen-<version>-linux-aarch64.tar.gz
```

바이너리 배포본에는 `bin/xen`, 런타임 표준 라이브러리, 학습용 예제, 라이선스,
`VERSION`과 배포용 README가 들어갑니다. `stdlib/`의 `.xen` 파일은 컴파일러의
모듈 로더가 읽는 필수 구성입니다. 두 Linux 플랫폼 프로필을 함께 제공하므로
어느 컴파일러에서도 두 지원 타깃의 프로그램을 생성할 수 있습니다.
컴파일러 소스·빌드 문서·개발 스크립트는 별도 소스 패키지에 포함합니다. macOS는 미지원입니다.

## 크로스 툴체인 설정

네이티브 OCaml과 Dune이 `PATH`에 있어야 합니다. 다른 CPU용 컴파일러를 빌드하려면
버전이 정확히 같은 크로스 OCaml, 대상 C 툴체인·라이브러리와 버전 검사에 사용할
실행 환경이 필요합니다. x86_64에서 준비하는 방법은 [AArch64 소스 빌드 안내](aarch64.md)에 있습니다.

저장소 루트의 `.package-toolchains.json`에 prefix와 runner를 지정합니다.
이 파일은 머신별 설정이며 Git과 소스 패키지에서 제외합니다.
[`scripts/package-toolchains.example.json`](../../../scripts/package-toolchains.example.json)에서
두 아키텍처의 설정 형식을 확인할 수 있습니다.

```json
{
  "aarch64": {
    "prefix": "/absolute/path/to/ocaml-aarch64",
    "runner": ["qemu-aarch64", "-L", "/usr/aarch64-linux-gnu"]
  }
}
```

AArch64 호스트에서는 `x86_64` 항목을 설정합니다. prefix는 실행 가능한
`bin/ocamlc`와 `bin/ocamlopt`가 있는 절대 경로여야 합니다.
네이티브 아키텍처는 해당 설정을 사용하지 않습니다. runner가 비어 있으면 직접 실행하므로
호환 호스트나 커널 binary handler가 필요합니다. 별도 설정이 없으면
`/opt/ocaml-aarch64`와 `/opt/ocaml-x86_64`를 사용합니다.
`PACKAGE_TOOLCHAINS=/path/to/toolchains.json`으로 다른 설정 파일을 선택할 수 있습니다.

빌드 전에 OCaml 버전·OS·CPU를 검사합니다. 툴체인이 없거나 설정이 맞지 않으면 실패하며
요청된 아키텍처를 생략하지 않습니다. Dune은 네이티브 `default`와 크로스
`package_<architecture>` context를 사용합니다. 빌드 중 실행하는 도구는 `host default`에서
만듭니다. `compiler/main.exe`를 직접 요청하므로 `compiler/dist/xen`을 덮어쓰지 않습니다.

## 바이너리 배포 명령

```sh
make package
make package VERSION=0.1.0
make package-build
make package PACKAGE_ARCHS=x86_64
make package PACKAGE_ARCHS=aarch64
```

`package-build`는 아카이브 없이 두 컴파일러를 빌드합니다. `PACKAGE_ARCHS`는 대상 일부를
명시적으로 선택하며 `arm64`는 `aarch64`의 별칭입니다. 바이너리의 ELF 아키텍처와
실행 파일이 보고하는 버전이 요청과 일치해야 합니다. 요청된 모든 아카이브를 완성한 뒤
기존 배포물을 교체합니다.

단일 context나 기존 실행 파일을 패키징할 때는 다음 명령을 사용합니다.

```sh
make package-one
make package-one DUNE_WORKSPACE=scripts/dune-workspace.arm64 \
  PACKAGE_CONTEXT=arm64 PACKAGE_ARCH=aarch64 \
  PACKAGE_RUNNER='["qemu-aarch64","-L","/usr/aarch64-linux-gnu"]'
make package-one PACKAGE_BINARY=/path/to/xen
```

명시적 context를 사용하기 전에 workspace의 두 prefix를 수정해야 합니다.
`PACKAGE_BINARY`는 Dune 빌드를 생략합니다. 호환성을 위해 `make package`에 비어 있지 않은
`PACKAGE_BINARY`·`PACKAGE_CONTEXT`·`DUNE_WORKSPACE`·`PACKAGE_ARCH`를 지정해도 단일 모드를
선택합니다. 단일 모드의 `PACKAGE_NAME`과 `PACKAGE`는 이름·출력 파일을 지정합니다.
`DIST_DIR`는 두 모드 모두의 아카이브 출력 디렉터리입니다.

## 소스 배포

```sh
make source-package VERSION=0.1.0
```

`xen-<version>-source.tar.gz`에는 컴파일러·stdlib 소스, 빌드 파일, 스크립트, 테스트,
문서, 예제와 라이선스를 포함합니다. 컴파일러를 빌드하지 않으며 Git 이력·머신별
툴체인·생성된 빌드 결과는 제외합니다. 컴파일러 빌드 안내도 이 소스 패키지에 포함합니다.
