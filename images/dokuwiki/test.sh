#!/bin/sh
# Smoke test for the DokuWiki image.
# Usage: IMAGE=ghcr.io/.../dokuwiki:2026.07.14c VERSION=2026.07.14c ./test.sh
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION (dokuwiki apk form, e.g. 2026.07.14c)}"

fail() { echo "FAIL: $1"; exit 1; }
VDASH=$(printf '%s' "$VERSION" | tr '.' '-')

echo "Testing shipped release matches $VDASH..."
docker run --rm --entrypoint /bin/cat "$IMAGE" /var/www/html/VERSION \
  | grep -q "$VDASH" || fail "VERSION file does not contain $VDASH"

echo "Testing required PHP extensions load..."
mods=$(docker run --rm --entrypoint /usr/bin/php "$IMAGE" -m 2>/dev/null)
for m in gd bz2 intl ldap pdo_sqlite zlib json session "Zend OPcache"; do
  printf '%s\n' "$mods" | grep -qix "$m" || fail "php extension '$m' missing"
done

echo "Testing default wiring: nonroot 33, /entrypoint.sh, no apk-tools..."
uid=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
[ "$uid" = "33" ] || fail "run-as is '$uid', expected '33'"
ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
[ "$ep" = "[/entrypoint.sh]" ] || fail "entrypoint is '$ep', expected '[/entrypoint.sh]'"
docker run --rm --entrypoint /bin/sh "$IMAGE" -c \
  'command -v apk >/dev/null 2>&1 && exit 1; exit 0' \
  || fail "apk-tools present in prod image"

wait_up() { # wait_up <cid> — poll until the wiki answers
  i=0
  until curl -fsS "http://127.0.0.1:$(docker port "$1" 8080/tcp | head -1 | sed 's/.*://')" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -gt 40 ] && { docker logs "$1"; fail "wiki never came up on :8080"; }
    sleep 1
  done
}
hit() { curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1$2"; }

echo "Testing nonroot boot (image default): pages, rewrite, static, health..."
cid=$(docker run -d --rm -p 127.0.0.1::8080 "$IMAGE")
# shellcheck disable=SC2064
trap "docker stop $cid >/dev/null 2>&1 || true" EXIT
wait_up "$cid"
port=$(docker port "$cid" 8080/tcp | head -1 | sed 's/.*://')
home=$(curl -s "http://127.0.0.1:$port/")
echo "$home" | grep -q DokuWiki || fail "homepage has no DokuWiki markup"
[ "$(hit "$port" /Start)" = "200" ] || fail "pretty URL /Start not rewritten to doku.php"
[ "$(hit "$port" /lib/tpl/dokuwiki/css/_diff.css)" = "200" ] || fail "static css via /storage/lib/tpl symlink not served"
curl -s "http://127.0.0.1:$port/health.php" | grep -q ok || fail "health.php did not answer ok"
[ "$(hit "$port" /VERSION)" = "403" ] || fail "/VERSION not denied"
[ "$(hit "$port" /conf.core/dokuwiki.php)" = "403" ] || fail "/conf.core not denied"
docker exec "$cid" /bin/sh -c 'test -L /var/www/html/data && test -d /storage/data/pages' \
  || fail "/storage not seeded from data.core"
# busybox tail -F polls on an interval; give the forwarder time to catch up
i=0
until docker logs "$cid" 2>&1 | grep -q 'GET / '; do
  i=$((i + 1))
  [ "$i" -gt 10 ] && fail "access log not forwarded to container stdout"
  sleep 1
done
docker stop "$cid" >/dev/null; trap - EXIT

echo "Testing root boot: auto-chown /storage, master root + workers www-data..."
cid=$(docker run -d --rm -p 127.0.0.1::8080 --user 0 \
  -v "$(mktemp -d):/storage" "$IMAGE")
# shellcheck disable=SC2064
trap "docker stop $cid >/dev/null 2>&1 || true" EXIT
wait_up "$cid"
docker logs "$cid" 2>&1 | grep -q 'Running as root' || fail "root mode banner missing"
curl -s "http://127.0.0.1:$(docker port "$cid" 8080/tcp | head -1 | sed 's/.*://')/health.php" \
  | grep -q ok || fail "health.php did not answer ok under root"
users=$(docker exec "$cid" /bin/sh -c 'ps -o user= | sort -u | tr "\n" " "')
[ "$users" = "root www-data " ] || fail "root-mode process owners are '$users', expected 'root www-data '"
docker stop "$cid" >/dev/null; trap - EXIT

echo "All dokuwiki tests passed!"
