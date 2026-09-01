#!/usr/bin/env bash
set -euo pipefail

SERVER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$SERVER_ROOT/.." && pwd)"

python3 -m unittest discover -s "$REPO_ROOT/Tests/contract" -v
cd "$SERVER_ROOT"
pnpm contract:check
pnpm test
