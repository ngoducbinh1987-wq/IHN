#!/usr/bin/env bash
# Đẩy migration lên Supabase qua Management API (HTTPS), không cần mở cổng Postgres.
#
# Biến môi trường:
#   SUPABASE_ACCESS_TOKEN   Personal access token (Dashboard → Account → Access Tokens)
#   SUPABASE_PROJECT_REF    mặc định critwnuscvdchdbvwygv (project thử nghiệm)
#
# Dùng: scripts/deploy_supabase.sh            # áp dụng migration chưa chạy + mở schema cho Data API
#       scripts/deploy_supabase.sh --status   # chỉ xem migration nào đã chạy
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SUPABASE_ACCESS_TOKEN:?Thiếu SUPABASE_ACCESS_TOKEN}"
REF=${SUPABASE_PROJECT_REF:-critwnuscvdchdbvwygv}
API="https://api.supabase.com/v1/projects/$REF"
SCHEMAS="app,core,master,sales,plan,purchase,inv,mfg,qa,cost,wf,iot,integ"

run_sql() {  # $1 = file SQL
  local body resp code
  body=$(python3 -I -c 'import json,sys; print(json.dumps({"query": open(sys.argv[1], encoding="utf-8").read()}))' "$1")
  resp=$(mktemp)
  code=$(curl -sS -o "$resp" -w '%{http_code}' -X POST "$API/database/query" \
    -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H "Content-Type: application/json" --data-binary "$body")
  if [[ "$code" != 2* ]]; then echo "LỖI ($code): $(cat "$resp")" >&2; rm -f "$resp"; return 1; fi
  cat "$resp"; rm -f "$resp"
}

q() { local f; f=$(mktemp --suffix=.sql); printf '%s' "$1" > "$f"; run_sql "$f"; rm -f "$f"; }

# Bảng theo dõi migration, tương thích Supabase CLI
q "create schema if not exists supabase_migrations;
   create table if not exists supabase_migrations.schema_migrations (version text primary key, statements text[], name text);" >/dev/null
applied=$(q "select coalesce(json_agg(version), '[]') as v from supabase_migrations.schema_migrations")

if [[ "${1:-}" == "--status" ]]; then echo "$applied"; exit 0; fi

for f in supabase/migrations/*.sql; do
  base=$(basename "$f" .sql); ver=${base%%_*}; name=${base#*_}
  if grep -q "\"$ver\"" <<<"$applied"; then echo "= $base (đã chạy)"; continue; fi
  echo "→ $base"
  run_sql "$f" >/dev/null
  q "insert into supabase_migrations.schema_migrations (version, name) values ('$ver', '$name')" >/dev/null
done

# Mở các schema cho Data API (PostgREST) để web app gọi được
curl -sS -o /dev/null -w "Data API schemas: HTTP %{http_code}\n" -X PATCH "$API/postgrest" \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H "Content-Type: application/json" \
  --data "{\"db_schema\": \"public,graphql_public,$SCHEMAS\"}"

echo "Kiểm tra nhanh:"
q "select (select count(*) from master.products) as san_pham, (select count(*) from master.materials where not is_scrap) as vat_tu,
          (select count(*) from master.bom_lines) as dong_bom, (select count(*) from core.roles) as vai_tro,
          (select count(*) from wf.approval_steps) as buoc_duyet"
echo
