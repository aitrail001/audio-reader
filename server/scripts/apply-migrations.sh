#!/bin/sh
set -eu

HOST="${PGHOST:-127.0.0.1}"
PORT="${PGPORT:-5432}"
USER="${PGUSER:-postgres}"
DB="${PGDATABASE:-postgres}"
DIR="${MIGRATIONS_DIR:-$(CDPATH= cd "$(dirname "$0")/../supabase/migrations" && pwd)}"

psql_cmd() {
  psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -v ON_ERROR_STOP=1 "$@"
}

echo "waiting for postgres at ${HOST}:${PORT}..."
i=0
while [ "$i" -lt 60 ]; do
  if psql_cmd -c 'select 1' >/dev/null 2>&1; then
    break
  fi
  i=$((i + 1))
  sleep 1
done
if ! psql_cmd -c 'select 1' >/dev/null 2>&1; then
  echo "postgres did not become ready" >&2
  exit 1
fi

psql_cmd <<'SQL'
create table if not exists public.schema_migrations (
  filename text primary key,
  applied_at timestamptz not null default now()
);
SQL

for file in "$DIR"/*.sql; do
  [ -f "$file" ] || continue
  name=$(basename "$file")
  applied=$(psql_cmd -t -A -c "select count(*) from public.schema_migrations where filename = '${name}'")
  if [ "$applied" = "1" ]; then
    echo "skip ${name}"
    continue
  fi
  echo "apply ${name}"
  psql_cmd -f "$file"
  psql_cmd -c "insert into public.schema_migrations (filename) values ('${name}')"
done

echo "migrations complete"
