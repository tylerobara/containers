#!/bin/bash
# Smoke test for the CloudNativePG-compatible Wolfi image.
# Mirrors rtvkiz/minimal images/postgres-slim/test.sh.
set -euo pipefail
: "${IMAGE:?IMAGE env var required}"

echo "Testing CNPG image tag convention (must start with PG major)..."
tag=${IMAGE##*:}
echo "$tag" | grep -qE '^18(\.[0-9]+)?([-_.]|$)' \
  || { echo "FAIL: tag '$tag' breaks CNPG major-version auto-detection"; exit 1; }

echo "Testing CNPG-required binaries on PATH..."
# Hard requirements from cloudnative-pg.github.io/docs/container_images +
# the instance manager's exec list.
for bin in initdb postgres pg_ctl pg_controldata pg_basebackup pg_rewind pg_isready psql pg_dump pg_restore; do
  docker run --rm --entrypoint "/usr/bin/$bin" "$IMAGE" --version >/dev/null \
    || { echo "FAIL: $bin missing or not runnable"; exit 1; }
done
docker run --rm --entrypoint /usr/bin/postgres "$IMAGE" --version | grep -qiE 'PostgreSQL\) 18\.' \
  || { echo "FAIL: postgres 18 version string not found"; exit 1; }

echo "Testing initdb can initialise a fresh PGDATA..."
# REGRESSION GUARD: initdb runs `"postgres" -V` via popen(), which execs /bin/sh.
# A shell-less image fails here with ENOENT, cannot initialise an empty volume,
# and so cannot bootstrap a CNPG cluster on first run. This is why prod carries busybox.
docker run --rm --tmpfs /pgtest:uid=26,gid=26,mode=0700 \
  --entrypoint /usr/bin/initdb "$IMAGE" -D /pgtest -U postgres --auth=trust 2>&1 \
  | grep -qi 'Success' \
  || { echo "FAIL: initdb could not initialise a data dir (missing /bin/sh?)"; exit 1; }

echo "Testing PostgreSQL starts and serves queries..."
docker rm -f cnpg-test >/dev/null 2>&1 || true
cid=$(docker run -d --name cnpg-test \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  --entrypoint /bin/sh "$IMAGE" \
  -c 'initdb -D "$PGDATA" -U postgres --auth=trust && exec postgres -D "$PGDATA" -h 0.0.0.0')
trap 'docker rm -f cnpg-test >/dev/null 2>&1 || true' EXIT

ready=0
for _ in $(seq 1 30); do
  if docker exec "$cid" pg_isready -q -U postgres >/dev/null 2>&1; then ready=1; break; fi
  if [ -z "$(docker ps -q --filter id="$cid")" ]; then break; fi
  sleep 1
done
[ "$ready" = 1 ] || { echo "FAIL: postgres did not become ready"; docker logs "$cid" 2>&1 | tail -20; exit 1; }

out=$(docker exec "$cid" psql -U postgres -tAc 'SELECT 1;' 2>/dev/null | tr -d '[:space:]')
[ "$out" = "1" ] || { echo "FAIL: query returned '${out:-<none>}', expected 1"; docker logs "$cid" 2>&1 | tail -20; exit 1; }
echo "SELECT 1 -> $out (server accepted a real query)"

echo "Verifying CNPG uid (26, not 70)..."
# NOTE: unlike postgres-slim's uid 70, CNPG runs its instances as uid/gid 26 —
# the operator sets that security context and its images usermod postgres to 26.
uid=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
[ "$uid" = "26" ] || { echo "FAIL: expected uid 26 (CNPG postgres), got '$uid'"; exit 1; }

echo "Verifying prod restraint: busybox shell only, no bash/apk-tools..."
docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'echo shell-ok' 2>/dev/null | grep -q shell-ok \
  || { echo "FAIL: /bin/sh missing — initdb will break"; exit 1; }
for forbidden in /bin/bash /usr/bin/bash /sbin/apk /usr/bin/apk; do
  docker run --rm --entrypoint "$forbidden" "$IMAGE" --version >/dev/null 2>&1 \
    && { echo "FAIL: $forbidden present in prod image"; exit 1; }
done
echo "busybox sh only (as expected)"

echo "Verifying busybox applets CNPG shells out to..."
docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'du --version >/dev/null 2>&1 || du -sh /tmp >/dev/null' \
  || { echo "FAIL: du missing (kubectl cnpg status needs it)"; exit 1; }

echo "All cloudnative-pg tests passed!"
