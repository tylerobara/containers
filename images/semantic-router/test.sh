#!/bin/sh
# Smoke test for the vLLM Semantic Router Dashboard image.
# Usage: IMAGE=ghcr.io/.../vllm-sr-dashboard:0.4.0 VERSION=0.4.0 ./test.sh
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION (release version, no v)}"

fail() { echo "FAIL: $1"; exit 1; }

echo "Testing entrypoint + cmd (upstream contract: entrypoint.sh + backend on :8700)..."
ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
[ "$ep" = "[/app/entrypoint.sh]" ] || fail "entrypoint is '$ep', expected '[/app/entrypoint.sh]'"
docker inspect --format '{{json .Config.Cmd}}' "$IMAGE" \
  | grep -q -- '-port=8700' || fail "cmd does not carry -port=8700"

echo "Testing env contract (venv PATH + PYTHONPATH=/app)..."
docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$IMAGE" \
  | grep -qx 'PYTHONPATH=/app' || fail "PYTHONPATH=/app not set in the image"
docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$IMAGE" \
  | grep -q 'PATH=/opt/vllm-sr-dashboard-venv/bin:' \
  || fail "venv bin is not first on PATH"

echo "Testing the WASM DSL compiler assets shipped in the frontend..."
docker run --rm --entrypoint /bin/sh "$IMAGE" -ec \
  'test -s /app/frontend/signal-compiler.wasm && test -s /app/frontend/wasm_exec.js' \
  || fail "signal-compiler.wasm / wasm_exec.js missing from /app/frontend"

echo "Testing the vendored venv as uid 65532 (imports + catalog export)..."
# The read-only asset tree must be usable by the user the entrypoint gosu's
# to — upstream's own Dockerfile RUN warns a root-only smoke misses
# unreadable package data.
docker run --rm --user 65532 -w /tmp --entrypoint \
  /opt/vllm-sr-dashboard-venv/bin/python3 "$IMAGE" \
  -c 'import click, yaml, jinja2, requests, jsonschema, pydantic, huggingface_hub' \
  || fail "venv deps do not import as nonroot"
docker run --rm --user 65532 -w /tmp --entrypoint \
  /opt/vllm-sr-dashboard-venv/bin/python3 "$IMAGE" \
  -m cli.model_catalog_export >/dev/null \
  || fail "cli.model_catalog_export failed as nonroot"

echo "Testing prod restraint: no apk-tools, no node runtime..."
docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
  command -v apk  >/dev/null 2>&1 && exit 1
  command -v node >/dev/null 2>&1 && exit 1
  exit 0' || fail "apk-tools or node present in prod image"

echo "Testing the server boots and /healthz reports healthy (upstream verify contract)..."
# Same env set upstream's own published-image verifier uses. The image has
# no HTTP client, so the probe runs from the host against a published port.
cid=$(docker run -d --rm \
  -p 127.0.0.1::8700 \
  -e DASHBOARD_READONLY=true \
  -e DASHBOARD_RUNTIME_CONFIG_WRITABLE=false \
  -e DASHBOARD_RECIPE_STORE_WRITABLE=false \
  -e EVALUATION_ENABLED=false \
  -e MCP_ENABLED=false \
  -e ML_PIPELINE_ENABLED=false \
  -e OPENCLAW_ENABLED=false \
  "$IMAGE")
# shellcheck disable=SC2064
trap "docker stop $cid >/dev/null 2>&1 || true" EXIT
port=$(docker port "$cid" 8700/tcp | head -1 | awk -F: '{print $NF}')
i=0
until body=$(curl -sf "http://127.0.0.1:${port}/healthz" 2>/dev/null) \
  && echo "$body" | grep -q '"status":"healthy"' \
  && echo "$body" | grep -q '"service":"semantic-router-dashboard"'; do
  i=$((i + 1))
  if [ "$i" -gt 90 ]; then
    docker logs "$cid" 2>&1 | tail -30
    fail "/healthz never reported healthy"
  fi
  docker inspect "$cid" >/dev/null 2>&1 || fail "container exited before becoming healthy"
  sleep 1
done
docker stop "$cid" >/dev/null
trap - EXIT

echo "All vllm-sr-dashboard tests passed!"
