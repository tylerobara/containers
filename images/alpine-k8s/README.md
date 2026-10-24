# alpine-k8s

Wolfi counterpart to [alpine/k8s](https://github.com/alpine-docker/k8s): the
kubectl/helm toolbox the minilab pipelines run. Assembled by apko on Wolfi —
no Dockerfile. helm is the one piece built from upstream source by melange
([`melange/helm.yaml`](melange/helm.yaml), 3.22.1 pinned to the 3.x line: its
old Wolfi `helm-3` apk was the source of **every** grype finding this image
ever had — 326 of them); everything else is signed Wolfi packages, so the
daily rebuild picks up security updates without a commit. Like the reference,
**the image version is the kubectl version** (`alpine/k8s:1.37.1` ↔
`alpine-k8s:1.37.1`).

```
docker run --rm ghcr.io/tylerobara/containers/alpine-k8s:latest version --client
# Client Version: v1.37.1
```

## What's in it

| tool | note |
|------|------|
| busybox | `sh` + coreutils |
| kubectl | Wolfi `kubectl-1.37-default`, pinned to the minor series so the lock can't drift off the image's version line; patches float like the reference's tag builds |
| helm | our melange build ([`melange/helm.yaml`](melange/helm.yaml)) from the sha-pinned upstream tarball, 3.x line only — Wolfi's plain `helm` is now helm 4, and its old `helm-3` apk is what this replaces |
| kustomize | manifest overlay renderer |
| jq / yq | JSON / YAML munging (the reference ships both too) |
| gettext | `envsubst` for manifest templating, as in the reference |
| git, curl, ca-certificates, bash | what the reference's `apk add` baseline covers |

Deliberately **not** shipped (all present in the reference, none needed by the
minilab pipelines): the EKS-specific `eksctl`, `awscli` and
`aws-iam-authenticator`, the sealed-secrets helper `kubeseal`, `vals`,
`kubeconform`, and `krew` (a plugin manager that installs into `$HOME/.krew`
and needs network at runtime — pointless as a nonroot image with no writable
HOME). Want one? It's one line in the apko `packages:` list if Wolfi ships it.

Runs as uid/gid 65532 (`nonroot`) — the reference runs as root, but kubectl
and helm need no privileges. There is no writable HOME; mount an `emptyDir`
if a pipeline step wants to write kubeconfig cache files.

## Versioning

`VERSION` in this directory is the tag source (also `MAJOR.MINOR` + `latest`
tags) and mirrors kubectl's release, exactly like the reference tag. The
update-versions bot tracks kubernetes/kubernetes releases within the pinned
minor and bumps `VERSION`; **minor** bumps are manual — the apko config pins
`kubectl-1.37`, so a minor bump means editing that line once Wolfi ships the
new `kubectl-1.<minor>` package. The helm build is a separate bot row
(**alpine-k8s-helm**): it tracks helm **3.x tags only** (upstream
`releases/latest` is helm 4, which breaks the pipelines) and bumps
`melange/helm.yaml` `version` + `vars.sha256`; a bump also needs the apko
`helm=<ver>-r100` pin and `vars.git_commit` moved by hand — the workflow's
lock guard and the melange assert step fail loudly on any drift.

## Verify

```
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/tylerobara/containers/\.github/workflows/alpine-k8s\.yml@refs/heads/main$' \
  ghcr.io/tylerobara/containers/alpine-k8s:latest
```

Only signed when the grype scan in the same run found zero Low+ findings;
current digests, scans and signatures are on the [Pages catalog](https://tylerobara.github.io/containers/).
