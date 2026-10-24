#!/bin/sh
# Smoke test for the Traefik image.
# Usage: IMAGE=ghcr.io/.../traefik:3.7.14 VERSION=3.7.14 ./test.sh
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION (traefik version, no v)}"

fail() { echo "FAIL: $1"; exit 1; }

echo "Testing traefik reports v$VERSION..."
docker run --rm --entrypoint /usr/bin/traefik "$IMAGE" version 2>&1 \
  | grep -q "v$VERSION" || fail "traefik version does not report v$VERSION"

echo "Testing default entrypoint is /usr/bin/traefik..."
ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
[ "$ep" = "[/usr/bin/traefik]" ] || fail "entrypoint is '$ep', expected '[/usr/bin/traefik]'"

echo "Testing nonroot uid 65532..."
uid=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
[ "$uid" = "65532" ] || fail "run-as is '$uid', expected '65532'"

echo "Testing prod restraint: busybox shell only, no bash/apk-tools..."
docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
  command -v bash >/dev/null 2>&1 && exit 1
  command -v apk  >/dev/null 2>&1 && exit 1
  exit 0' || fail "bash or apk-tools present in prod image"

echo "Testing provider-less boot with --ping (/ping on :8080)..."
# Same as the minilab ingress posture (no k8s provider needed for this):
# traefik always registers its internal provider, so it starts and serves
# ping/api without any external provider configured.
cid=$(docker run -d --rm -p 127.0.0.1::8080 "$IMAGE" \
  --entrypoints.web.address=:80 --ping --api.dashboard=false)
# shellcheck disable=SC2064
trap "docker stop $cid >/dev/null 2>&1 || true" EXIT
port=$(docker port "$cid" 8080/tcp | head -1 | sed 's/.*://')
i=0
until curl -fsS --max-time 5 "http://127.0.0.1:${port}/ping" 2>/dev/null | grep -q OK; do
  i=$((i + 1))
  [ "$i" -gt 30 ] && { docker logs "$cid" 2>&1 || true; fail "ping endpoint never came up"; }
  sleep 1
done
docker stop "$cid" >/dev/null
trap - EXIT

echo "All traefik tests passed!"
