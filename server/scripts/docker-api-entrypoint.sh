#!/bin/sh
set -eu

cd /workspace/apps/api-worker

{
  echo "ENVIRONMENT=${ENVIRONMENT:-local}"
  echo "APP_VERSION=${APP_VERSION:-1.0.0-draft.1}"
  echo "LOCAL_DEV_OTP=${LOCAL_DEV_OTP:-123456}"
  echo "CORS_ALLOWED_ORIGINS=${CORS_ALLOWED_ORIGINS:-}"
  echo "MAX_BODY_BYTES=${MAX_BODY_BYTES:-1048576}"
  if [ -n "${ADMIN_ORIGIN:-}" ]; then
    echo "ADMIN_ORIGIN=${ADMIN_ORIGIN}"
  fi
} > .dev.vars

exec pnpm exec wrangler dev --ip 0.0.0.0 --port 8787 --local
