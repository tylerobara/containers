# metallb (controller, speaker, frr-k8s)

MetalLB built the minimal way: all binaries compiled from the upstream release
tarballs by **melange** with upstream's exact build contracts
(`CGO_ENABLED=0` + the same `go build` targets as `controller/Dockerfile`,
`speaker/Dockerfile` and the frr-k8s `Makefile`; commit/branch ldflags left at
upstream's release-visible `dev`/`dev` so the startup banners match
byte-for-byte) and assembled by **apko** on Wolfi — no Dockerfile anywhere.
Upstream ships the same static binaries on `distroless/static` (frr-k8s on a
busybox base); here every image is busybox + ca-certificates, the repo's
one-debug-shell convention.

| Image | Upstream | Built | Contents |
|---|---|---|---|
| `ghcr.io/tylerobara/containers/metallb-controller` | `quay.io/metallb/controller` | melange from source | `/controller` (`./controller`) |
| `ghcr.io/tylerobara/containers/metallb-speaker` | `quay.io/metallb/speaker` | melange from source | `/speaker`, `/frr-metrics`, `/cp-tool`, `/frr-reloader.sh` |
| `ghcr.io/tylerobara/containers/metallb-frr-k8s` | `quay.io/metallb/frr-k8s` | melange from source | `/frr-k8s`, `/statuscleaner`, `/frr-metrics`, `/frr-status`, `/frr-reloader.sh` |

Binary paths are at `/` (not the repo's usual `/usr/bin/`) on purpose: the
upstream images place them there and the helm chart hardcodes them — the
`ENTRYPOINT`s (`/controller`, `/speaker`) and the speaker/frr-k8s init
containers (`/cp-tool /frr-metrics ...`, `cp -f /frr-reloader.sh ...`) exec
those exact paths. The metallb pair shares one sha256-pinned tarball and moves
in lockstep (bot bumps both configs in one PR; the workflow's version guard
refuses a mixed set). frr-k8s is a separate upstream (`metallb/frr-k8s`) with
its own version line and its own tarball. No binary has a `--version` flag, so
the melange builds and `test.sh` verify the JSON startup banners
(`MetalLB controller starting version 0.16.1 (commit dev, branch dev)`) and —
for the bannerless frr-k8s binaries — that each gets as far as demanding an
in-cluster API server config.

## Helm usage

metallb's chart keys are per-component `image.repository`/`image.tag`
overrides. With the bundled frr-k8s mode (`frrk8s.enabled=true`, the 0.16
default), one values file swaps all three of our images; the FRR routing
containers stay on the official `quay.io/frrouting/frr` image (out of scope
here — the chart pins it via `frr-k8s.frr.image`):

```
helm upgrade metallb metallb/metallb --version 0.16.1 \
  --namespace metallb-system --create-namespace \
  --set controller.image.repository=ghcr.io/tylerobara/containers/metallb-controller \
  --set controller.image.tag=0.16.1 \
  --set speaker.image.repository=ghcr.io/tylerobara/containers/metallb-speaker \
  --set speaker.image.tag=0.16.1 \
  --set frr-k8s.frrk8s.image.repository=ghcr.io/tylerobara/containers/metallb-frr-k8s \
  --set frr-k8s.frrk8s.image.tag=0.0.27
```

(The last two are values passed to the packaged `frr-k8s` subchart — note the
hyphen. Upstream's `v`-prefixed tags vs our plain-version tags make the
explicit `image.tag` sets above required.)

Tags start with the version (`0.16.1`, `0.16`, `latest`; frr-k8s: `0.0.27`,
`0.0`, `latest`). Pin by digest in production
(`docker buildx imagetools inspect` the tags above); verify signatures:

```
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/tylerobara/containers/\.github/workflows/metallb\.yml@refs/heads/main$' \
  ghcr.io/tylerobara/containers/metallb-controller:0.16.1
```

(Only digest-pinned references are signed, and only when the daily grype scan
reports zero Low+ findings — see the Pages catalog for current state.)

## Deliberate differences from upstream

- **distroless → busybox-on-Wolfi** base: same static Go binaries, plus
  `/bin/sh` for debugging and Wolfi `ca-certificates`. The frr-k8s image's
  `/bin/sh` + `cp` are load-bearing (the chart's `cp-reloader`/`cp-metrics`/
  `cp-frr-status` init containers run them from this image).
- **Vulnerable Go deps are raised** before compiling (`go get` of the
  patched releases; `vars.xnet_version`/`vars.otel_version`/`vars.grpc_version`
  in the configs): upstream 0.16.1 pins `golang.org/x/net v0.53.0` (Critical/
  High advisories fixed in 0.60.0), otel ≤1.40.0 (GHSA-8wmf-6v46-5gfg, Low,
  fixed in 1.45.0) and `google.golang.org/grpc v1.83.0` (High
  GHSA-2v4p-qf9q-27wj / GHSA-vp52-pcj8-j9qc, fixed in 1.83.2); frr-k8s 0.0.27
  pins x/net v0.57.0 (its otel is already 1.45.0, so only the x/net pin
  applies there). The melange verify steps assert the patched versions land in
  the binaries' embedded build info (what grype reads).
- **No run-as / root parity**: upstream runs user 0 (distroless default) and
  the chart's daemonsets grant the capabilities (speaker needs `NET_RAW`/
  `NET_ADMIN` for memberlist/BGP); the frr-k8s daemon's config files are read
  by root-owned frr sidecars across shared volumes, so we keep root.
- **frr-k8s ships the latest upstream (0.0.27), not minilab's 0.0.25**: the
  metallb 0.16.1 chart bundles the frr-k8s 0.0.25 subchart, but 0.0.27 is the
  current release and the bot tracks it; compatibility is the chart's problem
  to pin via `frr-k8s.frrk8s.image.tag`.
- **The official FRR containers image stays upstream** (`quay.io/frrouting/
  frr`): it is a full Debian-based FRR routing suite, a separate packaging
  project in its own right, and only referenced here via `frr-k8s.frr.image`.
- **No `/LICENSE` root files**; the melange packages carry SPDX metadata.

## Files

- `melange/metallb-{controller,speaker}.yaml` — one config per metallb image
  (shared tarball + `go get` vuln pins)
- `melange/metallb-frr-k8s.yaml` — frr-k8s' own tarball, four binaries + script
- `apko/metallb-{controller,speaker,frr-k8s}.yaml` — one config per image
- `test.sh <controller|speaker|frr-k8s>` — CI smoke test
- `.github/workflows/metallb.yml` — build/publish/scan/sign, daily 06:40 UTC
