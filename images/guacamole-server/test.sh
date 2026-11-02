#!/bin/sh
# Smoke test for the guacamole-server (guacd) image.
# Usage: IMAGE=ghcr.io/.../guacamole-server:1.6.0 VERSION=1.6.0 ./test.sh
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION (guacamole-server version, no v)}"

fail() { echo "FAIL: $1"; exit 1; }

echo "Testing default entrypoint is 'tini -- docker-entrypoint.sh' with empty CMD (upstream contract)..."
ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
[ "$ep" = "[/sbin/tini -- /usr/bin/docker-entrypoint.sh]" ] \
  || fail "entrypoint is '$ep', expected '[/sbin/tini -- /usr/bin/docker-entrypoint.sh]'"
cmd=$(docker inspect --format '{{.Config.Cmd}}' "$IMAGE")
[ -z "$cmd" ] || [ "$cmd" = "[]" ] || fail "default args are '$cmd', expected empty"

echo "Testing guacd(1000) run-as + accounts + fonts + shipped tools..."
user=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
[ "$user" = "guacd" ] || [ "$user" = "1000" ] \
  || fail "run-as is '$user', expected guacd/1000"
docker run --rm --entrypoint /bin/sh "$IMAGE" -ec '
  grep -q "^guacd:[^:]*:1000:1000:" /etc/passwd || exit 1
  grep -q "^guacd:[^:]*:1000:" /etc/group || exit 2
  test -x /usr/sbin/guacd || exit 3
  test -x /usr/bin/guacenc || exit 4
  test -x /usr/bin/docker-entrypoint.sh || exit 5
  for f in rdp ssh telnet vnc kubernetes; do test -e /usr/lib/libguac-client-$f.so || exit 6; done
  find /usr/share/fonts \( -name "*.ttf" -o -name "*.otf" -o -name "*.ttc" \) | grep -q . || exit 7' \
  || fail "guacd accounts, protocol plugins, tools or fonts missing"

echo "Testing guacd reports v$VERSION (no version drift, ffmpeg-linked guacenc present)..."
# -v, not --version: 1.6.0's getopt string (l:b:p:L:C:K:fv) has no long options.
v=$(docker run --rm --entrypoint /usr/sbin/guacd "$IMAGE" -v)
echo "$v"
echo "$v" | grep -q "version $VERSION" || fail "guacd -v is not $VERSION: $v"

echo "Testing the daemon boots under the default entrypoint and accepts connections on 4822..."
cid=$(docker run -d --rm "$IMAGE")
# shellcheck disable=SC2064
trap "docker stop $cid >/dev/null 2>&1 || true" EXIT
i=0
until docker exec "$cid" nc -z 127.0.0.1 4822; do
  i=$((i + 1))
  [ "$i" -gt 30 ] && { docker logs "$cid" || true; fail "guacd never listened on 4822"; }
  sleep 1
done

echo "Testing extra args pass through the entrypoint to the guacd command line..."
# Upstream contract: `docker run <img> <args>` appends to guacd's own options.
# -L debug must not break the boot (and proves guacd parses what we appended).
acId=$(docker run -d --rm "$IMAGE" -L debug)
# shellcheck disable=SC2064
trap "docker stop $cid $acId >/dev/null 2>&1 || true" EXIT
i=0
until docker exec "$acId" nc -z 127.0.0.1 4822; do
  i=$((i + 1))
  [ "$i" -gt 30 ] && { docker logs "$acId" || true; fail "guacd with -L debug extra args never listened on 4822"; }
  sleep 1
done
docker stop "$acId" >/dev/null 2>&1 || true

echo "Testing the deprecated GUACD_LOG_LEVEL still warns and boots (upstream entrypoint contract)..."
wcid=$(docker run -d --rm -e GUACD_LOG_LEVEL=debug "$IMAGE")
# shellcheck disable=SC2064
trap "docker stop $cid $wcid >/dev/null 2>&1 || true" EXIT
i=0
until docker exec "$wcid" nc -z 127.0.0.1 4822; do
  i=$((i + 1))
  [ "$i" -gt 30 ] && { docker logs "$wcid" || true; fail "guacd under GUACD_LOG_LEVEL=debug never listened on 4822"; }
  sleep 1
done
# Grab the logs BEFORE the stop: --rm reaps them once the container is gone.
logs=$(docker logs "$wcid" 2>&1)
docker stop "$wcid" >/dev/null 2>&1 || true
echo "$logs" | grep -q "deprecated" \
  || fail "GUACD_LOG_LEVEL deprecation warning missing from logs"

echo "All guacamole-server tests passed!"
