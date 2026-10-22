# grafana-image-renderer

[Grafana Image Renderer](https://github.com/grafana/grafana-image-renderer)
v5 (a static Go server driving headless Chromium — no Node.js since v5) built
from the release tarball by melange, assembled by apko on Wolfi with Wolfi's
`chromium` + a compact font set — no Dockerfile. Mirrors the upstream image
contract (`/usr/bin/grafana-image-renderer`, `tini` as PID 1, nonroot 65532,
`:8081`, `GET /healthz`, `X-Auth-Token` on `/render`). Deliberate deviations:

- **Wolfi chromium, not Debian's pinned 155.x** — Wolfi's chromium lags a few
  releases (currently 149.x) but gets security patches on Wolfi's own daily
  cadence; the rebuild schedule picks them up. The binary is on `PATH`
  (`browser.path` defaults to `chromium`).
- **Small font set** (dejavu + Open Sans + Noto core/CJK) instead of upstream's
  ~20-package multilingual pile; if a dashboard needs another script, add the
  matching `font-noto-*` package to the apko config.
- **No chromium-driver/shell** (Selenium-only) and no bash/util-linux debug
  tooling — busybox shell only.

```
docker run --rm ghcr.io/tylerobara/containers/grafana-image-renderer:latest version
```

## Running the server

```
docker run --rm -p 8081:8081 \
  ghcr.io/tylerobara/containers/grafana-image-renderer:latest \
  server --server.auth-token=<token>
```

Then point Grafana at it (`[rendering] server_url =
http://<host>:8081/render?token=<token>`). Config flows through CLI flags,
env vars (`SERVER_ADDR`, `AUTH_TOKEN`, `BROWSER_PATH`, ...; full list in
`grafana-image-renderer server --help`), or a `config.yaml`/`config.json`
(next-key form, e.g. `server.auth-token: <token>`) in the working directory —
v5 dropped the old .ini file. Health: `GET /healthz` (unauthenticated) or the
bundled `grafana-image-renderer healthcheck` subcommand for the container
probe.

**Chromium sandbox:** off by default (upstream's default too). The renderer
runs as uid 65532; give it a real sandbox at the platform level (gVisor/Kata)
rather than enabling `--browser.sandbox` unless the kernel has unprivileged
user namespaces available inside the container.

## Signing

Same keyless policy as every image here: signed only when the CI grype scan
reports 0 findings Low+; verify per the command on
<https://tylerobara.github.io/containers/>. Note a chromium-based image carries
chromium's whole CVE surface — expect unsigned periods after a fresh chromium
release until Wolfi ships the bump.

## Updating

`version` + `vars.sha256` in `melange/grafana-image-renderer.yaml`; the
update-versions bot opens bump PRs against
[grafana/grafana-image-renderer releases](https://github.com/grafana/grafana-image-renderer/releases).
The daily rebuild tracks Wolfi's chromium/font updates without a yaml change.
