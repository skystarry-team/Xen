# SPDX-License-Identifier: MIT OR Apache-2.0
# Xen build and distribution helpers.

SHELL := /bin/sh

PROJECT := xen
VERSION ?= $(shell cat VERSION)
export XEN_BUILD_VERSION := $(VERSION)
PACKAGE_NAME := $(PROJECT)-$(VERSION)-linux-x86_64

XEN := compiler/dist/xen
QUICKCHECK_MODE ?= all
QUICKCHECK_DEPTH ?= standard
QUICKCHECK_SEED ?=
DIST_DIR := dist
PACKAGE := $(DIST_DIR)/$(PACKAGE_NAME).tar.gz
SOURCE_NAME := $(PROJECT)-$(VERSION)-source
SOURCE_PACKAGE := $(DIST_DIR)/$(SOURCE_NAME).tar.gz

.PHONY: all build test quickcheck semantic-test package source-package clean help

all: build

build:
	dune build @release

test: build
	dune runtest
	XEN_TEST_OPT=basic dune exec tests/native_core_test.exe
	python3 tests/integration/optimization_test.py
	python3 tests/integration/jit_test.py
	python3 tests/integration/toolchain_test.py
	python3 tests/integration/stdlib_test.py
	python3 tests/integration/test_workflow_test.py
	$(MAKE) quickcheck

quickcheck: build
	XEN_BIN="$(CURDIR)/$(XEN)" XEN_STDLIB_ROOT="$(CURDIR)/stdlib" python3 tests/property/runner.py --mode "$(QUICKCHECK_MODE)" --depth "$(QUICKCHECK_DEPTH)" $(if $(QUICKCHECK_SEED),--seed "$(QUICKCHECK_SEED)")

semantic-test: build
	dune exec tests/semantic_ir_test.exe
	XEN_BIN="$(CURDIR)/$(XEN)" XEN_STDLIB_ROOT="$(CURDIR)/stdlib" python3 tests/property/runner.py --mode semantic --depth "$(QUICKCHECK_DEPTH)" $(if $(QUICKCHECK_SEED),--seed "$(QUICKCHECK_SEED)")

package: build
	python3 scripts/package.py --version "$(VERSION)" --name "$(PACKAGE_NAME)" --output "$(PACKAGE)"

source-package:
	python3 scripts/package.py --source --version "$(VERSION)" --name "$(SOURCE_NAME)" --output "$(SOURCE_PACKAGE)"

clean:
	dune clean
	rm -rf "$(DIST_DIR)"

help:
	@printf '%s\n' \
	  'make build    Build the Xen compiler executable.' \
	  'make test     Run regression and property tests.' \
	  'make quickcheck  Run Python property tests only.' \
	  'make semantic-test  Run Semantic IR generative/metamorphic properties.' \
	  'make package  Create a Linux x86-64 distribution archive.' \
	  'make source-package  Export public source without Git history or local artifacts.' \
	  'make clean    Remove Dune and package build artifacts.' \
	  '' \
	  'Override VERSION to choose the package version, for example:' \
	  '  make package VERSION=0.1.0' \
	  '' \
	  'Configure property tests with QUICKCHECK_MODE, QUICKCHECK_DEPTH, and QUICKCHECK_SEED.'
