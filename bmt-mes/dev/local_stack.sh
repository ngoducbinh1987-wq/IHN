#!/usr/bin/env bash
# Dựng "Supabase thu nhỏ" để thử web app cục bộ: Postgres (sẵn có, cổng 5433) + GoTrue + PostgREST + proxy :54321
# Dùng: dev/local_stack.sh up | down
set -euo pipefail
cd "$(dirname "$0")"
[[ -f .env.local-stack ]] || node gen_keys.mjs > .env.local-stack
source .env.local-stack
DB=${DB:-bmt_app}; PG="host=/tmp port=5433 user=postgres"
SCHEMAS="public,app,core,master,sales,plan,purchase,inv,mfg,qa,cost,wf,iot,integ"
case "${1:-up}" in
down) docker rm -f bmt-gotrue bmt-postgrest >/dev/null 2>&1 || true; pkill -f "node proxy.mjs" || true; exit 0;;
esac
docker rm -f bmt-gotrue bmt-postgrest >/dev/null 2>&1 || true
psql "$PG dbname=postgres" -qc "drop database if exists $DB" -c "create database $DB"
psql "$PG dbname=$DB" -q -v ON_ERROR_STOP=1 <<SQL
do \$\$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin noinherit bypassrls; end if;
  if not exists (select 1 from pg_roles where rolname='authenticator') then create role authenticator login noinherit; end if;
  if not exists (select 1 from pg_roles where rolname='supabase_auth_admin') then create role supabase_auth_admin login superuser; end if;
end \$\$;
grant anon, authenticated, service_role to authenticator;
create schema if not exists auth authorization supabase_auth_admin;
grant usage on schema public to anon, authenticated, service_role;
SQL
# GoTrue tự tạo bảng auth.* rồi chạy nền
docker run -d --name bmt-gotrue --network host \
  -e GOTRUE_API_HOST=127.0.0.1 -e PORT=9999 -e API_EXTERNAL_URL=http://localhost:54321/auth/v1 \
  -e GOTRUE_DB_DRIVER=postgres -e GOTRUE_DB_DATABASE_URL="postgres://supabase_auth_admin@127.0.0.1:5433/$DB?sslmode=disable&search_path=auth" \
  -e GOTRUE_SITE_URL=http://localhost:3000 -e GOTRUE_JWT_SECRET="$JWT_SECRET" -e GOTRUE_JWT_EXP=3600 \
  -e GOTRUE_JWT_AUD=authenticated -e GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated -e GOTRUE_JWT_ADMIN_ROLES=service_role \
  -e GOTRUE_DISABLE_SIGNUP=true -e GOTRUE_EXTERNAL_EMAIL_ENABLED=true -e GOTRUE_MAILER_AUTOCONFIRM=true \
  supabase/gotrue:v2.158.1 >/dev/null
for i in $(seq 1 30); do curl -sf http://127.0.0.1:9999/health >/dev/null && break; sleep 1; done
psql "$PG dbname=$DB" -qc "grant usage on schema auth to anon, authenticated, service_role; grant execute on all functions in schema auth to anon, authenticated, service_role;"
# Áp migration của BMT MES
export PGOPTIONS="-c client_min_messages=warning"
for f in ../supabase/migrations/*.sql; do psql "$PG dbname=$DB" -q -v ON_ERROR_STOP=1 -1 -f "$f" >/dev/null; done
docker run -d --name bmt-postgrest --network host \
  -e PGRST_DB_URI="postgres://authenticator@127.0.0.1:5433/$DB" -e PGRST_DB_SCHEMAS="$SCHEMAS" \
  -e PGRST_DB_ANON_ROLE=anon -e PGRST_JWT_SECRET="$JWT_SECRET" -e PGRST_SERVER_PORT=3001 \
  postgrest/postgrest:v12.2.3 >/dev/null
pkill -f "node proxy.mjs" || true
(nohup node proxy.mjs > proxy.log 2>&1 &)
sleep 3
echo "OK: http://localhost:54321  (anon key trong dev/.env.local-stack)"
