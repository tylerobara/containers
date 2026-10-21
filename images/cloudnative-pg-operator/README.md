# cloudnative-pg-operator

The [CloudNativePG operator](https://github.com/cloudnative-pg/cloudnative-pg)
built the same way as everything else here: **apko + Wolfi base, no Dockerfile**.
The manager binary is compiled from the upstream release tarball by melange
(`melange/cloudnative-pg.yaml`, the minimal repo's traefik pattern):
`CGO_ENABLED=0 go build ./cmd/manager` → fully static, package named exactly
`cloudnative-pg` with `provider-priority: 100` so it wins resolution and
grype/CPE identify it.

Mirrors the operator's upstream Distroless image: static `/manager` entrypoint,
`nonroot` uid/gid **65532**, `ca-certificates`, plus busybox for debugging
(~78 MB total). Manifests from upstream are drop-in — just point
`image:`/`imageCatalogRef` at our registry.

## Tags

`melange/cloudnative-pg.yaml`'s `version:` is the source of truth. Each build
publishes, from one digest:

```
ghcr.io/tylerobara/containers/cloudnative-pg:1.30.1
ghcr.io/tylerobara/containers/cloudnative-pg:1.30
ghcr.io/tylerobara/containers/cloudnative-pg:latest
```

The workflow refuses to publish if `apko lock` resolves anything other than
the exact `version-r<epoch>` from the melange config.

**On each operator release:** bump `version` + `vars.sha256` (SHA256 of
`https://github.com/cloudnative-pg/cloudnative-pg/archive/refs/tags/v<ver>.tar.gz`)
and push.

## Signing

Same gate as the postgres images: cosign keyless sign only when the post-publish
grype scan has zero Low-or-above findings. Go-module CVEs in the operator's
dependency tree are common upstream, so "unsigned this build" is normal and
visible on the catalog page; check the job summary for the blocking count.

## Build locally

```sh
brew install melange  # one-time
melange build melange/cloudnative-pg.yaml --arch aarch64 \
  --signing-key melange.rsa --out-dir ./packages --runner docker   # ~4 min
docker run --rm --user root -v "$PWD:/w" \
  cgr.dev/chainguard/apko lock /w/apko/operator.yaml --arch aarch64 \
  --repository-append /w/packages --keyring-append /w/key/melange.rsa.pub \
  --output /w/op.lock.json
docker run --rm --user root -v "$PWD:/w" -v /var/run/docker.sock:/var/run/docker.sock \
  cgr.dev/chainguard/apko publish /w/apko/operator.yaml \
  cnpg-operator:local --arch aarch64 --local --lockfile /w/op.lock.json \
  --repository-append /w/packages --keyring-append /w/key/melange.rsa.pub
IMAGE=cnpg-operator:local VERSION=1.30.1 ./test.sh
```
