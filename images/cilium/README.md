# cilium (cilium, cilium-operator-generic, cilium-envoy)

Cilium CNI built the minimal way: the agent/operator trees are compiled
from the upstream release tarball by **melange** (`make build-container
install-container-binary` / the `-operator-generic` pair, exactly as
upstream's Dockerfiles invoke them) and assembled by **apko** on Wolfi — no
Dockerfile anywhere.

| Image | Upstream | Built | Contents |
|---|---|---|---|
| `ghcr.io/tylerobara/containers/cilium` | `quay.io/cilium/cilium` | melange from source | `cilium-agent`, `cilium-dbg`/`cilium`, `cilium-bugtool`, `cilium-health`, `hubble`, `cilium-mount`, `cilium-sysctlfix`, `cilium-envoy-bootstrap-locality`, `/opt/cni/bin/cilium-cni`, `/cni/loopback`, `/init-container.sh`, `/install-plugin.sh`, `/cni-uninstall.sh`, `/var/lib/cilium/bpf` + Wolfi `bash iproute2 iptables ipset kmod jq util-linux clang bpftool gops` (llvm/gcc ride in on clang's depends) + bundled `cilium-envoy` |
| `ghcr.io/tylerobara/containers/cilium-operator-generic` | `quay.io/cilium/operator-generic` | melange from source | `cilium-operator-generic` (generic IPAM) + Wolfi `gops` + `ca-certificates`, `GOPS_CONFIG_DIR=/home/gops` with a 777 `/home/gops` |
| `ghcr.io/tylerobara/containers/cilium-envoy` | `quay.io/cilium/cilium-envoy` | extracted, digest-pinned | static `cilium-envoy` + `cilium-envoy-starter` from the upstream image, busybox base |

## Helm usage

Swap all three in one `helm upgrade` (tags follow upstream; the envoy tag is
the plain Envoy version):

```
helm upgrade cilium cilium/cilium --version 1.20.3 \
  --namespace kube-system \
  --set image.override=ghcr.io/tylerobara/containers/cilium \
  --set image.useDigest=false --set image.tag=1.20.3 \
  --set operator.image.override=ghcr.io/tylerobara/containers/cilium-operator-generic \
  --set operator.image.useDigest=false --set operator.image.tag=1.20.3 \
  --set envoy.image.override=ghcr.io/tylerobara/containers/cilium-envoy \
  --set envoy.image.useDigest=false --set envoy.image.tags[0]=1.38.6 --set envoy.image.tags[1]=1.38.6
```

Pin by digest in production (`docker buildx imagetools inspect` the tags
above); verify signatures:

```
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/tylerobara/containers/\.github/workflows/cilium\.yml@refs/heads/main$' \
  ghcr.io/tylerobara/containers/cilium:1.20.3
```

(Only digest-pinned references are signed, and only when the daily grype
scan reports zero Low+ findings — see the Pages catalog for current state.)

## Deliberate differences from upstream

- **No ubuntu rootfs.** Upstream's agent image is ubuntu 26.04 with apt
  residue; the runtime deps from `install-runtime-deps.sh` all exist in
  Wolfi (`iproute2`, `iptables`, `ipset`, `kmod`, `jq`, `util-linux`) plus
  the runtime BPF toolchain (Wolfi `clang` 23.1.4 — cilium 1.20.3 only ever
  execs `clang -target bpf`, never `llc` — plus `bpftool`).
  Upstream's `iptables-wrapper` autodetect is skipped: Wolfi `iptables` is
  nft-only, so there is no legacy/nft choice to make.
- **cilium-envoy is extracted, not bazel-built.** Building Envoy means
  multi-hour bazel+clang superbuilds, so the static binary comes from the
  exact digest-pinned upstream image (the pin cilium itself ships in
  `images/cilium/Dockerfile`), sha256-verified per arch and smoke-tested.
  Same tier as the CNPG operator image reusing upstream release binaries.
- `gops` is Wolfi's package (upstream's `build-gops.sh` pins the very same
  v0.3.29); `bash-completion` and `LICENSE.all` are not shipped.
- Envoy image is busybox-on-Wolfi, not bare scratch (one debug shell per
  prod image, repo-wide convention).

## Files

- `melange/cilium.yaml` — agent tree from the release tarball
- `melange/cilium-operator-generic.yaml` — operator (generic) from the same tarball
- `melange/cilium-envoy.yaml` — registry-API extraction of the digest-pinned upstream image
- `apko/*.yaml` — one config per image
- `test.sh <cilium|operator|envoy>` — CI smoke test
- `.github/workflows/cilium.yml` — build/publish/scan/sign, daily 06:30 UTC
