#!/bin/sh
# Smoke test for the Dozzle image.
# Usage: IMAGE=ghcr.io/.../dozzle:11.3.0 VERSION=11.3.0 ./test.sh
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION (dozzle version, no v)}"

fail() { echo "FAIL: $1"; exit 1; }

echo "Testing dozzle reports v$VERSION..."
docker run --rm --entrypoint /usr/bin/dozzle "$IMAGE" --version 2>&1 \
  | grep -q "$VERSION" || fail "dozzle --version does not report $VERSION"

echo "Testing default entrypoint /usr/bin/dozzle + nonroot uid 65532..."
ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
[ "$ep" = "[/usr/bin/dozzle]" ] || fail "entrypoint is '$ep', expected '[/usr/bin/dozzle]'"
user=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
[ "$user" = "65532" ] || fail "run-as is '$user', expected '65532'"

echo "Testing prod restraint: busybox shell only, no bash/apk-tools..."
docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
  command -v bash >/dev/null 2>&1 && exit 1
  command -v apk  >/dev/null 2>&1 && exit 1
  exit 0' || fail "bash or apk-tools present in prod image"

echo "Testing /data exists and is writable by the daemon user..."
# dozzle's internal/profile init() mkdirs ./data (=/data) on EVERY run and
# fatals on EACCES — a non-writable /data bricks even `--version`.
docker run --rm --entrypoint /bin/sh "$IMAGE" -c \
  'test -d /data && touch /data/.w && rm /data/.w' \
  || fail "/data missing or not writable by uid 65532"

echo "Testing the server comes up on :8080 (UI + healthcheck)..."
# The server dies without a container runtime ("Could not connect to any
# Docker Engine" is fatal when TotalClients()==0), so mount the runner's own
# docker socket — and hand the process the socket's group: the nonroot uid
# 65532 cannot open the root:docker 0660 socket without it (what killed the
# first CI run). No --rm: the fail path below needs `docker logs` post-mortem.
cid=$(docker run -d -p 127.0.0.1::8080 -e DOZZLE_NO_ANALYTICS=1 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --group-add "$(stat -c %g /var/run/docker.sock)" "$IMAGE")
# shellcheck disable=SC2064
trap "docker rm -f $cid >/dev/null 2>&1 || true" EXIT
port=$(docker port "$cid" 8080/tcp | head -1 | sed 's/.*://')
i=0
until curl -fsS "http://127.0.0.1:${port}/healthcheck" >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -gt 30 ] && { docker logs "$cid"; fail "server never became healthy"; }
  sleep 1
done

echo "Testing the embedded web UI is served..."
curl -fsS "http://127.0.0.1:${port}/" | grep -qi dozzle \
  || fail "web UI index is missing or not dozzle's"

echo "Testing the in-image healthcheck subcommand..."
docker exec "$cid" /usr/bin/dozzle healthcheck >/dev/null \
  || fail "dozzle healthcheck subcommand failed"

docker rm -f "$cid" >/dev/null
trap - EXIT

echo "All dozzle tests passed!"
