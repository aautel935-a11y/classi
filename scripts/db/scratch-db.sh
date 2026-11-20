#!/bin/sh
# An EMPTY, isolated local Supabase stack used only as a restore target: its own project id ("classi-restore-check")
# and ports (553xx), no migrations, no seed, PostgreSQL 17 (classi-staging's major version). Never linked to a hosted
# project. Needs the Supabase CLI and Docker (GitHub runners have both).
#   sh scripts/db/scratch-db.sh start <new empty folder>   prints the target URL (local default credentials)
#   sh scripts/db/scratch-db.sh stop  <that folder>        removes its containers and volumes
set -eu
. "$(dirname "$0")/guard.sh"
CMD="${1:?usage: scratch-db.sh start|stop <folder>}"; DIR="${2:?usage: scratch-db.sh start|stop <folder>}"
need supabase
case "$CMD" in
  start)
    mkdir -p "$DIR"; [ -z "$(ls -A "$DIR")" ] || { echo "refusing: $DIR is not empty"; exit 2; }
    mkdir "$DIR/supabase"
    cat > "$DIR/supabase/config.toml" <<'EOF'
project_id = "classi-restore-check"
[api]
enabled = true
port = 55321
[db]
port = 55322
shadow_port = 55320
major_version = 17
[db.seed]
enabled = false
[studio]
enabled = false
[inbucket]
enabled = false
[realtime]
enabled = false
[storage]
enabled = true
[analytics]
enabled = false
[edge_runtime]
enabled = false
[auth]
enabled = true
EOF
    supabase start --workdir "$DIR" -x studio,imgproxy,edge-runtime,logflare,vector,supavisor,realtime > "$DIR/start.log" 2>&1 \
      || { tail -5 "$DIR/start.log" | sed -E 's/eyJ[A-Za-z0-9._-]+/[redacted]/g; s/sb_[a-z]+_[A-Za-z0-9_-]+/[redacted]/g'; echo "FAIL: the restore target did not start"; exit 1; }
    echo "postgresql://postgres:postgres@127.0.0.1:55322/postgres?sslmode=disable" ;;
  stop) supabase stop --workdir "$DIR" --no-backup >/dev/null 2>&1 || true ;;
  *) echo "usage: scratch-db.sh start|stop <folder>"; exit 2 ;;
esac
