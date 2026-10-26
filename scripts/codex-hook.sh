#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook_bin="$SCRIPT_DIR/../bin/codex-hook"
if [ -x "$hook_bin" ]; then
    exec "$hook_bin" "$@"
fi
