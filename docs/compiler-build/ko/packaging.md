# 컴파일러 배포 패키징

`make package`는 기본으로 **Linux x86_64와 AArch64 컴파일러를 모두** 빌드하고 패키징합니다.

```text
dist/xen-<version>-linux-x86_64.tar.gz
dist/xen-<version>-linux-aarch64.tar.gz
```

`make package-deb`는 `xen-lang_<debian-version>_amd64.deb`와
`xen-lang_<debian-version>_arm64.deb`를 만듭니다. `make release-package`는 두 형식을
함께 만듭니다. `make package`나 `make package-one`에 `PACKAGE_FORMATS="tar.gz deb"`를
지정해도 됩니다. 기존 Make 선택 옵션도 유지됩니다.

| 명령 | 생성 형식 | 기본 컴파일러 CPU |
| --- | --- | --- |
| `make package` | tar.gz | x86_64와 aarch64 |
| `make package-deb` | .deb | x86_64와 aarch64 |
| `make release-package` | tar.gz와 .deb | x86_64와 aarch64 |
| `make source-package` | 소스 tar.gz | 컴파일러 빌드 없음 |

내려받은 배포물의 사용 방법은 [설치 안내](installation.md)에 있습니다.

배포 코드는 [`packaging/`](../../../packaging/README.md)의 `archive/`, `debian/`,
`windows/`, `toolchains/`, `github/`로 분리합니다. 상위 모듈이 공통 검증과 빌드를 담당하며,
`scripts/`에는 일반 테스트 실행기를 둡니다.

바이너리 tar.gz에는 `bin/xen`, 런타임 표준 라이브러리, 학습용 예제, 라이선스,
`VERSION`과 배포용 README가 들어갑니다. `stdlib/`의 `.xen` 파일은 컴파일러의
모듈 로더가 읽는 필수 구성입니다. 세 플랫폼 프로필을 함께 제공하므로
각 컴파일러에서 Linux x86_64·AArch64와 Windows x86_64 프로그램을 생성할 수 있습니다.
컴파일러 소스·빌드 문서·개발 스크립트는 별도 소스 패키지에 포함합니다. macOS는 미지원입니다.

## Windows 포터블 ZIP (실험적 지원)

Windows x64 네이티브 OCaml switch를 준비하고 저장소 루트에서 PowerShell로 실행합니다.

```powershell
opam exec -- dune build '@release'
opam exec -- python -m packaging.cli --platform windows --architecture x86_64 --formats zip
$version = (Get-Content VERSION -Raw).Trim()
python -m packaging.windows.smoke "dist/xen-$version-windows-x86_64.zip" --version $version
```

`dist/xen-<version>-windows-x86_64.zip`에 `bin/xen.exe`, 모든 표준 라이브러리
프로필, 예제와 라이선스를 넣습니다. Make는 필요하지 않습니다. AMD64 PE32+ 형식,
실행 파일의 내장 버전과 검토된 시스템 DLL import 목록을 검사하며, 추가 런타임 DLL이나
지연 import가 있으면 패키징을 중단합니다. 임시 ZIP 생성을 마친 뒤에만 기존 출력 파일을 교체합니다.

검증 스크립트는 실제 ZIP을 추출하여 공백·유니코드가 포함된 경로로 옮기고 저장소 밖에서
version/check/build/run/test를 실행합니다. PATH에는 설치한 `bin`과 Windows System32만
남깁니다. 생성된 PE 실행, stdlib 파일 입출력, 두 Linux 타깃 생성과 번들 stdlib 누락 시
실패도 확인합니다. 이는 CI의 PATH 격리 검사이며 깨끗한 Windows 설치 검증은 아닙니다.
컴파일러·로더·표준 라이브러리는 Windows Server 2022 네이티브 CI를 통과했으며,
새 ZIP 검증도 릴리스 전에 통과해야 합니다. Windows 데스크톱 실 하드웨어 검증은
추가로 필요합니다. Windows ARM64는 미지원입니다.

## 크로스 툴체인 설정

네이티브 OCaml과 Dune이 `PATH`에 있어야 합니다. 다른 CPU용 컴파일러를 빌드하려면
버전이 정확히 같은 크로스 OCaml, 대상 C 툴체인·라이브러리와 버전 검사에 사용할
실행 환경이 필요합니다. x86_64에서 준비하는 방법은 [AArch64 소스 빌드 안내](aarch64.md)에 있습니다.

저장소 루트의 `.package-toolchains.json`에 prefix와 runner를 지정합니다.
이 파일은 머신별 설정이며 Git과 소스 패키지에서 제외합니다.
[`packaging/toolchains/example.json`](../../../packaging/toolchains/example.json)에서
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
make package VERSION=0.1.0-demo.3
make package-build
make package PACKAGE_ARCHS=x86_64
make package PACKAGE_ARCHS=aarch64
```

`package-build`는 패키징 없이 두 컴파일러를 빌드합니다. `PACKAGE_ARCHS`는 대상 일부를
명시적으로 선택하며 `arm64`는 `aarch64`의 별칭입니다. 바이너리의 ELF 아키텍처와
실행 파일이 보고하는 버전이 요청과 일치해야 합니다. 요청된 모든 형식의 배포물을 완성한 뒤
기존 배포물을 교체합니다.

단일 context나 기존 실행 파일을 패키징할 때는 다음 명령을 사용합니다.

```sh
make package-one
make package-one DUNE_WORKSPACE=packaging/toolchains/dune-workspace.arm64 \
  PACKAGE_CONTEXT=arm64 PACKAGE_ARCH=aarch64 \
  PACKAGE_RUNNER='["qemu-aarch64","-L","/usr/aarch64-linux-gnu"]'
make package-one PACKAGE_BINARY=/path/to/xen
```

명시적 context를 사용하기 전에 workspace의 두 prefix를 수정해야 합니다.
`PACKAGE_BINARY`는 Dune 빌드를 생략합니다. 호환성을 위해 `make package`에 비어 있지 않은
`PACKAGE_BINARY`·`PACKAGE_CONTEXT`·`DUNE_WORKSPACE`·`PACKAGE_ARCH`를 지정해도 단일 모드를
선택합니다. 형식 하나를 선택한 단일 모드에서 `PACKAGE_NAME`과 `PACKAGE`로 이름·출력
파일을 지정합니다. 데비안의 `PACKAGE_NAME`은 출력 파일 이름만 바꾸며 설치되는
패키지 이름은 `xen-lang`입니다. `DIST_DIR`는 두 모드 모두의 배포물 출력 디렉터리입니다.

## 데비안 패키지

`sudo apt install dpkg-dev`로 패키징 도구를 설치합니다. 네이티브 빌드에서는
`PACKAGE_ARCHS=x86_64` 또는 `PACKAGE_ARCHS=aarch64`로 현재 CPU를 선택합니다.
크로스 패키징에는 OCaml·버전 검사용 runner 외에 대상 라이브러리와 해당 데비안
패키지 메타데이터도 필요합니다. amd64 빌더에서 arm64용 apt 소스를 준비한 뒤
`sudo dpkg --add-architecture arm64`, `sudo apt update`,
`sudo apt install libc6:arm64`를 실행하는 방식입니다.
`dpkg-shlibdeps`가 대상 의존성을 해결하지 못하면 패키징을 중단합니다.

패키지 이름은 `xen-lang`이며 `/usr/bin/xen`, `/usr/lib/xen`의 런타임 모듈,
`/usr/share/doc/xen-lang`의 예제·라이선스를 설치합니다. 두 Linux 타깃 프로필을
함께 포함합니다. 환경변수나 설치 후처리 스크립트 없이 동작하며 일반 사용자로
빌드해도 패키지 내부 소유권은 root입니다. 최소 OS 이미지의 dpkg 설정은 문서를
설치 대상에서 제외할 수 있습니다.

다음 amd64 예시는 `dist/`에 해당 CPU의 패키지 하나만 있는 경우입니다.
arm64에서는 `_arm64.deb`를 사용합니다. CPU 선택과 체크섬 검증은
[설치 안내](installation.md)를 참고하세요.

```sh
sudo apt install ./dist/xen-lang_*_amd64.deb
xen version
xen run hello.xen
sudo apt remove xen-lang
```

데비안 버전은 숫자로 시작해야 합니다. 접미사 구분자 `_`와 `-`를 `~`로 바꾸고
패키징 리비전 `-1`을 붙입니다. `0.1.0-demo.3`는 `0.1.0~demo.3-1`이 되어
정식 버전 `0.1.0-1`보다 앞에 정렬됩니다. 기존 `0.1.0_1-demo` 형식은
`0.1.0~1~demo-1`로 변환합니다. 컴파일러 출력과 번들 `VERSION`은 원본을
유지합니다. 라이브러리 의존성은 실제 ELF에서 `dpkg-shlibdeps`로 산출하므로,
최신 OS에서 다시 빌드하면 필요한 최소 glibc 버전도 올라갈 수 있습니다.
[데비안 버전 규칙](https://www.debian.org/doc/debian-policy/ch-controlfields.html#version)과
[dpkg-shlibdeps](https://manpages.debian.org/stable/dpkg-dev/dpkg-shlibdeps.1.en.html)를 참고하세요.

## GitHub 릴리스

[릴리스 워크플로](../../../.github/workflows/release.yml)는 Ubuntu 22.04의 amd64·arm64
러너와 Windows Server 2022 x86_64 러너에서 OCaml 5.5.0과 Dune 3.24.2로 각각 네이티브 빌드합니다.
OCaml 런타임도 이 환경에서 빌드해 시스템 라이브러리 기준을 맞춥니다.
Linux 패키지는 각 CPU에서 **Debian 12/13, Ubuntu 22.04/24.04/26.04**의 깨끗한 컨테이너에 설치하여
stdlib 탐색과 check/build/run/test 및 제거 검사를 통과해야 합니다.
다른 기능의 ARM 실기기 검증은 기존 실험적 지원 범위를 따르며,
파생 배포판은 개별 인증 대상에 포함하지 않습니다.

1. `VERSION`을 설정하고 변경 사항을 커밋한 뒤 정확히 일치하는 `v<VERSION>` 태그를 push합니다.
2. 두 Linux CPU의 tar.gz·deb 빌드와 설치 검사를 실행합니다. Windows 작업은 ZIP을 생성·재배치하고 격리한 PATH에서 실행을 검사합니다.
3. 바이너리 tar.gz 2개, deb 2개, Windows ZIP 1개, 소스 tar.gz 1개가 정확히 있는지 검사하고 `SHA256SUMS`를 만듭니다.
4. 태그 push일 때만 GitHub 릴리스를 만듭니다. 초안 생성 후 파일 7개를 업로드하고 공개합니다.
   `_`·`-` 접미사 또는 alpha/beta/rc 표시가 있는 버전은 prerelease입니다.
   업로드 실패 시 초안이 남으므로 확인 후 초안을 삭제하고 publish 작업을 재실행합니다.
   이미 공개된 릴리스는 덮어쓰지 않습니다.

수동 `workflow_dispatch`와 패키징 PR에서는 검증과 Actions 아티팩트 생성만 수행합니다.
`release-assets` 아티팩트로 최종 구성을 확인할 수 있습니다.
로컬 검증은 `python3 scripts/test.py --suite packaging`으로 실행합니다.
두 컴파일러 툴체인과 대상 데비안 메타데이터를 준비한 뒤 빈 출력 디렉터리에서
전체 배포물 구성을 만들 수 있습니다.

```sh
make release-package DIST_DIR=dist/release
make source-package DIST_DIR=dist/release
# Windows 네이티브 빌드의 xen-<version>-windows-x86_64.zip도 dist/release에 복사합니다.
python3 -m packaging.github.release --directory dist/release
(cd dist/release && sha256sum --check SHA256SUMS)
```

`release-package` 자체는 Linux 바이너리 패키지 4개를 만듭니다. Windows ZIP·소스 아카이브·체크섬은
별도 단계이며 GitHub 워크플로가 이 작업을 모두 수행합니다.
릴리스 변경 사항을 커밋한 뒤 일치하는 태그를 push합니다.

```sh
XEN_RELEASE_TAG="v$(cat VERSION)"
git tag "$XEN_RELEASE_TAG"
git push origin "$XEN_RELEASE_TAG"
```

모아 둔 결과물은
`python3 -m packaging.github.release --directory /path/to/assets --tag v<VERSION>`으로
검사합니다. 지정 디렉터리에는 패키지 6개와 선택적인 기존 `SHA256SUMS`만 있어야 하며,
이전 배포 파일이 섞이면 실패합니다.

## 소스 배포

```sh
make source-package VERSION=0.1.0-demo.3
```

`xen-<version>-source.tar.gz`에는 컴파일러·stdlib 소스, 빌드 파일, `packaging/`,
릴리스 워크플로, 스크립트, 테스트,
문서, 예제와 라이선스를 포함합니다. 컴파일러를 빌드하지 않으며 Git 이력·머신별
툴체인·생성된 빌드 결과는 제외합니다. 컴파일러 빌드 안내도 이 소스 패키지에 포함합니다.
