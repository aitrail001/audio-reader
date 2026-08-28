#!/usr/bin/env bash
# Fail closed unless the named Wrangler environment is staging or production.
# Does not print secret values.
set -euo pipefail

ENV="${1:-}"
if [[ "$ENV" != "staging" && "$ENV" != "production" ]]; then
  echo "usage: $0 staging|production" >&2
  echo "Refusing to deploy the top-level wrangler [vars] (ENVIRONMENT=local, LOCAL_DEV_OTP)." >&2
  exit 1
fi

SERVER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKER="$SERVER_ROOT/apps/api-worker"
TOML="$WORKER/wrangler.toml"

if [[ ! -f "$TOML" ]]; then
  echo "missing $TOML" >&2
  exit 1
fi

python3 - "$TOML" "$ENV" <<'PY'
import re
import sys

path, env_name = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
section = re.search(
    rf"\[env\.{re.escape(env_name)}\.vars\](.*?)(?=\n\[|\Z)",
    text,
    re.S,
)
if section is None:
    print(f"wrangler.toml is missing [env.{env_name}.vars]", file=sys.stderr)
    sys.exit(1)
body = section.group(1)

def var(key):
    match = re.search(rf'^{re.escape(key)}\s*=\s*"(.*)"\s*$', body, re.M)
    return None if match is None else match.group(1)

environment = var("ENVIRONMENT")
if environment != env_name:
    print(
        f"[env.{env_name}.vars] ENVIRONMENT must be {env_name!r}, got {environment!r}",
        file=sys.stderr,
    )
    sys.exit(1)

otp = var("LOCAL_DEV_OTP")
if otp not in (None, ""):
    print(
        f"[env.{env_name}.vars] LOCAL_DEV_OTP must be empty, got {otp!r}",
        file=sys.stderr,
    )
    sys.exit(1)

cors = var("CORS_ALLOWED_ORIGINS")
if cors is None:
    print(f"[env.{env_name}.vars] CORS_ALLOWED_ORIGINS is missing", file=sys.stderr)
    sys.exit(1)
PY

cd "$WORKER"
if ! pnpm exec wrangler whoami >/dev/null 2>&1; then
  echo "Wrangler is not authenticated." >&2
  echo "Run: cd server/apps/api-worker && pnpm exec wrangler login" >&2
  exit 1
fi

cat <<EOF
Preflight passed for --env ${ENV}.

Required secrets (never commit; never put in wrangler.toml [vars]):
  wrangler secret put SUPABASE_URL --env ${ENV}
  wrangler secret put SUPABASE_JWT_SECRET --env ${ENV}
  wrangler secret put SUPABASE_ANON_KEY --env ${ENV}
  wrangler secret put SUPABASE_SERVICE_ROLE_KEY --env ${ENV}

Recommended before public passwordless:
  wrangler secret put TURNSTILE_SECRET_KEY --env ${ENV}
  wrangler secret put PASSWORDLESS_HMAC_SECRET --env ${ENV}

Managed Qwen (optional until assistant jobs ship):
  wrangler secret put QWEN_API_KEY --env ${ENV}

Supabase Auth dashboard:
  - Enable Email OTP (6-digit codes)
  - Enable Google and Azure providers
  - Allow redirect URL: audioreader://auth/callback
  - Apply server/supabase/migrations to the project database

Deploy with:
  pnpm deploy:${ENV}
  # or: bash server/scripts/deploy-worker.sh ${ENV}
EOF
