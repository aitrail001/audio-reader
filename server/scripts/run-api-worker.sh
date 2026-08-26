#!/usr/bin/env bash
set -euo pipefail

SERVER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SERVER_ROOT"

exec pnpm --filter @audio-reader/api-worker dev
