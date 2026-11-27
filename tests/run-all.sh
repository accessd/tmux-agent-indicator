#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Every tests/test-*.sh runs, in sorted order; the first failure stops the run.
tests=("$ROOT_DIR"/tests/test-*.sh)
if [ ! -e "${tests[0]}" ]; then
    echo "FAIL: no tests found in $ROOT_DIR/tests"
    exit 1
fi

for test_script in "${tests[@]}"; do
    echo "==> $(basename "$test_script")"
    "$test_script"
done

echo "PASS: all automated tests"
