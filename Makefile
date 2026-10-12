# SPDX-License-Identifier: MIT OR Apache-2.0
# Xen build and distribution helpers.

SHELL := /bin/sh

PROJECT := xen
VERSION ?= $(shell cat VERSION)
export XEN_BUILD_VERSION := $(VERSION)
# Preserve explicit single-package selections before assigning defaults.
PACKAGE_SINGLE := $(strip $(PACKAGE_BINARY) $(PACKAGE_CONTEXT) $(DUNE_WORKSPACE) $(PACKAGE_ARCH))
PACKAGE_ARCHS ?= x86_64 aarch64
PACKAGE_TOOLCHAINS ?= .package-toolchains.json
DUNE_WORKSPACE ?=
PACKAGE_CONTEXT ?= default
PACKAGE_PLATFORM ?= linux
PACKAGE_ARCH ?=
PACKAGE_RUNNER ?= []
export PACKAGE_RUNNER
PACKAGE_NAME ?=
# An explicit existing binary skips Dune; context builds never promote to dist.
ifeq ($(origin PACKAGE_BINARY), undefined)
PACKAGE_BINARY := _build/$(or $(strip $(PACKAGE_CONTEXT)),default)/compiler/main.exe
PACKAGE_NEEDS_BUILD := yes
endif

QUICKCHECK_MODE ?= all
QUICKCHECK_DEPTH ?= standard
QUICKCHECK_SEED ?=
DIST_DIR := dist
PACKAGE ?=
SOURCE_NAME := $(PROJECT)-$(VERSION)-source
SOURCE_PACKAGE := $(DIST_DIR)/$(SOURCE_NAME).tar.gz

.PHONY: all build test package package-build package-one package-one-build source-package clean help

all: build

build:
	dune build @release

test:
	python3 scripts/test.py --mode "$(QUICKCHECK_MODE)" --depth "$(QUICKCHECK_DEPTH)" $(if $(QUICKCHECK_SEED),--seed "$(QUICKCHECK_SEED)")

ifneq ($(strip $(PACKAGE_SINGLE)),)
package: package-one
package-build: package-one-build
else
package:
	python3 scripts/package_build.py --architectures $(PACKAGE_ARCHS) --toolchains "$(PACKAGE_TOOLCHAINS)" --platform "$(PACKAGE_PLATFORM)" --version "$(VERSION)" --output-dir "$(DIST_DIR)" $(if $(PACKAGE_NAME),--name "$(PACKAGE_NAME)") $(if $(PACKAGE),--output "$(PACKAGE)")

package-build:
	python3 scripts/package_build.py --architectures $(PACKAGE_ARCHS) --toolchains "$(PACKAGE_TOOLCHAINS)" --platform "$(PACKAGE_PLATFORM)" --version "$(VERSION)" --build-only
endif

package-one-build:
ifeq ($(PACKAGE_NEEDS_BUILD),yes)
	dune build $(if $(DUNE_WORKSPACE),--workspace="$(DUNE_WORKSPACE)") "$(PACKAGE_BINARY)"
endif

package-one: package-one-build
	python3 scripts/package.py --binary "$(PACKAGE_BINARY)" --platform "$(PACKAGE_PLATFORM)" --version "$(VERSION)" --output-dir "$(DIST_DIR)" $(if $(PACKAGE_ARCH),--architecture "$(PACKAGE_ARCH)") $(if $(PACKAGE_NAME),--name "$(PACKAGE_NAME)") $(if $(PACKAGE),--output "$(PACKAGE)")

source-package:
	python3 scripts/package.py --source --version "$(VERSION)" --name "$(SOURCE_NAME)" --output "$(SOURCE_PACKAGE)"

clean:
	dune clean
	rm -rf "$(DIST_DIR)"

help:
	@printf '%s\n' \
	  'make build    Build the Xen compiler executable.' \
	  'make package  Build and package Linux x86_64 and AArch64 compilers.' \
	  'make package-build  Build both package compilers without archiving.' \
	  'make package-one  Build and package one selected compiler.' \
	  'make source-package  Export public source without Git history or local artifacts.' \
	  'make test     Run the test suite through scripts/test.py.' \
	  'make clean    Remove Dune and package build artifacts.' \
	  '' \
	  'Override VERSION to choose the package version, for example:' \
	  '  make package VERSION=0.1.0' \
	  'Configure cross prefixes and runners in .package-toolchains.json.' \
	  'PACKAGE_TOOLCHAINS selects another configuration file.' \
	  'PACKAGE_ARCHS selects a subset; default: x86_64 aarch64.' \
	  'For package-one, select DUNE_WORKSPACE and PACKAGE_CONTEXT as needed.' \
	  'PACKAGE_BINARY selects an existing executable without rebuilding.' \
	  'PACKAGE_ARCH verifies the ELF architecture; PACKAGE_PLATFORM supports linux.' \
	  'PACKAGE_RUNNER is a JSON argument array, e.g. ["qemu-aarch64","-L","/sysroot"].' \
	  '' \
	  'See tests/README.md for individual test suites.'
