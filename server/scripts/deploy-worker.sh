#!/usr/bin/env bash
# Deploy the API worker to a named Wrangler environment only.
set -euo pipefail

ENV="${1:-}"
SERVER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

"$SERVER_ROOT/scripts/preflight-deploy.sh" "$ENV"

cd "$SERVER_ROOT/apps/api-worker"
echo "Deploying @audio-reader/api-worker --env ${ENV}"
pnpm exec wrangler deploy --env "$ENV"

cat <<'EOF'

Smoke the hosted API:

  curl -i https://<worker-host>/healthz
  curl -i https://<worker-host>/readyz
  curl -s https://<worker-host>/v1/auth/config

Packaged apps already point at production via ProductAPIBaseURL. Override with
AUDIOREADER_API_BASE_URL for local Docker (`http://127.0.0.1:8787`).
EOF
