# 명령어 안내

이 문서의 명령은 `xen`이 `PATH`에 있다는 전제입니다. 배포 디렉터리에서는 `./bin/xen`, 저장소에서는 `compiler/dist/xen`으로 바꾸어도 됩니다. Windows PowerShell에서는 `.\bin\xen.exe` 또는 `.\compiler\dist\xen.exe`를 사용합니다.

| 명령 | 사용하는 때 |
| --- | --- |
| `xen version` 또는 `xen --version` | 설치된 버전 확인 |
| `xen check file.xen` | 실행 전 오류 검사 |
| `xen run file.xen` | 바로 실행 |
| `xen build file.xen -o app` | 독립 실행 파일 만들기 |
| `xen test [file.xen 또는 디렉터리 또는 std.module]` | 테스트 실행 |

`check`와 `build`는 성공하면 출력하지 않습니다. `build`에서 `-o`를 생략하면 현재 디렉터리에 Linux·macOS 타깃은 `a.out`, Windows 타깃은 `a.exe`를 만듭니다. 출력 이름은 호스트 OS와 관계없이 선택한 타깃을 따릅니다. 같은 출력 경로가 이미 있으면 덮어씁니다. `run`은 현재 작업 디렉터리와 표준 입출력을 사용하며 프로그램이 끝나면 임시 실행 파일을 지웁니다.

## 프로그램 인자

```sh
xen run word_count.xen -- input.txt
xen build word_count.xen -o word-count
./word-count input.txt
```

`--` 앞은 Xen의 옵션이고 뒤는 프로그램의 인자입니다. 프로그램에서 `std.env.args()` 또는 `arg_count()`, `arg(index)`로 읽습니다. 첫 인자의 색인은 0이며 실행 파일 이름은 포함하지 않습니다. `arg`의 잘못된 색인은 실행 오류입니다.

## 실행 환경 선택

기본 실행 환경은 설치한 Xen의 OS와 CPU를 따릅니다. `check`, `build`, `run`, `test`에 `--target=x86_64-linux`, `--target=aarch64-linux`, `--target=x86_64-windows`, `--target=aarch64-macos`를 지정할 수 있습니다. `arm64-linux`와 `arm64-darwin`은 별명입니다.

```sh
xen build hello.xen --target=aarch64-linux -o hello-arm64
```

만든 파일은 호환되는 OS와 CPU에서 실행하세요. 다른 타깃을 골라도 현재 머신에서 자동으로 실행되지는 않습니다. AArch64, Windows x86-64, Apple Silicon macOS는 실험적 지원입니다. Apple Silicon 네이티브 CI 검증은 대기 중이며 Intel macOS와 Windows ARM64는 미지원입니다. Windows 컴파일러·PE 실행·표준 라이브러리는 Windows Server 2022 네이티브 CI를 통과했지만, Windows 데스크톱 실기기 검증은 추가로 필요합니다. Windows의 원시 syscall과 `extern_call`은 지원하지 않습니다. PowerShell에서는 `-o hello.exe`로 빌드하고 `.\hello.exe`로 실행합니다.

## 테스트 선택

`xen test`는 현재 디렉터리에서 찾습니다. `--filter 단어`로 이름을 좁힐 수 있습니다. 자세한 사용법은 [테스트](testing.md)를 참고하세요.

## 선택적인 빌드 옵션

평소에는 기본 옵션으로 실행하면 됩니다. 직접 `#scope[opt] { ... }`를 적은 블록에 대해 `build`, `run`, `test`의 `--opt=basic`이 기본으로 적용됩니다. `--opt=off`로 끌 수 있습니다. 표시가 없는 코드에는 적용하지 않습니다.

`--opt-report`는 적용 정보를 표준 오류로 출력합니다. `--opt-cache=디렉터리`는 해당 디렉터리에 빌드용 캐시를 저장합니다. 두 옵션은 `basic`에서만 사용할 수 있고 `check`에서는 사용할 수 없습니다. 이 옵션을 알아야 프로그램을 작성할 수 있는 것은 아닙니다.

## 종료 상태와 도움말

| 상태 | 뜻 |
| --- | --- |
| `0` | 성공 |
| `1` | 코드·실행·테스트 오류 또는 테스트 선택 실패 |
| `2` | 잘못된 명령 사용 |

`run`은 프로그램의 종료 상태를 그대로 전달합니다. `panic`과 일반 실행 오류는 보통 1입니다. 별도 `--help` 옵션은 없으며, 인자 없이 `xen`을 실행하면 사용법을 표준 오류에 보여 주고 2로 종료합니다.

---

[목차](README.md) · [이전: 표준 라이브러리 찾기](stdlib.md) · [다음: 문법과 자주 만나는 문제](reference.md) · [English](../en/cli.md)
