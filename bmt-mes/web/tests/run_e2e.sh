#!/usr/bin/env bash
# Chạy toàn bộ kiểm thử end-to-end trên môi trường thử cục bộ (dựng lại database từ đầu).
# Dùng: web/tests/run_e2e.sh [thư_mục_ảnh]
set -euo pipefail
cd "$(dirname "$0")/../.."
SHOTS=${1:-$(mktemp -d)}
dev/local_stack.sh up
source dev/.env.local-stack
curl -sf -X POST http://localhost:54321/auth/v1/admin/users -H "Authorization: Bearer $SERVICE_ROLE_KEY" -H "apikey: $SERVICE_ROLE_KEY" \
  -H 'Content-Type: application/json' -d '{"email":"admin@bmt.test","password":"Admin@12345","email_confirm":true}' >/dev/null
cd web
printf "NEXT_PUBLIC_SUPABASE_URL=http://localhost:54321\nNEXT_PUBLIC_SUPABASE_ANON_KEY=%s\nSUPABASE_SERVICE_ROLE_KEY=%s\n" "$ANON_KEY" "$SERVICE_ROLE_KEY" > .env.local
NEXT_TELEMETRY_DISABLED=1 npx next build > /dev/null
PIDFILE=.next/e2e-server.pid
[[ -f $PIDFILE ]] && kill "$(cat $PIDFILE)" 2>/dev/null || true
pgrep -f "^next-server" | xargs -r kill 2>/dev/null || true; sleep 1
NEXT_TELEMETRY_DISABLED=1 nohup npx next start -p 3000 > "$SHOTS/next.log" 2>&1 &
echo $! > "$PIDFILE"
for i in $(seq 1 30); do curl -s -o /dev/null http://localhost:3000/login && break; sleep 1; done
NODE_PATH=$(npm root -g) node tests/e2e.mjs "$SHOTS"
echo "Ảnh chụp: $SHOTS"
