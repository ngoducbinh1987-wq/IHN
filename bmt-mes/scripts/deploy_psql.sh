#!/usr/bin/env bash
# Áp dụng migration chưa chạy lên Supabase bằng psql (dùng trong GitHub Actions hoặc máy có psql).
# Biến môi trường: SUPABASE_DB_URL = chuỗi kết nối Session pooler (Dashboard → Connect).
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SUPABASE_DB_URL:?Thiếu SUPABASE_DB_URL}"
export PGOPTIONS="-c client_min_messages=warning"
P() { psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -qAt "$@"; }

P -c "create schema if not exists supabase_migrations;
      create table if not exists supabase_migrations.schema_migrations (version text primary key, statements text[], name text);"
for f in supabase/migrations/*.sql; do
  base=$(basename "$f" .sql); ver=${base%%_*}; name=bmt_mes_${base#*_}
  if [[ -n $(P -c "select 1 from supabase_migrations.schema_migrations where version = '$ver'") ]]; then
    echo "= $base (đã chạy)"; continue
  fi
  echo "→ $base"
  # Mỗi migration chạy trong một transaction; lỗi thì dừng, không ghi lịch sử
  P -1 -f "$f" -c "insert into supabase_migrations.schema_migrations (version, name) values ('$ver', '$name')" > /dev/null
done

echo "Kiểm tra:"
P -c "select 'san_pham=' || (select count(*) from master.products) || ', vat_tu=' || (select count(*) from master.materials where not is_scrap)
          || ', dong_bom=' || (select count(*) from master.bom_lines) || ', vai_tro=' || (select count(*) from core.roles)
          || ', buoc_duyet=' || (select count(*) from wf.approval_steps)
          || ', spec_rdc_vuot=' || (select count(*) from master.spec_results where rdc_calc > rdc_limit)"
