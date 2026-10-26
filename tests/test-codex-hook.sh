#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
(cd "$ROOT_DIR" && env -u GOROOT go test ./cmd/codex-hook)

echo "PASS: Codex hook pane routing"
