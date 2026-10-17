# Xen 설치

[GitHub Releases](https://github.com/skystarry-team/Xen/releases)에서 호스트 CPU에
맞는 컴파일러 패키지와 `SHA256SUMS`를 내려받습니다. 릴리스마다 새 다운로드
디렉터리를 사용하고 컴파일러를 실행할 OS와 CPU를 선택합니다. 각 컴파일러에서
Linux x86_64·AArch64와 Windows x86_64 프로그램을 생성할 수 있습니다. AArch64는
[프로젝트 지원 범위](../../../README.md)에 명시한 실험적 지원 대상입니다.

Linux 컴파일러 패키지:

| 호스트 CPU | 데비안 아키텍처 | 데비안 패키지 | 바이너리 아카이브 |
| --- | --- | --- | --- |
| x86-64 | `amd64` | `xen-lang_<debian-version>_amd64.deb` | `xen-<version>-linux-x86_64.tar.gz` |
| AArch64 | `arm64` | `xen-lang_<debian-version>_arm64.deb` | `xen-<version>-linux-aarch64.tar.gz` |

## Windows x86-64 (실험적 지원)

같은 릴리스의 `xen-<version>-windows-x86_64.zip`과 `SHA256SUMS`를 선택합니다.
추출 전에 `Get-FileHash .\xen-<version>-windows-x86_64.zip -Algorithm SHA256`의
결과를 `SHA256SUMS`의 해당 ZIP 항목과 비교합니다.
PowerShell에서 `<version>`을 실제 릴리스 버전으로 바꾸어 실행합니다.

```powershell
$version = "<version>"
Expand-Archive -LiteralPath ".\xen-$version-windows-x86_64.zip" -DestinationPath .\xen
Set-Location ".\xen\xen-$version-windows-x86_64"
.\bin\xen.exe version
.\bin\xen.exe run examples\demo.xen
.\bin\xen.exe build examples\demo.xen -o app.exe
.\app.exe
.\bin\xen.exe test std.fs --filter null
$env:PATH = "$((Get-Location).Path)\bin;$env:PATH"
```

`bin/`과 `stdlib/`을 함께 유지하세요. `XEN_STDLIB_ROOT`는 설정하지 않아도 됩니다.
설치한 컴파일러 사용에는 OCaml·Dune·Python·Cygwin·MinGW가 필요하지 않습니다.
위 PATH 변경은 현재 PowerShell 세션에 적용됩니다. 제거할 때는 압축을 푼 디렉터리를
삭제하고, PATH에 영구 등록했다면 해당 항목도 제거합니다.

기본 타깃은 `x86_64-windows`, 기본 빌드 출력은 `a.exe`입니다.
`--target=x86_64-linux` 또는 `--target=aarch64-linux`으로 Linux 프로그램을 만들 수 있으며,
실행에는 호환 OS와 CPU가 필요합니다. Windows의 원시 syscall과 `extern_call`은 미지원입니다.
Windows x86-64는 실험적 지원입니다. 컴파일러·PE 실행·표준 라이브러리는
Windows Server 2022 네이티브 CI를 통과했으며, Windows 데스크톱 실 하드웨어 검증은
추가로 필요합니다. Windows ARM64는 미지원입니다.
ZIP CI는 재배치와 PATH 격리를 검사하며 깨끗한 OS 설치 검증을 대신하지 않습니다.

## Debian과 Ubuntu

릴리스 CI는 두 CPU의 Debian 12/13과 Ubuntu 22.04/24.04/26.04에서 설치 검사를
통과한 뒤 공개하도록 구성되어 있습니다. 파생 배포판은 개별 검사 대상이 아닙니다.
`dpkg --print-architecture`로 패키지 아키텍처를 확인하고, 같은 릴리스의 해당
`.deb` 파일과 체크섬 목록을 내려받습니다.

다운로드 디렉터리에서 무결성을 확인합니다. 목록에 있는 다른 배포 파일을 모두
내려받을 필요는 없습니다.

```sh
sha256sum --check --ignore-missing SHA256SUMS
```

amd64에서는 다음 명령으로 설치합니다.

```sh
sudo apt install ./xen-lang_*_amd64.deb
```

arm64에서는 `sudo apt install ./xen-lang_*_arm64.deb`를 사용합니다.
이 디렉터리에는 선택한 릴리스·CPU의 패키지만 두어야 합니다.
apt로 설치하면 컴파일러의 시스템 라이브러리 의존성을 확인하고 설치합니다.
설치된 컴파일러 사용에는 OCaml·Dune·Python이 필요하지 않습니다.

```sh
xen version
xen run /usr/share/doc/xen-lang/examples/demo.xen
xen test std.fs --filter null
```

패키지 이름은 `xen-lang`, 명령 이름은 `xen`입니다. 실행 파일은 `/usr/bin/xen`,
필수 런타임 모듈은 `/usr/lib/xen`, 예제·라이선스는 `/usr/share/doc/xen-lang`에
설치합니다. `XEN_STDLIB_ROOT` 설정은 필요하지 않습니다. 최소 OS 이미지에서는
문서 설치가 제외될 수 있으므로 번들 예제 대신 직접 작성한 소스를 사용합니다.

업그레이드할 때도 새 `.deb`를 내려받아 같은 apt 명령으로 설치합니다.
컴파일러와 번들 모듈은 다음 명령으로 제거합니다.

```sh
sudo apt remove xen-lang
```

데비안 패키지 버전은 접미사 구분자를 변환하고 패키징 리비전을 붙입니다.
예를 들어 `v0.1.0-demo.4`는 `0.1.0~demo.4-1`이 되며, `xen version`은 원본인
`v0.1.0-demo.4`를 출력합니다. 직접 빌드한 패키지는 빌드 환경에 따라 필요한
시스템 라이브러리 버전이 달라지므로 [버전·의존성 처리](packaging.md#데비안-패키지)를 확인하세요.

## 바이너리 tar.gz

일반 사용자 소유의 디렉터리에 압축을 풀어 사용할 수도 있습니다.
호스트 CPU에 맞는 바이너리 아카이브와 `SHA256SUMS`를 내려받고 앞의 체크섬
명령으로 확인합니다. 소스 아카이브는 컴파일러를 직접 빌드할 때 사용합니다.

x86-64용 바이너리 아카이브 하나만 있는 다운로드 디렉터리에서 실행합니다.

```sh
tar -xzf xen-*-linux-x86_64.tar.gz
cd xen-*-linux-x86_64
./bin/xen version
./bin/xen run examples/demo.xen
export PATH="$PWD/bin:$PATH"
```

AArch64에서는 아카이브·디렉터리 이름의 `x86_64`를 `aarch64`로 바꿉니다.
PATH 변경은 현재 셸에 적용됩니다. 이후에도 사용하려면 설치한 `bin` 경로를
셸 설정에 추가합니다. 배포본을 옮길 때는 `bin/`과 `stdlib/`을 함께 유지해야 합니다.
컴파일러에는 호환되는 시스템 라이브러리가 필요하며, 생성된 Xen 프로그램은
정적 Linux 실행 파일입니다.

소스 빌드는 [Xen 빌드 안내](build.md), 두 패키지 형식의 생성과 배포는
[패키징·릴리스 안내](packaging.md)를 참고하세요.
