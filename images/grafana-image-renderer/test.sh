#!/bin/sh
# Smoke test for the grafana-image-renderer image.
# Usage: IMAGE=ghcr.io/.../grafana-image-renderer:5.12.8 VERSION=5.12.8 ./test.sh
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION (grafana-image-renderer version, no v)}"

fail() { echo "FAIL: $1"; exit 1; }

echo "Testing binary reports v$VERSION..."
docker run --rm --entrypoint /usr/bin/grafana-image-renderer "$IMAGE" --version 2>&1 \
  | grep -q "version $VERSION " || fail "--version does not report $VERSION"

echo "Testing default entrypoint is 'tini -- grafana-image-renderer server'..."
ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
[ "$ep" = "[/usr/local/bin/docker-entrypoint.sh]" ] \
  || fail "entrypoint is '$ep', expected '[/usr/local/bin/docker-entrypoint.sh]'"
cmd=$(docker inspect --format '{{.Config.Cmd}}' "$IMAGE")
[ "$cmd" = "[server]" ] || fail "default args are '$cmd', expected '[server]'"

echo "Testing nonroot uid 65532 + chromium + tini present..."
uid=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
[ "$uid" = "65532" ] || fail "run-as is '$uid', expected '65532'"
docker run --rm --entrypoint /bin/sh "$IMAGE" -c \
  'command -v chromium >/dev/null || exit 1
   command -v tini     >/dev/null || exit 2
   fc-list | grep -qi dejavu || exit 3' \
  || fail "chromium, tini or fonts missing"

echo "Testing prod restraint: busybox shell only, no bash/apk-tools..."
docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
  command -v bash >/dev/null 2>&1 && exit 1
  command -v apk  >/dev/null 2>&1 && exit 1
  exit 0' || fail "bash or apk-tools present in prod image"

echo "Testing server boot, /healthz, token auth and a real PNG render..."
TOKEN=testtoken-$$
cid=$(docker run -d --rm -p 127.0.0.1::8081 "$IMAGE" \
  server --server.auth-token="$TOKEN")
# shellcheck disable=SC2064
trap "docker stop $cid >/dev/null 2>&1 || true" EXIT
port=$(docker port "$cid" 8081/tcp | head -1 | sed 's/.*://')
i=0
until curl -fsS "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -gt 60 ] && { docker logs "$cid"; fail "server never became healthy"; }
  sleep 1
done

echo "Testing the bundled healthcheck subcommand..."
docker exec "$cid" /usr/bin/grafana-image-renderer healthcheck \
  || fail "healthcheck subcommand failed against the running server"

echo "Testing /render requires X-Auth-Token..."
code=$(curl -s -o /dev/null -w '%{http_code}' \
  "http://127.0.0.1:${port}/render?url=https://example.com&width=100&height=100")
[ "$code" = "401" ] || fail "unauthenticated /render returned $code, expected 401"

echo "Testing E2E render returns a real PNG..."
# the SSRF middleware rejects non-http(s) query urls, so serve the fixture
# from a busybox sidecar on a shared network (data: URLs 403 by design)
docker network create girtest >/dev/null
docker network connect girtest "$cid"
# shellcheck disable=SC2064
trap "docker rm -f gir-web >/dev/null 2>&1 || true; docker network rm girtest >/dev/null 2>&1 || true; docker stop $cid >/dev/null 2>&1 || true" EXIT
docker run -d --rm --name gir-web --network girtest busybox:latest \
  sh -c 'echo "<html><body><h1>EOG</h1></body></html>" > /t.html && \
         exec httpd -f -p 8090 -h /' >/dev/null
curl -fsS -H "X-Auth-Token: $TOKEN" \
  "http://127.0.0.1:${port}/render?url=http://gir-web:8090/t.html&width=320&height=100&encoding=png" \
  -o /tmp/gir-test.png || { docker logs "$cid"; docker logs gir-web; fail "authenticated /render failed"; }
magic=$(od -An -tx1 -N8 /tmp/gir-test.png | tr -d ' \n')
[ "$magic" = "89504e470d0a1a0a" ] \
  || { docker logs "$cid"; fail "render did not return a PNG (magic '$magic')"; }

docker stop "$cid" >/dev/null
docker rm -f gir-web >/dev/null 2>&1 || true
docker network rm girtest >/dev/null 2>&1 || true
trap - EXIT

echo "All grafana-image-renderer tests passed!"
