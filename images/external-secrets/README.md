# external-secrets

[External Secrets Operator](https://external-secrets.io) — the Kubernetes
operator that syncs secrets from external stores (AWS/ GCP/ Azure Secrets
Manager, Vault, and the rest of the provider registry) into in-cluster
`ExternalSecret`/`Secret` resources — built from the release tarball by
melange, assembled by apko on Wolfi. No Dockerfile.

**One image, one binary, three modes.** Upstream ships a single image whose
static Go binary serves all three deployments: the controller is the root
command (`main.go`), while `webhook` and `certcontroller` are cobra
subcommands — exactly how upstream's helm chart spawns them (same image,
args `["webhook", ...]` / `["certcontroller", ...]`). This image mirrors that
shape, so point all three chart deployments at it:

```
# controller (default entrypoint, like upstream's ENTRYPOINT)
docker run --rm ghcr.io/tylerobara/containers/external-secrets:latest --help
# webhook / cert-controller: override args the way the chart does
docker run --rm --entrypoint /usr/bin/external-secrets \
  ghcr.io/tylerobara/containers/external-secrets:latest webhook --help
```

In helm: `--set image.repository=ghcr.io/tylerobara/containers/external-secrets
--set image.tag=2.14.0` — `webhookImage`/`certControllerImage` stay unset, the
chart picks modes via args. Bare runs outside a cluster exit loudly on the
missing in-cluster kube config; the nonroot posture matches upstream's
release image (USER 65534), and the chart's `runAsNonRoot` pod securityContext
governs actual deployments.

## Deviations (deliberate)

- **The "three binaries" ask doesn't exist upstream.** Issue #68's premise
  (separate controller/webhook/crypto binaries) does not hold at v2.14.0: the
  Makefile builds ONE binary from root `main.go`, webhook/certcontroller are
  subcommands, and there is no crypto binary or command anywhere in the tree.
  (`cmd/esoctl` is a dev-only CLI that never ships.) Building upstream's
  single-binary contract is upstream's own deployment shape, not a shortcut.
- **Upstream stamps no version** — no ldflags in the Makefile build, the
  cobra root sets no `Version`, so `--version` is an unknown flag (the flux
  family's documented situation; the lone `-X main.version` in the tree
  belongs to esoctl). The version anchor is the sha256-pinned release tarball
  the melange build verifies, the embedded build-info module assertion, the
  `2.14.0-r100` apk db check in `test.sh`, and the image tag.
- **go-1.27 + `GOTOOLCHAIN=local`**: go.mod requires `go 1.27.0` (toolchain
  go1.27.3) — upstream bumped past Wolfi's default go; same handling as the
  flux images.
- **Network module resolution**: the release tarball has no `vendor/`, and
  the root go.mod local-replaces its ~118 apis/providers/generators
  submodules; same pattern as the cert-manager/cilium builds.
- **Wolfi busybox debug shell** instead of upstream's distroless scratch base,
  and `/usr/bin` (FHS) instead of `/bin` — the repo-wide conventions; binary
  content (`CGO_ENABLED=0 go build -tags all_providers`, all providers/
  generators compiled in like upstream's release) and uid 65534 match upstream.

## Signing

Same keyless policy as every image here: signed only when the CI grype scan
reports 0 findings Low+; verify per the command on
<https://tylerobara.github.io/containers/>.

## Updating

`version` + `vars.sha256` in `melange/external-secrets.yaml`. The
update-versions bot covers this row — but upstream's `releases/latest`
returns the **chart** tag (`helm-chart-X.Y.Z`), so the bot's row filters the
tag list for plain `vX.Y.Z` tags instead (traefik's strategy). The apko world
line floats (`- external-secrets`): the workflow's lock guard fails the build
if the resolved apk is not exactly our `2.14.0-r100`, and epoch/provider
priority 100 keep any same-version Wolfi package from winning resolution.
