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

echo "Testing the server comes up on :8080 (UI + healthcheck)..."
# The server dies without a container runtime ("Could not connect to any
# Docker Engine"), so mount the runner's own docker socket.
cid=$(docker run -d --rm -p 127.0.0.1::8080 \
  -v /var/run/docker.sock:/var/run/docker.sock "$IMAGE")
# shellcheck disable=SC2064
trap "docker stop $cid >/dev/null 2>&1 || true" EXIT
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

docker stop "$cid" >/dev/null
trap - EXIT

echo "All dozzle tests passed!"
