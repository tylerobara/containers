#!/bin/sh
# Smoke test for the Kubernetes Reflector image.
# Usage: IMAGE=ghcr.io/.../kubernetes-reflector:10.0.65 VERSION=10.0.65 ./test.sh
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION (kubernetes-reflector version, no v)}"

fail() { echo "FAIL: $1"; exit 1; }

echo "Testing prod restraint: busybox shell only, no apk-tools..."
docker run --rm --entrypoint /bin/sh "$IMAGE" -c \
  'command -v apk >/dev/null 2>&1 && exit 1; exit 0' \
  || fail "apk-tools present in prod image"

echo "Testing shipped tree is stamped v$VERSION..."
# Upstream is ASP.NET: no --version flag and no startup banner (unlike the
# cert-manager/metallb Go binaries). The melange build stamps
# /p:Version=/p:InformationalVersion=, so the assertable artefact is the
# stamped assembly metadata sitting in the shipped dll (runtime assembly
# versions are 10.0.1xx, never this app's 10.0.65, so the match is
# unambiguous).
docker run --rm --entrypoint /bin/sh "$IMAGE" -c \
  "grep -q '$VERSION' /usr/lib/kubernetes-reflector/ES.Kubernetes.Reflector.dll" \
  || fail "shipped assembly does not carry version $VERSION"

echo "Testing default entrypoint is /usr/bin/reflector (apphost symlink)..."
ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
[ "$ep" = "[/usr/bin/reflector]" ] || fail "entrypoint is '$ep', expected '[/usr/bin/reflector]'"
uid=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
[ "$uid" = "65532" ] || fail "run-as is '$uid', expected '65532'"

echo "Testing web host comes up without a cluster (helm liveness /health/live on :8080)..."
# No in-cluster config: the watchers log errors and retry — same behaviour
# as the upstream image — while the web host must bind :8080
# (ASPNETCORE_HTTP_PORTS) and serve the liveness path of the official
# reflector helm chart as nonroot uid 65532.
cid=$(docker run -d --rm -p 127.0.0.1::8080 "$IMAGE")
# shellcheck disable=SC2064
trap "docker stop $cid >/dev/null 2>&1 || true" EXIT
port=$(docker port "$cid" 8080/tcp | head -1 | sed 's/.*://')
i=0
until curl -fsS "http://127.0.0.1:${port}/health/live" >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -gt 30 ] && { docker logs "$cid"; fail "reflector never became live"; }
  sleep 1
done
docker stop "$cid" >/dev/null
trap - EXIT

echo "All kubernetes-reflector tests passed!"
