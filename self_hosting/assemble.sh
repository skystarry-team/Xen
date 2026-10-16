#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
# Assemble the explicit source list into one Xen compilation unit; no rewriting.
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
while IFS= read -r source; do
    if [ "$source" = compiler.xen ]; then source=${1:-compiler.xen}; fi
    cat "$source"
    printf '\n'
done < sources.list
