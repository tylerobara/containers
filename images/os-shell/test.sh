#!/bin/sh
# Smoke test for the os-shell image.
# Usage: IMAGE=ghcr.io/.../os-shell:1.0.0 ./test.sh
# VERSION is accepted (like the sibling test.sh scripts) but nothing in an
# apko-only image embeds it — the tag is the version.
set -eu
: "${IMAGE:?set IMAGE}"

fail() { echo "FAIL: $1"; exit 1; }

echo "Testing default shape: no entrypoint, cmd /bin/sh, run-as 65532..."
ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
[ "$ep" = "[]" ] || fail "entrypoint is '$ep', expected '[]'"
cmd=$(docker inspect --format '{{.Config.Cmd}}' "$IMAGE")
[ "$cmd" = "[/bin/sh]" ] || fail "default cmd is '$cmd', expected '[/bin/sh]'"
uid=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
[ "$uid" = "65532" ] || fail "run-as is '$uid', expected '65532'"

echo "Testing the whole advertised toolset actually runs..."
# Functional probes, not `command -v`: jq/yq evaluate, ps is procps (busybox
# ps rejects --version), nc is present as the wait-for-port replacement.
docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
  bash -c "echo bash-ok" | grep -q bash-ok || exit 1
  curl --version | head -1 | grep -qi curl || exit 2
  echo "{\"a\":42}" | jq -e ".a == 42" >/dev/null || exit 3
  printf "a: 42\n" | yq -e ".a == 42" >/dev/null || exit 4
  ps --version | grep -qi procps || exit 5
  command -v nc >/dev/null || exit 6
  nc -h 2>&1 | grep -qi usage || exit 7
  exit 0' || fail "toolset probe failed (codes: 2=curl 3=jq 4=yq 5=procps-ps 6=nc-missing 7=nc-usage)"

echo "Testing bash is on PATH for init-container-style invocations..."
docker run --rm --entrypoint /bin/bash "$IMAGE" -c 'echo ok' | grep -q ok \
  || fail "/bin/bash -c does not run"

echo "Testing no package manager at runtime (Wolfi minimal)..."
docker run --rm --entrypoint /bin/sh "$IMAGE" -c \
  '! command -v apk >/dev/null' \
  || fail "apk-tools leaked into the image"

echo "All os-shell smoke tests passed."
