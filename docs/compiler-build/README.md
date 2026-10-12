# Compiler build documentation / 컴파일러 빌드 문서

These guides cover building the Xen compiler, preparing OCaml toolchains and
creating distributions. Language syntax and program usage are documented in
[English](../en/README.md) and [한국어](../ko/README.md).

이 문서는 Xen 컴파일러 자체의 빌드, OCaml 툴체인 준비와 배포 패키징을 다룹니다.
언어 사용법과 컴파일러 구축 절차는 별도로 안내합니다.

| Topic / 주제 | English | 한국어 |
| --- | --- | --- |
| Native compiler build / 네이티브 빌드 | [Build](en/build.md) | [빌드](ko/build.md) |
| AArch64 OCaml cross toolchain / 크로스 툴체인 | [AArch64](en/aarch64.md) | [AArch64](ko/aarch64.md) |
| Binary and source distributions / 배포 패키징 | [Packaging](en/packaging.md) | [패키징](ko/packaging.md) |

Linux x86_64 and AArch64 are supported compiler hosts. macOS is unsupported.
Contributor test commands are documented in [tests/README.md](../../tests/README.md).
