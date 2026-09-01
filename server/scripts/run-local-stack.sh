#!/usr/bin/env bash
set -euo pipefail

SERVER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SERVER_ROOT"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required. Install Docker Desktop or Engine, then retry." >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "The Docker engine is not running. Start Docker Desktop (or dockerd) and retry." >&2
  exit 1
fi

echo "building and starting the local AudioReader API stack..."
docker compose up --build -d --wait --wait-timeout 180

echo "running HTTP end-to-end checks..."
AUDIOREADER_API_BASE_URL="${AUDIOREADER_API_BASE_URL:-http://127.0.0.1:8787}" \
  LOCAL_DEV_OTP="${LOCAL_DEV_OTP:-123456}" \
  bash "$SERVER_ROOT/scripts/e2e-local-api.sh"

cat <<'EOF'

Local remote server is ready.

  API:        http://127.0.0.1:8787
  Health:     http://127.0.0.1:8787/v1/health
  Postgres:   127.0.0.1:54329  (user postgres, trust auth, database postgres)
  Local OTP:  123456  (local/test only; not emailed)

Native apps default to http://localhost:8787. Sign in from Settings with any
email and code 123456. Stop the stack with:  pnpm dev:docker:down
EOF
