#!/bin/sh
# Smoke test for the Web-Check image.
# Usage: IMAGE=ghcr.io/.../web-check:2.3.11 VERSION=2.3.11 ./test.sh
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION (web-check version, no v)}"

fail() { echo "FAIL: $1"; exit 1; }

echo "Testing shipped app reports v$VERSION..."
docker run --rm --entrypoint /bin/cat "$IMAGE" /app/package.json \
  | grep -q "$VERSION" || fail "package.json does not report $VERSION"

echo "Testing app tree (server, healthcheck, dist, api, public, node_modules)..."
docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
  test -f /app/server.js && test -f /app/healthcheck.js \
  && test -f /app/package.json && [ ! -e /app/yarn.lock ] \
  && test -f /app/dist/server/entry.mjs \
  && test -n "$(ls -A /app/dist/client)" \
  && test -n "$(ls -A /app/api)" && test -n "$(ls -A /app/public)" \
  && test -d /app/node_modules' \
  || fail "/app tree incomplete (or yarn.lock shipped — lockfile cataloger risk)"

echo "Testing node v24 runtime + ESM sources parse..."
docker run --rm --entrypoint /usr/bin/node "$IMAGE" --version | grep -q '^v24\.' \
  || fail "node is not a v24 runtime"
docker run --rm --entrypoint /bin/sh "$IMAGE" -c \
  'node --input-type=module --check < /app/server.js \
   && node --input-type=module --check < /app/healthcheck.js' \
  || fail "server.js or healthcheck.js does not parse as ESM"

echo "Testing deps-stage purity (no dev toolchain, no browser binaries)..."
docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
  [ ! -e /app/node_modules/nodemon ] \
  && ! find /app/node_modules -maxdepth 3 \( -name chrome -o -name headless_shell \) 2>/dev/null | grep -q .' \
  || fail "dev toolchain or browser binary leaked into the prod tree"

echo "Testing default wiring: nonroot 65532, /entrypoint.sh, prod restraint..."
uid=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
[ "$uid" = "65532" ] || fail "run-as is '$uid', expected '65532'"
ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
[ "$ep" = "[/entrypoint.sh]" ] || fail "entrypoint is '$ep', expected '[/entrypoint.sh]'"
docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
  command -v apk  >/dev/null 2>&1 && exit 1
  command -v npm  >/dev/null 2>&1 && exit 2
  command -v yarn >/dev/null 2>&1 && exit 3
  command -v dumb-init >/dev/null || exit 4
  exit 0' || fail "apk/npm/yarn present or dumb-init missing in prod image"

echo "Testing nonroot boot: /healthz ready, GUI serves 200..."
cid=$(docker run -d --rm -p 127.0.0.1::3000 "$IMAGE")
# shellcheck disable=SC2064
trap "docker stop $cid >/dev/null 2>&1 || true" EXIT
port=$(docker port "$cid" 3000/tcp | head -1 | sed 's/.*://')
i=0
until curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -gt 60 ] && { docker logs "$cid"; fail "server never came up on :3000"; }
  sleep 1
done
# routes register async, so the app's own healthcheck.js gates on `ready`
# (every /api handler live) — mirror that gate, not just the TCP listener.
i=0
until curl -fsS "http://127.0.0.1:$port/healthz" | grep -q '"ready":true'; do
  i=$((i + 1))
  [ "$i" -gt 30 ] && { docker logs "$cid"; fail "/healthz never reported ready:true"; }
  sleep 1
done
# / is a 302 into the astro client shell — follow it, the contract is a 200.
[ "$(curl -sL -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/")" = "200" ] \
  || fail "GUI did not answer 200 (after redirects)"
docker stop "$cid" >/dev/null; trap - EXIT

echo "All web-check tests passed!"
