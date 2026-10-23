# local-path-provisioner

[Rancher's local-path-provisioner](https://github.com/rancher/local-path-provisioner)
(a lightweight local-volume StorageClass provisioner for Kubernetes — what
k3d/k3s-style clusters use for `local-path` PVCs) built from the release
tarball by **melange** with upstream's exact build contract
(`scripts/build`: `CGO_ENABLED=0` + `-X main.VERSION=<tag> -extldflags -static
-s -w` ldflags, so the binary self-reports `v0.0.37` instead of the unstamped
`0.0.1` default) and assembled by **apko** on Wolfi — no Dockerfile anywhere.
Upstream ships the same static binary on `scratch`
([`package/Dockerfile`](https://github.com/rancher/local-path-provisioner/blob/v0.0.37/package/Dockerfile));
here the base is busybox + Wolfi `ca-certificates`, the repo's
one-debug-shell convention.

| Image | Upstream | Built | Contents |
|---|---|---|---|
| `ghcr.io/tylerobara/containers/local-path-provisioner` | `docker.io/rancher/local-path-provisioner` | melange from source | `/usr/bin/local-path-provisioner` |

## Helm usage

The official chart keys are the top-level `image.repository`/`image.tag`:

```
helm upgrade local-path-provisioner local-path-provisioner/local-path-provisioner \
  --namespace local-path-storage --create-namespace \
  --set image.repository=ghcr.io/tylerobara/containers/local-path-provisioner \
  --set image.tag=0.0.37
```

Tags start with the version (`0.0.37`, `0.0`, `latest`); upstream's tags are
`v`-prefixed, hence the explicit `image.tag` above. Pin by digest in
production (`docker buildx imagetools inspect` the tags) and verify
signatures:

```
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/tylerobara/containers/\.github/workflows/local-path-provisioner\.yml@refs/heads/main$' \
  ghcr.io/tylerobara/containers/local-path-provisioner:0.0.37
```

(Only digest-pinned references are signed, and only when the daily grype scan
reports zero Low+ findings — see the Pages catalog for current state.)

## Deliberate differences from upstream

- **scratch → busybox-on-Wolfi base**: same static Go binary, plus `/bin/sh`
  for debugging and Wolfi `ca-certificates`. The provisioner itself never
  shells out — the volume work happens in helper pods that pull their own
  busybox image (`--helper-image` / the chart's `helperImage` values, left at
  upstream's default here).
- **run-as 65532**: upstream's scratch base has no user (root in practice)
  and the chart sets no `runAsUser`; ours is the repo-wide nonroot default.
  Functionally free — the provisioner only talks to the API server with its
  in-cluster token.
- **Vulnerable vendored dep raised**: upstream 0.0.37 pins
  `golang.org/x/net v0.56.0` (grype Critical/High advisories fixed in
  0.60.0); the melange build raises it via `go get` + `go mod vendor`
  (`vars.xnet_version` in the config) and the verify step asserts the patched
  version lands in the binary's embedded build info (what grype reads). The
  bump becomes a no-op once upstream ships >= 0.60.0.
- **No `/LICENSE` root file**; the melange package carries SPDX metadata.

## Files

- `melange/local-path-provisioner.yaml` — Go build from the sha256-pinned tarball
- `apko/local-path-provisioner.yaml` — the image definition
- `test.sh` — CI smoke test (`--version` stamp, `start` reaches the
  API-server step, no apk-tools, entrypoint)
- `.github/workflows/local-path-provisioner.yml` — build/publish/scan/sign,
  daily 07:25 UTC

## Updating

`version` + `vars.sha256` in `melange/local-path-provisioner.yaml`; the
update-versions bot opens bump PRs against
[rancher/local-path-provisioner releases](https://github.com/rancher/local-path-provisioner/releases).
Validate a bump PR by running this image's workflow with `ref = <bump branch>`
and **validate_only** checked.
