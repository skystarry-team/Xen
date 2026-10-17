# Compiler build documentation / 컴파일러 빌드 문서

These guides cover installing release packages, building the Xen compiler,
preparing OCaml toolchains and publishing distributions. Language syntax and program usage are documented in
[English](../en/README.md) and [한국어](../ko/README.md).

이 문서는 배포 패키지 설치, Xen 컴파일러 자체의 빌드, OCaml 툴체인 준비와 릴리스를 다룹니다.
언어 사용법과 컴파일러 구축 절차는 별도로 안내합니다.

| Topic / 주제 | English | 한국어 |
| --- | --- | --- |
| Install .deb, tar.gz or Windows ZIP / 배포 패키지 설치 | [Installation](en/installation.md) | [설치](ko/installation.md) |
| Native compiler build / 네이티브 빌드 | [Build](en/build.md) | [빌드](ko/build.md) |
| AArch64 OCaml cross toolchain / 크로스 툴체인 | [AArch64](en/aarch64.md) | [AArch64](ko/aarch64.md) |
| Build .deb, tar.gz, ZIP and GitHub releases / 패키징·릴리스 | [Packaging](en/packaging.md) | [패키징](ko/packaging.md) |

Start with installation to use a released compiler. Contributors building a
native compiler should follow the build guide; release maintainers should use
the packaging guide. Distribution tooling lives in
[`packaging/`](../../packaging/README.md), organized by package format.

배포된 컴파일러를 사용하려면 설치 안내부터 읽습니다. 컴파일러 개발은 빌드 안내,
배포물 생성과 GitHub 릴리스는 패키징 안내를 따릅니다. 배포 도구는
[`packaging/`](../../packaging/README.md)에서 패키징 형식별로 관리합니다.

Linux x86_64, Linux AArch64, Windows x86_64 and Apple Silicon macOS are compiler hosts.
AArch64, Windows and macOS support are experimental; Apple Silicon native CI validation is pending.
Windows native CI runs on Windows Server 2022; desktop hardware validation is
still required. Windows ARM64 and Intel macOS are unsupported.

Windows x86_64와 Apple Silicon macOS는 실험적 지원 대상입니다. Windows Server 2022 네이티브 CI는 통과했으며,
Windows 데스크톱 실 하드웨어 검증은 추가로 필요합니다. Apple Silicon 네이티브 CI 검증은 대기 중입니다.
Windows ARM64와 Intel macOS는 미지원입니다.
Contributor test commands are documented in [tests/README.md](../../tests/README.md).
