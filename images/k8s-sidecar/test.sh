#!/usr/bin/env bash
# Smoke test for the k8s-sidecar image.
# Usage: IMAGE=ghcr.io/tylerobara/containers/k8s-sidecar:2.14.1 ./test.sh
set -euo pipefail

IMAGE="${IMAGE:?set IMAGE=...}"
pass=0
fails=()
check() { # <label> <cmd...>
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else fails+=("$label"); fi
}

# 1. The real ENTRYPOINT runs the app: `python -u -m sidecar --help` exits 0
#    (argparse prints usage; imports the kubernetes client + requests on the
#    way in, so a broken venv fails here).
check "entrypoint --help exits 0" \
  docker run --rm --entrypoint python "$IMAGE" -u -m sidecar --help

# 2. Every pinned dependency imports inside the image.
check "deps import (kubernetes/requests/pythonjsonlogger/logfmter)" \
  docker run --rm --entrypoint python "$IMAGE" -c \
  "import kubernetes, requests, pythonjsonlogger, logfmter"

# 3. No apk tooling shipped (prod images are busybox-only).
check "no apk" \
  docker run --rm --entrypoint sh "$IMAGE" -c "! command -v apk"

# 4. Upstream contract: ENTRYPOINT array, user, env.
EP="$(docker inspect "$IMAGE" --format '{{join .Config.Entrypoint " "}}')"
[ "$EP" = "python -u -m sidecar" ] || { echo "entrypoint: got '$EP'"; exit 1; }
pass=$((pass + 1))
USER="$(docker inspect "$IMAGE" --format '{{.Config.User}}')"
[ "$USER" = "65534" ] || { echo "user: got '$USER'"; exit 1; }
pass=$((pass + 1))
docker inspect "$IMAGE" --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep -qx "PYTHONUNBUFFERED=1" || { echo "PYTHONUNBUFFERED missing"; exit 1; }
pass=$((pass + 1))

echo "k8s-sidecar: $pass checks passed"
[ ${#fails[@]} -eq 0 ] || { echo "FAILED: ${fails[*]}"; exit 1; }
