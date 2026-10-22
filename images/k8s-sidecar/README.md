# k8s-sidecar — kiwigrid/k8s-sidecar minimal image

`ghcr.io/tylerobara/containers/k8s-sidecar:<version>` (e.g. `2.14.1`) — a minimal
Wolfi-built drop-in for `ghcr.io/kiwigrid/k8s-sidecar` (the Grafana dashboards
sidecar that syncs ConfigMaps/Secrets to files).

Built the same way as every image here: **melange** builds the app from the
upstream release tarball into a self-contained venv, **apko** assembles the
image from Wolfi packages — no Dockerfile.

## Why from source

Wolfi ships a `k8s-sidecar` package but it's stale (2.7.3 vs upstream 2.14.1).
We build the upstream tag directly; the melange config carries `provider: tylerobara`
+ `provider-priority: 100` + `epoch: 100` so apko always prefers ours over the
Wolfi package of the same name.

The build replicates upstream's Dockerfile contract:

| Upstream (python:3.14-alpine base) | Ours (Wolfi) |
|---|---|
| `python -m venv /app/.venv`, `pip install .` (pyproject pins: kubernetes 36.0.3, requests, python-json-logger, logfmter) | Same — vendored in `/app/.venv` |
| `pip==26.1.2` upgrade inside the venv | Same during build; pip/setuptools stripped from the final venv (never executed at runtime) |
| `USER 65534:65534` | apko `run-as: 65534` (nobody/nogroup) |
| `ENTRYPOINT ["python","-u","-m","sidecar"]` | Same (verified in `test.sh`) |
| `PYTHONUNBUFFERED=1`, `/app/.venv/bin` first on `PATH` | Same |
| Alpine base + openssl 3.5.9 pins | Wolfi base + Wolfi's openssl (auto-tracked, patched within 24–48h) |

The sidecar reports no version anywhere (`--version` doesn't exist; the
pyproject version is a literal `1.0.0` placeholder even in upstream's released
image), so tag identity is pinned by sha256 on the release tarball, and
smoke tests import every pinned dependency and run `python -m sidecar --help`.

## Usage

Grafana's helm chart (and any other consumer) just needs the image override —
it speaks the same CLI/env contract as upstream:

```yaml
sidecar:
  image:
    repository: ghcr.io/tylerobara/containers/k8s-sidecar
    tag: "2.14.1"
```

Runs as UID 65534; a mounted target folder must be group-writable (or 777) —
same requirement as upstream.

## Verify provenance

Every published tag is cosign-signed by this repo's Actions identity:

```bash
cosign verify \
  --certificate-identity-regexp '^https://github.com/tylerobara/containers/\.github/workflows/k8s-sidecar\.yml@' \
  --certificate-oidc-issuer-regexp '^https://token\.actions\.githubusercontent\.com$' \
  ghcr.io/tylerobara/containers/k8s-sidecar:2.14.1
```

## Testing / local build

```bash
IMAGE=ghcr.io/tylerobara/containers/k8s-sidecar:2.14.1 ./test.sh
```

CI runs the same file plus a grype gate (any **Low or higher** finding blocks
publish + signing). To build locally:

```bash
melange build images/k8s-sidecar/melange/k8s-sidecar.yaml --arch host
melange publish images/k8s-sidecar/melange/k8s-sidecar.yaml --local --archive-not-found=error --signing-key melange.rsa
cgr.dev/chainguard/apko publish --local --repository packages images/k8s-sidecar/apko/k8s-sidecar.yaml \
  ghcr.io/tylerobara/containers/k8s-sidecar:$(awk '/^  version:/{print $2; exit}' images/k8s-sidecar/melange/k8s-sidecar.yaml)-amd64
```

## Version bumps

The daily rebuild (06:45 UTC) + the update-versions bot pick up new
`kiwigrid/k8s-sidecar` releases from the GitHub API automatically; the melange
source sha is re-fetched per build, so a stale pin would fail the build
loudly rather than ship the wrong bytes.
