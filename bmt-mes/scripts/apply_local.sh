#!/usr/bin/env bash
# Chạy toàn bộ migration lên một PostgreSQL cục bộ để kiểm thử.
# Dùng: PGURL="host=/tmp port=5433 user=postgres" scripts/apply_local.sh <tên_db>
set -euo pipefail
DB=${1:-bmt_test}
PGURL=${PGURL:-"host=/tmp port=5433 user=postgres"}
export PGOPTIONS="-c client_min_messages=warning"
cd "$(dirname "$0")/.."
psql "$PGURL dbname=postgres" -qc "drop database if exists $DB" -c "create database $DB"
psql "$PGURL dbname=$DB" -q -v ON_ERROR_STOP=1 -f tests/local_bootstrap.sql
for f in supabase/migrations/*.sql; do
  echo "→ $f"
  psql "$PGURL dbname=$DB" -q -v ON_ERROR_STOP=1 -f "$f" > /dev/null
done
echo "OK: đã áp dụng $(ls supabase/migrations/*.sql | wc -l) migration vào $DB"
