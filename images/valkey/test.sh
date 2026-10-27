#!/bin/sh
# Smoke test for the Valkey image.
# Usage: IMAGE=ghcr.io/.../valkey:9.1.3 VERSION=9.1.3 ./test.sh
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION (valkey version, no v)}"

fail() { echo "FAIL: $1"; exit 1; }

echo "Testing default entrypoint is 'tini -- docker-entrypoint.sh' + CMD valkey-server (upstream contract)..."
ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
[ "$ep" = "[/sbin/tini -- /usr/bin/docker-entrypoint.sh]" ] \
  || fail "entrypoint is '$ep', expected '[/sbin/tini -- /usr/bin/docker-entrypoint.sh]'"
cmd=$(docker inspect --format '{{.Config.Cmd}}' "$IMAGE")
[ "$cmd" = "[valkey-server]" ] || fail "default args are '$cmd', expected '[valkey-server]'"

echo "Testing valkey(999) account + root default user (entrypoint drops via su-exec)..."
user=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
[ -z "$user" ] || [ "$user" = "0" ] || fail "run-as is '$user', expected root"
docker run --rm --entrypoint /bin/sh "$IMAGE" -ec '
  grep -q "^valkey:[^:]*:999:999:" /etc/passwd || exit 1
  grep -q "^valkey:[^:]*:999:" /etc/group || exit 2
  test -d /data || exit 3' \
  || fail "valkey (uid/gid 999) accounts or /data missing"

echo "Testing the shipped tools report v$VERSION (no 'unknown', no version drift)..."
sv=$(docker run --rm --entrypoint /usr/bin/valkey-server "$IMAGE" --version)
echo "$sv"
echo "$sv" | grep -q "v=$VERSION " || fail "valkey-server --version is not v$VERSION: $sv"
echo "$sv" | grep -q 'malloc=jemalloc' || fail "server not on bundled jemalloc: $sv"
cv=$(docker run --rm --entrypoint /usr/bin/valkey-cli "$IMAGE" --version)
echo "$cv" | grep -q "$VERSION" || fail "valkey-cli --version does not report $VERSION: $cv"
docker run --rm --entrypoint /usr/bin/valkey-benchmark "$IMAGE" --version >/dev/null \
  || fail "valkey-benchmark --version failed"
docker run --rm --entrypoint /usr/bin/valkey-cli "$IMAGE" --help >/dev/null \
  || fail "valkey-cli --help failed"
docker run --rm --entrypoint /usr/bin/valkey-benchmark "$IMAGE" --help >/dev/null \
  || fail "valkey-benchmark --help failed"

echo "Testing the server boots under the default entrypoint and answers PING..."
cid=$(docker run -d --rm "$IMAGE")
# shellcheck disable=SC2064
trap "docker stop $cid >/dev/null 2>&1 || true" EXIT
i=0
until docker exec "$cid" valkey-cli ping | grep -q PONG; do
  i=$((i + 1))
  [ "$i" -gt 30 ] && { docker logs "$cid" || true; fail "valkey-server never answered PING"; }
  sleep 1
done

echo "Testing INFO reports valkey_version $VERSION..."
# valkey-cli passes RESP through — strip the \r line endings before anchoring.
# redis_version is the Redis-compat level that Valkey 9.x decoupled from its
# own numbering (9.1.3 reports redis_version:7.2.4), so only valkey_version
# carries the pinned version; redis_version gets a shape check.
info=$(docker exec "$cid" valkey-cli INFO server | tr -d '\r')
echo "$info" | grep -Eq '^server_name:valkey$' \
  || { echo "$info"; fail "INFO server: server_name is not valkey"; }
echo "$info" | grep -Eq "^valkey_version:$VERSION$" \
  || { echo "$info"; fail "INFO server valkey_version is not $VERSION"; }
echo "$info" | grep -Eq '^redis_version:7\.2\.[0-9]+$' \
  || { echo "$info"; fail "INFO server: unexpected redis_version compat line"; }
echo "$info" | grep -Eq '^valkey_release_stage:ga$' \
  || { echo "$info"; fail "not a GA release"; }

echo "Testing SET/GET round-trip..."
docker exec "$cid" valkey-cli SET smoke:key "smoke value" >/dev/null \
  || fail "SET failed"
got=$(docker exec "$cid" valkey-cli GET smoke:key | tr -d '\r')
[ "$got" = "smoke value" ] || fail "GET returned '$got', expected 'smoke value'"

echo "Testing data really lands in /data (dir + persistence under the default entrypoint)..."
docker exec "$cid" valkey-cli CONFIG SET save "900 1" >/dev/null
docker exec "$cid" valkey-cli BGSAVE >/dev/null
i=0
until docker exec "$cid" /bin/sh -c 'test -s /data/dump.rdb'; do
  i=$((i + 1))
  [ "$i" -gt 30 ] && fail "dump.rdb never appeared in /data"
  sleep 1
done

echo "Testing a .conf file arg boots the server via the entrypoint (config arg support)..."
# Template must end in Xs (BSD mktemp); the CONTAINER-side path is what the
# entrypoint checks for the .conf suffix, so the host name does not matter.
# The file must outlive container start — the server reads it lazily while
# the entrypoint is still exec-ing, so it is removed only after the stop.
conf=$(mktemp "${TMPDIR:-/tmp}/valkey-test.XXXXXX")
printf 'port 6390\ndir /data\ndbfilename test-dump.rdb\nsave ""\n' > "$conf"
# mktemp is 0600 (host-uid owned); the server reads it as valkey(999).
chmod 644 "$conf"
# No --rm here: when this container dies the failure must still be explainable
# from `docker logs`, which --rm would have already reaped.
ccid=$(docker run -d -v "$conf:/etc/valkey/test.conf:ro" "$IMAGE" /etc/valkey/test.conf)
# shellcheck disable=SC2064
trap "docker stop $cid $ccid >/dev/null 2>&1 || true" EXIT
i=0
until docker exec "$ccid" valkey-cli -p 6390 ping | grep -q PONG; do
  i=$((i + 1))
  [ "$i" -gt 30 ] && { docker logs "$ccid" || true; fail "server booted from .conf arg never answered on 6390"; }
  sleep 1
done
docker exec "$ccid" valkey-cli -p 6390 SHUTDOWN NOSAVE >/dev/null 2>&1 || true
docker rm -f "$ccid" >/dev/null 2>&1 || true
rm -f "$conf"

echo "All valkey tests passed!"
