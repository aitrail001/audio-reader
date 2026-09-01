#!/usr/bin/env bash
set -euo pipefail

SERVER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v supabase >/dev/null 2>&1; then
  echo "The Supabase CLI is required. See https://supabase.com/docs/guides/local-development/cli/getting-started" >&2
  exit 1
fi

exec supabase --workdir "$SERVER_ROOT" start
