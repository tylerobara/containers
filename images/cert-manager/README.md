# cert-manager (controller, cainjector, webhook)

cert-manager built the minimal way: all three binaries are compiled from the
upstream release tarball by **melange** with upstream's exact build contract
(`CGO_ENABLED=0`, `GOFLAGS=-trimpath`, ldflags `-w -s -X
pkg/util.AppVersion=… -X pkg/util.AppGitCommit=…`, per `make/00_mod.mk`) and
assembled by **apko** on Wolfi — no Dockerfile anywhere. Upstream ships the
same static binary on `distroless/static` (`hack/containers/Containerfile.*`);
here the base is busybox + ca-certificates (the repo's one-debug-shell
convention).

| Image | Upstream | Built | Contents |
|---|---|---|---|
| `ghcr.io/tylerobara/containers/cert-manager-controller` | `quay.io/jetstack/cert-manager-controller` | melange from source | `/usr/bin/cert-manager-controller` (`./cmd/controller`) |
| `ghcr.io/tylerobara/containers/cert-manager-cainjector` | `quay.io/jetstack/cert-manager-cainjector` | melange from source | `/usr/bin/cert-manager-cainjector` (`./cmd/cainjector`) |
| `ghcr.io/tylerobara/containers/cert-manager-webhook` | `quay.io/jetstack/cert-manager-webhook` | melange from source | `/usr/bin/cert-manager-webhook` (`./cmd/webhook`) |

All three configs share one sha256-pinned tarball and move in lockstep — the
update-versions bot bumps them in a single PR, and the workflow's version
guard refuses to publish a mixed set. The startup banner is verified against
both stamps (`version="v…"` + `git_commit="…"`) in the melange build and the
smoke test, mirroring upstream's banner byte-for-byte.

## Helm usage

The chart's `image.repository`/`tag` keys are per-component full-repository
overrides, so one values file swaps all three:

```
helm upgrade cert-manager cert-manager/cert-manager --version v1.21.2 \
  --namespace cert-manager \
  --set image.repository=ghcr.io/tylerobara/containers/cert-manager-controller \
  --set image.tag=1.21.2 \
  --set webhook.image.repository=ghcr.io/tylerobara/containers/cert-manager-webhook \
  --set webhook.image.tag=1.21.2 \
  --set cainjector.image.repository=ghcr.io/tylerobara/containers/cert-manager-cainjector \
  --set cainjector.image.tag=1.21.2
```

Tags start with the version (`1.21.2`, `1.21`, `latest`); upstream's `v`-prefixed
chart default (`v1.21.2`) is set explicitly above. Pin by digest in production
(`docker buildx imagetools inspect` the tags above); verify signatures:

```
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/tylerobara/containers/\.github/workflows/cert-manager\.yml@refs/heads/main$' \
  ghcr.io/tylerobara/containers/cert-manager-controller:1.21.2
```

(Only digest-pinned references are signed, and only when the daily grype scan
reports zero Low+ findings — see the Pages catalog for current state.)

## Deliberate differences from upstream

- **distroless → busybox-on-Wolfi** base: same single static binary per
  image, plus `/bin/sh` for debugging and Wolfi `ca-certificates`. No apt or
  distroless scaffolding.
- **The chart's other two images stay upstream** (out of scope here): the
  `startupapicheck` helm-hook Job and the `acmesolver` spawned for ACME
  dns01 self-checks still pull `quay.io/jetstack/...` — same static Go
  pattern, trivially added later if wanted; or disable the check Job with
  `--set startupapicheck.enabled=false`.
- **No `/licenses` layer** from the Containerfiles; the melange package
  carries SPDX metadata and the tarball's LICENSEs.
- The chart's `runAsNonRoot` + `runAsUser: 1001` securityContext governs the
  containers; the image's own `run-as: 65532` only applies to bare docker runs.

## Files

- `melange/cert-manager-{controller,cainjector,webhook}.yaml` — one config
  per binary (shared tarball + build contract)
- `apko/cert-manager-{controller,cainjector,webhook}.yaml` — one config per image
- `test.sh <controller|cainjector|webhook>` — CI smoke test
- `.github/workflows/cert-manager.yml` — build/publish/scan/sign, daily 06:35 UTC
