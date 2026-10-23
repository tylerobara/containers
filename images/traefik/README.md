# traefik

[Traefik](https://traefik.io) (reverse proxy / ingress controller) built from
the release tarball by melange, assembled by apko on Wolfi — no Dockerfile.
Mirrors upstream's image contract (static Go binary, plain-binary
entrypoint, flags-only interface) with deliberate deviations: the binary
lives at `/usr/bin/traefik` (upstream: `/traefik`), everything runs as uid
65532, and the dashboard UI assets are **not** embedded (upstream's release
CI yarn-builds them into the binary pre-embed; the melange build ships the
tarball's `webui/static` placeholder instead — the API/ping endpoints work,
only the dashboard HTML/JS is absent, which matches how this one is used:
`--api.dashboard=false`).

```
docker run --rm ghcr.io/tylerobara/containers/traefik:latest version
docker run --rm ghcr.io/tylerobara/containers/traefik:latest \
  --entrypoints.web.address=:80 --ping --api.dashboard=false   # /ping on :8082
```

## Running

Traefik is flag/config driven (upstream ships no CMD either). A provider is
optional at boot — the internal provider alone starts fine (that's what the
smoke test exercises); enable `providers.kubernetesCRD`/`kubernetesIngress`
in the cluster. Anything Traefik writes (ACME `acme.json` under `/data`,
TLS material, access logs) needs a volume you mount and chown to 65532.

## Signing

Same keyless policy as every image here: signed only when the CI grype scan
reports 0 findings Low+; verify per the command on
<https://tylerobara.github.io/containers/>.

## Updating

`version` + `vars.sha256` in `melange/traefik.yaml`; the melange build also
stamps `pkg/version.Version` (+ `Codename`/`BuildDate`) via ldflags exactly
like upstream's release build, so `traefik version` reports the real release.
The update-versions bot opens bump PRs against
[traefik/traefik releases](https://github.com/traefik/traefik/releases); the
`vars.xnet_version` `go get` pin becomes a no-op (drop it) once upstream
ships >= it.
