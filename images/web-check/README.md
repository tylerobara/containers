# web-check

[Web-Check](https://github.com/lissy93/web-check) (web-check.xyz — the
all-in-one OSINT/analysis tool for any website) built from the pinned release
tarball by melange — the upstream Dockerfile's two yarn stages: full-toolchain
`astro check && astro build`, then a prod-only `node_modules` — and served by
Wolfi's `nodejs-24` running `node server.js`, no Dockerfile. Mirrors the
upstream image contract: app at `/app`, GUI + `/api` checks + `/healthz` on
`$PORT` (default 3000).

```
docker run -d -p 3000:3000 ghcr.io/tylerobara/containers/web-check:latest
```

Tags follow the upstream release: `2.3.11`, `2.3`, `latest`.

## Config

Nothing is required: open the UI and enter a target. Optional knobs are the
app's own env vars (`PORT`, `DISABLE_GUI=true` for API-only,
`API_CORS_ORIGIN`, `TRUST_PROXY`, plus per-check API keys like
`SECURITYTRAILS_API_KEY`) — see the upstream README; the image bakes only
`NODE_ENV=production` and `PORT=3000`.

The default user is nonroot **65532** (`web-check`); the app keeps no state,
so there is nothing to mount or chown.

## Deliberate deviations from upstream

- **No chromium** (the big one): upstream's image apt-installs chromium +
  tini and points puppeteer at `/usr/bin/chromium`. Wolfi's chromium carries
  thousands of unfixable grype findings (same reason grafana's renderer
  residuals are never chased), all of it for the screenshot/browser-based
  checks only. Everything else — DNS, HTTP headers, SSL, ports, cookies,
  geo, the ~30 API checks — runs identically; the browser-based checks fail
  soft per-check instead of degrading the container. Want them? Add
  `chromium` to the apko config and accept that the image stops meeting the
  sign-with-0-findings gate.
- **No traceroute**: Wolfi ships no traceroute package, so the one check that
  shells out to it degrades the same way.
- **node 24 via Wolfi**, not `node:22-bookworm-slim` + apt; explicit
  `nodejs-24` stream in both build and runtime so a Wolfi stream rollover
  can't change the major silently (upstream's engines allow 22/24/26).
- **dumb-init instead of tini**, house PID 1; **nonroot 65532** by default
  (upstream runs as root).
- The server binds all interfaces on `$PORT` (express default) — apko has no
  `EXPOSE`; reach it via published ports on any interface.
- Version source is upstream's latest semver **tag** — their GitHub releases
  lag tags — and the update-versions bot sources tags for this row.

## Signing

Same keyless policy as every image here: signed only when the CI grype scan
reports 0 findings Low+; verify per the command on
<https://tylerobara.github.io/containers/>.

## Updating

`version` + `vars.sha256` in `melange/web-check.yaml` (tarball URL
`https://github.com/lissy93/web-check/archive/refs/tags/<version>.tar.gz`,
no v prefix). The update-versions bot opens bump PRs against
[lissy93/web-check tags](https://github.com/lissy93/web-check/tags) —
validate a bump with this image's own workflow (`workflow_dispatch`, ref =
PR branch, validate_only) before merging, as everywhere else here.
