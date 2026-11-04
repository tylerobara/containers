# semantic-router (vllm-sr-dashboard)

The [vLLM Semantic Router](https://github.com/vllm-project/semantic-router)
Dashboard — the web UI + admin backend for the router's config, catalog and
replay tooling — built the minimal way: all four upstream build stages
reproduced from the release tarball by **melange**, assembled by **apko** on
Wolfi — no Dockerfile anywhere.

| | |
|---|---|
| Image | `ghcr.io/tylerobara/containers/vllm-sr-dashboard` |
| Upstream | `ghcr.io/vllm-project/semantic-router/dashboard` (python3.11-slim + gosu) |
| Build | melange: Go→WASM DSL compiler + `wasm_exec.js`; Vite frontend + wizmap Svelte app (`npm ci`, nodejs-20); CGO Go backend (`mattn/go-sqlite3`) over upstream's exact package whitelist; vendored pip venv (k8s-sidecar pattern) |
| Runs as | root entrypoint → `gosu nonroot` (65532), same `ENTRYPOINT`/`CMD` contract as upstream, port 8700 |

Image version == the repo's `vX.Y.Z` release tag (asserted equal to the
`src/vllm-sr/pyproject.toml` version in the build), and the tag is stamped
into the backend's `handlers.dashboardStatusVersion` ldflag like upstream's
release build.

```
docker run --rm -p 8700:8700 -v $PWD/config.yaml:/app/config/config.yaml \
  ghcr.io/tylerobara/containers/vllm-sr-dashboard:latest
# http://localhost:8700 — /healthz reports {"status":"healthy","service":"semantic-router-dashboard"}
```

Tags are the plain version (`0.4.0`, `0.4`, `latest`). Pin by digest in
production and verify signatures:

```
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/tylerobara/containers/\.github/workflows/vllm-sr-dashboard\.yml@refs/heads/main$' \
  ghcr.io/tylerobara/containers/vllm-sr-dashboard:0.4.0
```

(Only digest-pinned references are signed, and only when the daily grype scan
reports zero Low+ findings — see the Pages catalog for current state.)

## Deliberate differences from upstream

- Wolfi packages replace debian's runtime set: `docker-cli` for `docker.io`,
  `shadow` for the entrypoint's `groupadd`/`usermod`, `gosu` as-is; upstream's
  runtime `curl`/`wget` were debug-only and are left out (the smoke probes
  from the host instead).
- The pip venv drops `pip`/`setuptools` after the build (upstream keeps them)
  — same treatment as `k8s-sidecar`, smaller + a cleaner grype gate.
- The backend builds over the Dockerfile's exact package whitelist (not the
  whole Go module): that list is what keeps the Rust/onnx binding importers
  out of the build graph.

## The router image

The sibling `vllm-sr` router image (issue #111) needs the four Rust-nightly
cdylib bindings, the ONNX Runtime blob and a torch/HF model-export stage — a
much heavier build tracked separately; this family dir hosts the dashboard
only for now.

## Updating

`images/semantic-router/melange/vllm-sr-dashboard.yaml` pins `version` +
`vars.sha256` of the GitHub release tarball; the daily update-versions bot
opens the bump PR, validate it with `vllm-sr-dashboard.yml → Run workflow`
(`ref=<bump branch>`, `validate_only`) before merging. The apko world line is
a floating `- vllm-sr-dashboard`, so the workflow's lock guard (exact
`<version>-r<epoch>` resolution) is what catches a same-named Wolfi package
ever outranking this epoch-100 build.
