#!/bin/sh
# Smoke test for the Homepage image.
# Usage: IMAGE=ghcr.io/.../homepage:2.6.0 VERSION=2.6.0 ./test.sh
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION (homepage version, no v)}"

fail() { echo "FAIL: $1"; exit 1; }

echo "Testing shipped app reports v$VERSION..."
docker run --rm --entrypoint /bin/cat "$IMAGE" /app/package.json \
  | grep -q "$VERSION" || fail "package.json does not report $VERSION"

echo "Testing app tree (standalone server, static, public, skeleton)..."
docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
  test -f /app/server.js && test -f /app/package.json \
  && test -d /app/node_modules \
  && test -n "$(ls -A /app/.next/static)" \
  && test -f /app/public/favicon-16x16.png \
  && test -f /app/src/skeleton/settings.yaml' \
  || fail "/app tree incomplete (server.js / .next/static / public / src/skeleton)"

echo "Testing node v24 runtime + server.js parses..."
docker run --rm --entrypoint /usr/bin/node "$IMAGE" --version | grep -q '^v24\.' \
  || fail "node is not a v24 runtime"
docker run --rm --entrypoint /usr/bin/node "$IMAGE" --check /app/server.js \
  || fail "server.js does not parse"

echo "Testing client build stamps (real BUILD_ID, ISO build time, stamped version)..."
docker run --rm --entrypoint /bin/sh "$IMAGE" -c \
  'grep -qE "^[A-Za-z0-9_-]{8,}$" /app/.next/BUILD_ID' \
  || fail "/app/.next/BUILD_ID is missing or a placeholder"
# shellcheck disable=SC2016
docker run --rm --entrypoint /usr/bin/node -e "V=$VERSION" "$IMAGE" -e '
  const fs = require("fs"), path = require("path");
  const files = [];
  (function walk(d) { for (const f of fs.readdirSync(d)) { const p = path.join(d, f); fs.statSync(p).isDirectory() ? walk(p) : files.push(p); } })("/app/.next/static/chunks");
  const src = files.map((f) => fs.readFileSync(f, "utf8")).join("");
  const m = src.match(/"(20[2-3]\d-\d{2}-\d{2}T[\d:.]+Z)"/); // year window skips a 2006 date fixture other chunks carry
  if (!m) throw new Error("no ISO NEXT_PUBLIC_BUILDTIME baked into the client chunks");
  new Intl.DateTimeFormat("en").format(new Date(m[1])); // the exact call the version footer makes
  if (!src.includes(`"v${process.env.V}"`)) throw new Error("NEXT_PUBLIC_VERSION v" + process.env.V + " not baked into the client chunks");
  if (/"1\d{9}"/.test(src)) throw new Error("epoch-seconds build time baked into the client chunks (crashes the version footer)");
  ' || fail "client chunks lack baked build stamps (NEXT_PUBLIC_* env)"

echo "Testing default wiring: nonroot 65532, /entrypoint.sh, prod restraint..."
uid=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
[ "$uid" = "65532" ] || fail "run-as is '$uid', expected '65532'"
ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
[ "$ep" = "[/entrypoint.sh]" ] || fail "entrypoint is '$ep', expected '[/entrypoint.sh]'"
docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
  command -v apk  >/dev/null 2>&1 && exit 1
  command -v npm  >/dev/null 2>&1 && exit 2
  command -v dumb-init >/dev/null || exit 3
  command -v su-exec   >/dev/null || exit 4
  exit 0' || fail "apk/npm present or dumb-init/su-exec missing in prod image"

wait_up() { # wait_up <cid> <port> — poll until the dashboard answers
  i=0
  until curl -fsS "http://127.0.0.1:$2/api/healthcheck" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -gt 60 ] && { docker logs "$1"; fail "server never came up on :3000"; }
    sleep 1
  done
}

# HOMEPAGE_ALLOWED_HOSTS=* because the published port != PORT, so the Host
# header (127.0.0.1:<mapped>) would trip the app's upstream host validation.
# docker may also override HOSTNAME with the container id — the app binds
# whatever it is via /etc/hosts, as upstream; the probe stays deterministic.
boot() { # boot [extra docker args...] — starts the container, echoes cid
  cid=$(docker run -d --rm -p 127.0.0.1::3000 \
    -e HOMEPAGE_ALLOWED_HOSTS='*' "$@" "$IMAGE")
  # shellcheck disable=SC2064
  trap "docker stop $cid >/dev/null 2>&1 || true" EXIT
  port=$(docker port "$cid" 3000/tcp | head -1 | sed 's/.*://')
  wait_up "$cid" "$port"
}

echo "Testing nonroot boot (image default): healthcheck, home, static, self-seeded config..."
boot
[ "$(curl -s "http://127.0.0.1:$port/api/healthcheck")" = "up" ] \
  || fail "healthcheck did not answer 'up'"
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/")" = "200" ] \
  || fail "dashboard did not answer 200"
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/favicon-16x16.png")" = "200" ] \
  || fail "public/favicon-16x16.png not served"
docker exec "$cid" /bin/sh -c 'test -f /app/config/settings.yaml && test -d /app/config/logs' \
  || fail "config/settings.yaml not self-seeded from the skeleton"
i=0
until docker exec "$cid" test -f /app/config/logs/homepage.log; do
  i=$((i + 1))
  [ "$i" -gt 10 ] && fail "winston file log never appeared under /app/config/logs"
  sleep 1
done
docker stop "$cid" >/dev/null; trap - EXIT

echo "Testing root boot: PUID/PGID chown + su-exec drop..."
boot --user 0 -e PUID=65532 -e PGID=65532 -v "$(mktemp -d):/app/config"
[ "$(curl -s "http://127.0.0.1:$port/api/healthcheck")" = "up" ] \
  || fail "healthcheck did not answer 'up' under root+PUID"
users=$(docker exec "$cid" /bin/sh -c 'ps -o user= | sort -u | tr "\n" " "')
[ "$users" = "homepage root " ] || fail "root-mode process owners are '$users', expected 'homepage root '"
docker exec "$cid" /bin/sh -c 'test -f /app/config/settings.yaml' \
  || fail "skeleton not seeded into the mounted /app/config under root+PUID"
docker stop "$cid" >/dev/null; trap - EXIT

echo "All homepage tests passed!"
