#!/bin/sh
# Smoke test for the Gatus image.
# Usage: IMAGE=ghcr.io/.../gatus:5.37.0 VERSION=5.37.0 ./test.sh
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION (gatus version, no v)}"

fail() { echo "FAIL: $1"; exit 1; }

echo "Testing entrypoint is /usr/bin/gatus..."
ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
[ "$ep" = "[/usr/bin/gatus]" ] || fail "entrypoint is '$ep', expected '[/usr/bin/gatus]'"

echo "Testing nonroot uid 65532..."
uid=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
[ "$uid" = "65532" ] || fail "run-as is '$uid', expected '65532'"

echo "Testing prod restraint: busybox shell only, no bash/apk-tools..."
docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
  command -v bash >/dev/null 2>&1 && exit 1
  command -v apk  >/dev/null 2>&1 && exit 1
  exit 0' || fail "bash or apk-tools present in prod image"

echo "Testing bundled example config + image env default..."
# gatus $VERSION has no --version flag and prints no version banner (main.go
# parses no flags at all), so the version anchor is the sha-pinned tarball the
# melange build verified; here we assert the image contract instead: the
# example config is present and GATUS_CONFIG_PATH defaults to the mount point.
docker run --rm --entrypoint /bin/sh "$IMAGE" -ec '
  test -s /etc/gatus/config.yaml.example
  grep -q "^endpoints:" /etc/gatus/config.yaml.example' \
  || fail "/etc/gatus/config.yaml.example missing or empty"
envs=$(docker inspect --format '{{.Config.Env}}' "$IMAGE" | tr -d '[]')
echo "$envs" | tr ' ' '\n' | grep -qx 'GATUS_CONFIG_PATH=/etc/gatus/config.yaml' \
  || fail "GATUS_CONFIG_PATH default missing: $envs"

echo "Testing bare run without config fails loudly (no silent boot)..."
docker run --rm --entrypoint /usr/bin/gatus "$IMAGE" >out.log 2>&1 && rc=0 || rc=$?
[ "$rc" != 0 ] || { cat out.log; fail "gatus booted without any config"; }
grep -qi "config" out.log || { cat out.log; fail "config-missing panic is unintelligible"; }
rm -f out.log

echo "Testing the status page serves on :8080 (booted with the example config)..."
cid=$(docker run -d --rm -p 127.0.0.1::8080 \
  -e GATUS_CONFIG_PATH=/etc/gatus/config.yaml.example "$IMAGE")
# shellcheck disable=SC2064
trap "docker stop $cid >/dev/null 2>&1 || true" EXIT
port=$(docker port "$cid" 8080/tcp | head -1 | sed 's/.*://')
i=0
until curl -fsS -o /dev/null "http://127.0.0.1:${port}/"; do
  i=$((i + 1))
  [ "$i" -gt 30 ] && { docker logs "$cid"; fail "status page never came up"; }
  sleep 1
done
curl -fsS "http://127.0.0.1:${port}/" | grep -q "Gatus" \
  || fail "status page is not the embedded gatus SPA"
curl -fsS "http://127.0.0.1:${port}/api/v1/endpoints/statuses" >/dev/null \
  || fail "endpoints-status API not serving"
docker stop "$cid" >/dev/null
trap - EXIT

echo "All gatus tests passed!"
