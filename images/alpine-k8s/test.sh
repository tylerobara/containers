#!/bin/sh
# Smoke test for the alpine-k8s image.
# Usage: IMAGE=ghcr.io/.../alpine-k8s:1.37.1 VERSION=1.37.1 ./test.sh
set -eu
: "${IMAGE:?set IMAGE}"
: "${VERSION:?set VERSION}"

fail() { echo "FAIL: $1"; exit 1; }

echo "Testing default shape: no entrypoint, cmd kubectl, run-as 65532..."
ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
[ "$ep" = "[]" ] || fail "entrypoint is '$ep', expected '[]'"
cmd=$(docker inspect --format '{{.Config.Cmd}}' "$IMAGE")
[ "$cmd" = "[/usr/bin/kubectl]" ] || fail "default cmd is '$cmd', expected '[/usr/bin/kubectl]'"
uid=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
[ "$uid" = "65532" ] || fail "run-as is '$uid', expected '65532'"

echo "Testing kubectl + helm run as the image's nonroot user and print versions..."
# No --user override: this exercises the run-as 65532 account. kubectl checks
# the pinned minor series (v<major>.<minor>.x), not the exact patch — the
# apko lock floats kubectl patches inside the series, same as the reference.
series=${VERSION%.*}
docker run --rm --entrypoint kubectl "$IMAGE" version --client \
  | grep -q "Client Version: v${series}\." \
  || fail "kubectl --client does not print v${series}.x"
docker run --rm --entrypoint helm "$IMAGE" version --short \
  | grep -q '^v3\.' \
  || fail "helm does not print a v3.x version (helm-3 pin leaked?)"

echo "Testing the rest of the advertised toolset actually runs..."
# Functional probes, not `command -v`: jq/yq evaluate; kustomize prints a
# version; envsubst is the gettext probe. Codes: 1=kustomize 2=jq 3=yq 4=envsubst
docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
  kustomize help 2>&1 | grep -qi usage || exit 1
  echo "{\"a\":42}" | jq -e ".a == 42" >/dev/null || exit 2
  printf "a: 42\n" | yq -e ".a == 42" >/dev/null || exit 3
  printf "%s" "\$PATH" | envsubst | grep -q /usr/bin || exit 4
  exit 0' || fail "toolset probe failed (codes: 1=kustomize 2=jq 3=yq 4=envsubst)"

echo "Testing no package manager at runtime (Wolfi minimal)..."
docker run --rm --entrypoint /bin/sh "$IMAGE" -c \
  '! command -v apk >/dev/null' \
  || fail "apk-tools leaked into the image"

echo "All alpine-k8s smoke tests passed."
