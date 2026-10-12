# SPDX-License-Identifier: MIT OR Apache-2.0
# Xen build and distribution helpers.

SHELL := /bin/sh

PROJECT := xen
VERSION ?= $(shell cat VERSION)
export XEN_BUILD_VERSION := $(VERSION)
DUNE_WORKSPACE ?=
PACKAGE_CONTEXT ?= default
PACKAGE_PLATFORM ?= linux
PACKAGE_ARCH ?=
PACKAGE_RUNNER ?= []
export PACKAGE_RUNNER
PACKAGE_NAME ?=
# An explicit existing binary skips Dune; context builds never promote to dist.
ifeq ($(origin PACKAGE_BINARY), undefined)
PACKAGE_BINARY := _build/$(PACKAGE_CONTEXT)/compiler/main.exe
PACKAGE_NEEDS_BUILD := yes
endif

XEN := compiler/dist/xen
QUICKCHECK_MODE ?= all
QUICKCHECK_DEPTH ?= standard
QUICKCHECK_SEED ?=
DIST_DIR := dist
PACKAGE ?=
SOURCE_NAME := $(PROJECT)-$(VERSION)-source
SOURCE_PACKAGE := $(DIST_DIR)/$(SOURCE_NAME).tar.gz

.PHONY: all build test test-arm64 test-host quickcheck semantic-test package package-build source-package clean help

all: build

build:
	dune build @release

test: build
	dune runtest
	XEN_TEST_OPT=basic dune exec tests/native_core_test.exe
	python3 tests/integration/optimization_test.py
	python3 tests/integration/jit_test.py
	python3 tests/integration/toolchain_test.py
	python3 tests/integration/arm64_test.py
	python3 tests/integration/host_test.py
	python3 tests/integration/stdlib_test.py
	python3 tests/integration/stdlib_test.py --arm64
	python3 tests/integration/test_workflow_test.py
	$(MAKE) quickcheck

test-arm64: build
	dune exec tests/arm64_machine_test.exe
	XEN_REQUIRE_ARM64=1 python3 tests/integration/arm64_test.py
	XEN_REQUIRE_ARM64=1 python3 tests/integration/stdlib_test.py --arm64

# Runs the compiler's version/check/build/run/test/package paths on either host.
# The full test target still includes x86 execution and JIT-specific regressions.
test-host: build
	dune exec tests/backend_contract_test.exe
	python3 tests/integration/host_test.py

quickcheck: build
	XEN_BIN="$(CURDIR)/$(XEN)" XEN_STDLIB_ROOT="$(CURDIR)/stdlib" python3 tests/property/runner.py --mode "$(QUICKCHECK_MODE)" --depth "$(QUICKCHECK_DEPTH)" $(if $(QUICKCHECK_SEED),--seed "$(QUICKCHECK_SEED)")

semantic-test: build
	dune exec tests/semantic_ir_test.exe
	XEN_BIN="$(CURDIR)/$(XEN)" XEN_STDLIB_ROOT="$(CURDIR)/stdlib" python3 tests/property/runner.py --mode semantic --depth "$(QUICKCHECK_DEPTH)" $(if $(QUICKCHECK_SEED),--seed "$(QUICKCHECK_SEED)")

package-build:
ifeq ($(PACKAGE_NEEDS_BUILD),yes)
	dune build $(if $(DUNE_WORKSPACE),--workspace="$(DUNE_WORKSPACE)") "$(PACKAGE_BINARY)"
endif

package: package-build
	python3 scripts/package.py --binary "$(PACKAGE_BINARY)" --platform "$(PACKAGE_PLATFORM)" --version "$(VERSION)" --output-dir "$(DIST_DIR)" $(if $(PACKAGE_ARCH),--architecture "$(PACKAGE_ARCH)") $(if $(PACKAGE_NAME),--name "$(PACKAGE_NAME)") $(if $(PACKAGE),--output "$(PACKAGE)")

source-package:
	python3 scripts/package.py --source --version "$(VERSION)" --name "$(SOURCE_NAME)" --output "$(SOURCE_PACKAGE)"

clean:
	dune clean
	rm -rf "$(DIST_DIR)"

help:
	@printf '%s\n' \
	  'make build    Build the Xen compiler executable.' \
	  'make test     Run regression and property tests.' \
	  'make test-arm64  Verify ARM64 with a native host or qemu-aarch64.' \
	  'make quickcheck  Run Python property tests only.' \
	  'make semantic-test  Run Semantic IR generative/metamorphic properties.' \
	  'make test-host  Verify native compiler use and relocated packaging.' \
	  'make package  Bundle a compiler as xen-VERSION-PLATFORM-ARCH.tar.gz.' \
	  'make source-package  Export public source without Git history or local artifacts.' \
	  'make clean    Remove Dune and package build artifacts.' \
	  '' \
	  'Override VERSION to choose the package version, for example:' \
	  '  make package VERSION=0.1.0' \
	  'Select a cross build with DUNE_WORKSPACE and PACKAGE_CONTEXT=arm64.' \
	  'PACKAGE_BINARY selects an existing executable without rebuilding.' \
	  'PACKAGE_ARCH verifies the ELF architecture; PACKAGE_PLATFORM supports linux.' \
	  'PACKAGE_RUNNER is a JSON argument array, e.g. ["qemu-aarch64","-L","/sysroot"].' \
	  '' \
	  'Configure property tests with QUICKCHECK_MODE, QUICKCHECK_DEPTH, and QUICKCHECK_SEED.'
