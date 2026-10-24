# kubernetes-reflector

[EmberStack Reflector](https://github.com/emberstack/kubernetes-reflector) —
the cluster addon that mirrors secrets/configmaps into other namespaces (what
the ExternalDNS/External-Secret-style charts shell out to) — built from the
release tarball by melange, assembled by apko on Wolfi. No Dockerfile.
`docker.io/emberstack/kubernetes-reflector:10.0.65` is the upstream reference.

Upstream is ASP.NET (.NET 10), not Go, so the build contract is upstream's
own `dotnet publish -c Release` from
`src/ES.Kubernetes.Reflector/Dockerfile` + release pipeline, with the
`/p:Version=` stamps their CI injects from GitVersion (the tarball has no
`.git`, so we pass the pinned version directly). The published tree ships
**self-contained** — it bundles the .NET 10 + ASP.NET runtime — because Wolfi
has no ASP.NET Core shared framework; the only runtime-system deps are Wolfi's
`icu` + `libstdc++`, the same set Wolfi's own dotnet package declares.

```
docker run --rm ghcr.io/tylerobara/containers/kubernetes-reflector:latest
```

## What it mirrors from upstream

- app on `:8080` (`ASPNETCORE_HTTP_PORTS=8080`, same env the aspnet base
  image sets upstream) serving the helm chart's `/health/live` + `/health/ready`
- a single launch point: `/usr/bin/reflector` symlinks the apphost at
  `/usr/lib/kubernetes-reflector/ES.Kubernetes.Reflector` (which resolves its
  dll + native libs from its own directory), instead of upstream's
  `ENTRYPOINT ["dotnet", "ES.Kubernetes.Reflector.dll"]` from `/app`
- nonroot: uid 65532 here instead of upstream's `app` user; the official
  chart's securityContext (`runAsNonRoot`, `runAsUser: 1000`) overrides it at
  deploy time either way

## Using the official helm chart

```
helm upgrade --install reflector oci://ghcr.io/emberstack/helm-charts/reflector \
  --set image.repository=ghcr.io/tylerobara/containers/kubernetes-reflector \
  --set image.tag=10.0.65
```

## Signing

Same keyless policy as every image here: signed only when the CI grype scan
reports 0 findings Low+; verify per the command on
<https://tylerobara.github.io/containers/>.

## Updating

`version` + `vars.sha256` in `melange/kubernetes-reflector.yaml`; the melange
build also stamps `/p:Version`/`/p:InformationalVersion` (upstream's release
CI gets these from GitVersion, which can't run on a tarball), and the verify
step boots the real apphost (no cluster) and asserts the chart's
`/health/live` path answers before the package is shipped. The update-versions
bot opens bump PRs against
[emberstack/kubernetes-reflector releases](https://github.com/emberstack/kubernetes-reflector/releases)
(vX.Y.Z tags).
