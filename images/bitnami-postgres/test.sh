#!/bin/bash
# Smoke test for the Bitnami-compatible Wolfi image.
# Usage: IMAGE=<ref> [PG_MAJOR=18] ./test.sh
# All boots run as --user 1001 (the bitnami chart's runAsUser); the contract
# mirrors bitnami/containers bitnami/postgresql legacy tags (see README.md).
set -euo pipefail
: "${IMAGE:?IMAGE env var required}"
: "${PG_MAJOR:=18}"

echo "Testing tag convention (must start with PG major $PG_MAJOR)..."
tag=${IMAGE##*:}
echo "$tag" | grep -qE "^$PG_MAJOR(\.[0-9]+)?([-_.]|$)" \
  || { echo "FAIL: tag '$tag' does not start with $PG_MAJOR"; exit 1; }

echo "Testing Bitnami filetree + entrypoint bits..."
docker run --rm --user 1001 --entrypoint /bin/sh "$IMAGE" -c '
  for d in /opt/bitnami/postgresql/bin /opt/bitnami/postgresql/lib \
           /opt/bitnami/postgresql/conf /opt/bitnami/postgresql/conf.default \
           /opt/bitnami/postgresql/logs /opt/bitnami/postgresql/tmp \
           /opt/bitnami/scripts/postgresql /bitnami/postgresql \
           /docker-entrypoint-initdb.d /docker-entrypoint-preinitdb.d; do
    test -d "$d" || { echo "missing dir $d"; exit 1; }
  done
  for x in /opt/bitnami/scripts/postgresql/entrypoint.sh \
           /opt/bitnami/scripts/postgresql/setup.sh \
           /opt/bitnami/scripts/postgresql/run.sh \
           /usr/sbin/run-script /opt/bitnami/common/bin/hostname; do
    test -x "$x" || { echo "missing exec $x"; exit 1; }
  done
  test -f /opt/bitnami/postgresql/conf.default/postgresql.conf || exit 1
  test -f /opt/bitnami/postgresql/conf.default/pg_hba.conf || exit 1
  grep -q include_dir /opt/bitnami/postgresql/conf.default/postgresql.conf
  test -L /opt/bitnami/postgresql/logs/postgresql.log
' || { echo "FAIL: filetree contract broken"; exit 1; }

echo "Testing binaries resolve to the /opt prefix (bitnami layout)..."
docker run --rm --user 1001 --entrypoint /bin/sh "$IMAGE" -c '
  [ "$(command -v initdb)" = /opt/bitnami/postgresql/bin/initdb ]
  [ "$(command -v psql)" = /opt/bitnami/postgresql/bin/psql ]
  command -v hostname >/dev/null   # the common/bin shim wins
' || { echo "FAIL: PATH does not resolve to /opt/bitnami/postgresql/bin"; exit 1; }

echo "Verifying prod restraint: uid 1001, bash present, no apk..."
uid=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
[ "$uid" = "1001" ] || { echo "FAIL: expected uid 1001 (bitnami postgres), got '$uid'"; exit 1; }
cmd=$(docker inspect --format '{{join .Config.Entrypoint " "}}|{{join .Config.Cmd " "}}' "$IMAGE")
[ "$cmd" = "/opt/bitnami/scripts/postgresql/entrypoint.sh|/opt/bitnami/scripts/postgresql/run.sh" ] \
  || { echo "FAIL: ENTRYPOINT/CMD not the bitnami pair: $cmd"; exit 1; }
docker run --rm --entrypoint /bin/bash "$IMAGE" -c 'echo bash-ok' | grep -q bash-ok \
  || { echo "FAIL: bash missing (bitnami libs are bash)"; exit 1; }
docker run --rm --entrypoint /sbin/apk "$IMAGE" --version >/dev/null 2>&1 \
  && { echo "FAIL: apk-tools present in prod image"; exit 1; }

echo "Testing first boot: user+db creation + initdb.d scripts + pgaudit..."
docker rm -f bp-test >/dev/null 2>&1 || true
initdir=$(mktemp -d)
cat > "$initdir/001_seed.sql" <<'SQL'
CREATE TABLE smoke (id int);
INSERT INTO smoke VALUES (1);
SQL
cat > "$initdir/002_marker.sh" <<'SH'
#!/bin/bash
touch /tmp/init-sh-ran
SH
chmod 755 "$initdir/002_marker.sh"
trap 'docker rm -f bp-test >/dev/null 2>&1 || true; rm -rf "$initdir"' EXIT

# Default ENTRYPOINT+CMD (entrypoint.sh → setup.sh → run.sh), non-root,
# tmpfs volume owned by 1001 (what the chart's fsGroup achieves on a PVC).
cid=$(docker run -d --name bp-test --user 1001 \
  --tmpfs /bitnami/postgresql:uid=1001,gid=1001,mode=0775 \
  -v "$initdir:/docker-entrypoint-initdb.d:ro" \
  -e POSTGRES_USER=appuser \
  -e POSTGRES_PASSWORD=Test-Apppass-1 \
  -e POSTGRES_DB=appdb \
  -e POSTGRES_POSTGRES_PASSWORD=Test-Superpass-1 \
  "$IMAGE")

ready=0
for _ in $(seq 1 90); do
  if docker exec "$cid" pg_isready -q -U postgres >/dev/null 2>&1; then ready=1; break; fi
  [ -z "$(docker ps -q --filter id="$cid")" ] && break
  sleep 2
done
[ "$ready" = 1 ] || { echo "FAIL: entrypoint boot did not reach ready"; docker logs "$cid" 2>&1 | tail -30; exit 1; }

out=$(docker exec "$cid" psql -U postgres -tAc 'SELECT 1;' 2>/dev/null | tr -d '[:space:]')
[ "$out" = "1" ] || { echo "FAIL: SELECT 1 -> '${out:-<none>}'"; docker logs "$cid" 2>&1 | tail -30; exit 1; }

out=$(docker exec "$cid" psql -U postgres -tAc \
  "SELECT rolname FROM pg_roles WHERE rolname='appuser';" 2>/dev/null | tr -d '[:space:]')
[ "$out" = "appuser" ] || { echo "FAIL: POSTGRES_USER appuser not created ('$out')"; exit 1; }
out=$(docker exec "$cid" psql -U postgres -tAc \
  "SELECT datname FROM pg_database WHERE datname='appdb';" 2>/dev/null | tr -d '[:space:]')
[ "$out" = "appdb" ] || { echo "FAIL: POSTGRES_DB appdb not created ('$out')"; exit 1; }

# .sql ran via the initscripts user; .sh ran executable-bit path.
out=$(docker exec "$cid" psql -U postgres -d appdb -tAc 'SELECT count(*) FROM smoke;' 2>/dev/null | tr -d '[:space:]')
[ "$out" = "1" ] || { echo "FAIL: 001_seed.sql did not run ('$out')"; exit 1; }
docker exec "$cid" test -f /tmp/init-sh-ran \
  || { echo "FAIL: executable 002_marker.sh did not run"; exit 1; }

# scripts default SHARED_PRELOAD_LIBRARIES=pgaudit + wal_level=replica (chart
# replication relies on it) — proves the /opt-bundled pgaudit preloads.
out=$(docker exec "$cid" psql -U postgres -tAc \
  "SELECT setting FROM pg_settings WHERE name='shared_preload_libraries';" 2>/dev/null)
echo "$out" | grep -q pgaudit || { echo "FAIL: shared_preload_libraries='$out' (want pgaudit)"; exit 1; }
out=$(docker exec "$cid" psql -U postgres -tAc \
  "SELECT setting FROM pg_settings WHERE name='wal_level';" 2>/dev/null | tr -d '[:space:]')
[ "$out" = "replica" ] || { echo "FAIL: wal_level='$out' (chart replication needs replica)"; exit 1; }

# extension files landed in the /opt server's share/extension (repmgr package).
docker exec "$cid" psql -U postgres -d appdb -qc 'CREATE EXTENSION repmgr;' \
  || { echo "FAIL: CREATE EXTENSION repmgr failed (extension files misplaced?)"; exit 1; }

echo "Testing repmgr compatibility package..."
docker run --rm --user 1001 --entrypoint /opt/bitnami/repmgr/bin/repmgr "$IMAGE" --version \
  | grep -q 'repmgr' || { echo "FAIL: repmgr --version"; exit 1; }

echo "Testing ALLOW_EMPTY_PASSWORD boot (bitnami dev contract)..."
docker rm -f bp-test-empty >/dev/null 2>&1 || true
cid=$(docker run -d --name bp-test-empty --user 1001 \
  --tmpfs /bitnami/postgresql:uid=1001,gid=1001,mode=0775 \
  -e ALLOW_EMPTY_PASSWORD=yes \
  "$IMAGE")
trap 'docker rm -f bp-test bp-test-empty >/dev/null 2>&1 || true; rm -rf "$initdir"' EXIT
ready=0
for _ in $(seq 1 90); do
  if docker exec "$cid" pg_isready -q -U postgres >/dev/null 2>&1; then ready=1; break; fi
  [ -z "$(docker ps -q --filter id="$cid")" ] && break
  sleep 2
done
[ "$ready" = 1 ] || { echo "FAIL: ALLOW_EMPTY_PASSWORD boot"; docker logs "$cid" 2>&1 | tail -30; exit 1; }

echo "All bitnami-postgres tests passed!"
