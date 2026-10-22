#!/bin/sh
# Smoke test for the OpenBao image.
# Usage: IMAGE=ghcr.io/.../openbao:2.7.1 VERSION=2.7.1 ./test.sh
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION (openbao version, no v)}"

fail() { echo "FAIL: $1"; exit 1; }

echo "Testing bao reports v$VERSION..."
docker run --rm --entrypoint /usr/bin/bao "$IMAGE" version 2>&1 \
  | grep -q "$VERSION" || fail "bao version does not report $VERSION"

echo "Testing default entrypoint is 'bao server'..."
ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
[ "$ep" = "[/usr/bin/bao]" ] || fail "entrypoint is '$ep', expected '[/usr/bin/bao]'"
cmd=$(docker inspect --format '{{.Config.Cmd}}' "$IMAGE")
[ "$cmd" = "[server]" ] || fail "default args are '$cmd', expected '[server]'"

echo "Testing nonroot uid 65532 + vault compat symlink..."
uid=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
[ "$uid" = "65532" ] || fail "run-as is '$uid', expected '65532'"
docker run --rm --entrypoint /bin/sh "$IMAGE" -c \
  'test -x /usr/bin/vault && test ! -d /usr/bin/vault' \
  || fail "/usr/bin/vault compat symlink missing"

echo "Testing prod restraint: busybox shell only, no bash/apk-tools..."
docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
  command -v bash >/dev/null 2>&1 && exit 1
  command -v apk  >/dev/null 2>&1 && exit 1
  exit 0' || fail "bash or apk-tools present in prod image"

echo "Testing the official chart's server path (bundled docker-entrypoint.sh)..."
# openbao-helm hardcodes /usr/local/bin/docker-entrypoint.sh in the server
# command; running it with "bao version" exercises the shebang (dumb-init),
# the script's bao branch, su-exec and the /openbao dirs in one shot.
docker run --rm --entrypoint /bin/sh "$IMAGE" -ec '
  command -v dumb-init >/dev/null || exit 1
  command -v su-exec  >/dev/null || exit 2
  test -x /usr/local/bin/docker-entrypoint.sh || exit 3
  for d in config logs file data; do test -d "/openbao/$d" || exit 4; done
  /usr/local/bin/docker-entrypoint.sh bao version >/dev/null || exit 5' \
  || fail "chart server path broken (docker-entrypoint.sh, dumb-init/su-exec or /openbao dirs)"

echo "Testing dev server actually comes up (healthz on :8200)..."
cid=$(docker run -d --rm -p 127.0.0.1::8200 "$IMAGE" \
  server -dev -dev-no-store-token \
  -dev-listen-address=0.0.0.0:8200)
# shellcheck disable=SC2064
trap "docker stop $cid >/dev/null 2>&1 || true" EXIT
port=$(docker port "$cid" 8200/tcp | head -1 | sed 's/.*://')
i=0
until curl -fsS "http://127.0.0.1:${port}/v1/sys/health" >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -gt 30 ] && { docker logs "$cid"; fail "dev server never became healthy"; }
  sleep 1
done
docker stop "$cid" >/dev/null
trap - EXIT

echo "All openbao tests passed!"
