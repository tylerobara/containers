# flux (helm-controller, kustomize-controller, notification-controller, source-controller)

The four core Flux controllers, each built the minimal way: compiled from its
own upstream release tarball by **melange** with upstream's exact build
contract (`CGO_ENABLED=0`, `go build -trimpath -a`, no ldflags — per each
repo's `Dockerfile`) and assembled by **apko** on Wolfi — no Dockerfile
anywhere. Unlike cert-manager/metallb, these are four **separate upstream
repos** (github.com/fluxcd/&#60;name&#62;) with independent version lines,
bumped by their own update-versions bot rows.

| Image | Upstream | Built | Contents |
|---|---|---|---|
| `ghcr.io/tylerobara/containers/helm-controller` | `ghcr.io/fluxcd/helm-controller` | melange from source | `/usr/bin/helm-controller` (`main.go` + `internal/`) |
| `ghcr.io/tylerobara/containers/kustomize-controller` | `ghcr.io/fluxcd/kustomize-controller` | melange from source | `/usr/bin/kustomize-controller` + `git` (remote bases) |
| `ghcr.io/tylerobara/containers/notification-controller` | `ghcr.io/fluxcd/notification-controller` | melange from source | `/usr/bin/notification-controller` |
| `ghcr.io/tylerobara/containers/source-controller` | `ghcr.io/fluxcd/source-controller` | melange from source | `/usr/bin/source-controller` |

Pinned versions: helm-controller 1.6.5, kustomize-controller 1.9.6,
notification-controller 1.9.4, source-controller 1.9.6 — the version is
enforced by the sha256-pinned release tarball in each melange config. The
flux binaries carry **no version stamp** (upstream adds no ldflags; `--version`
is an unknown flag on the upstream images too — the version ships only as an
OCI annotation), so the melange verify step asserts the binary boots to its
in-cluster config step, exposes this controller's unique flag surface, and
embeds the right module path in its build info.

## Install usage

`flux install` (and `flux create source/git` etc.) build image refs as
`--registry/<component>:v<version>`, so the workflow also publishes the
upstream-style `v<version>` tag next to the repo-standard ones
(`1.6.5`, `1.6`, `latest`, `v1.6.5`):

```
flux install --registry ghcr.io/tylerobara/containers \
  --version v2.8.0   # pins the bundled controller versions; keep these in
                     # sync with the pins above or bump both together
```

Pin by digest in production (`docker buildx imagetools inspect` the tags
above); verify signatures:

```
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/tylerobara/containers/\.github/workflows/flux\.yml@refs/heads/main$' \
  ghcr.io/tylerobara/containers/helm-controller:1.6.5
```

(Only digest-pinned references are signed, and only when the daily grype scan
reports zero Low+ findings — see the Pages catalog for current state.)

## Deliberate differences from upstream

- **alpine → busybox-on-Wolfi** base: same single static binary per image,
  plus `/bin/sh` for debugging and Wolfi `ca-certificates`.
- **kustomize-controller gets `git`** (upstream ships it for kustomize remote
  bases) but **not `tini`/`gnupg`/`openssh-client`**: the binary is PID 1
  directly (fine under Kubernetes; tini only reaped zombies for git/sops side
  processes), and PGP-based SOPS decryption / SSH git auth extras are out of
  scope — use age-based SOPS, or add the packages to the apko config later.
- **No OCI annotations stamped**: upstream's release workflow labels the
  image (`org.opencontainers.image.revision`) at docker buildx time; apko
  configs here keep the repo-standard minimal shape, and `flux check --pre`
  style version reporting via those annotations is unavailable.
- **No `/licenses` layer**; the melange package carries SPDX metadata and the
  tarball's LICENSEs.
- The install manifests' `runAsNonRoot` + `--watch-all-namespaces` etc.
  govern the containers; the image's own `run-as: 65532` only applies to bare
  docker runs (upstream uses 65534).

## Files

- `melange/{helm,kustomize,notification,source}-controller.yaml` — one config
  per binary (own tarball, own version line)
- `apko/{helm,kustomize,notification,source}-controller.yaml` — one config per image
- `test.sh <helm-controller|kustomize-controller|notification-controller|source-controller>` — CI smoke test
- `.github/workflows/flux.yml` — build/publish/scan/sign, daily 06:45 UTC
