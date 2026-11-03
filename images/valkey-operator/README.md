# valkey-operator

The [Valkey operator](https://github.com/valkey-io/valkey-operator) — it
reconciles `ValkeyCluster`/`ValkeyNode` CRDs into valkey clusters — built the
minimal way: the manager compiled from the upstream release tarball by
**melange** with upstream's own build contract, assembled by **apko** on
Wolfi — no Dockerfile anywhere.

| | |
|---|---|
| Image | `ghcr.io/tylerobara/containers/valkey-operator` |
| Upstream | `ghcr.io/valkey-io/valkey-operator` (distroless/static + static `/manager`) |
| Build | melange: `CGO_ENABLED=0 go build -o manager ./cmd` (kubebuilder / controller-runtime), prometheus version ldflag stamped |
| Runs as | nonroot 65532, `ENTRYPOINT ["/manager"]` — same as upstream, so the helm chart / kustomize manifests are drop-in |

Separate upstream repo and version line from the `valkey` server image, so it
bumps independently (the update-versions bot has its own row, and
`valkey-operator.yml` builds it alone).

Tags are the plain version (`0.8.0`, `0.8`, `latest`). Pin by digest in
production and verify signatures:

```
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/tylerobara/containers/\.github/workflows/valkey-operator\.yml@refs/heads/main$' \
  ghcr.io/tylerobara/containers/valkey-operator:0.8.0
```

(Only digest-pinned references are signed, and only when the daily grype scan
reports zero Low+ findings — see the Pages catalog for current state.)

## Updating

`images/valkey-operator/melange/valkey-operator.yaml` pins `version` +
`vars.sha256` of the GitHub release tarball; the daily update-versions bot
opens the bump PR, validate it with `valkey-operator.yml → Run workflow`
(`ref=<bump branch>`, `validate_only`) before merging. The apko world line is
a floating `- valkey-operator`, so the workflow's lock guard (exact
`<version>-r<epoch>` resolution) is what catches a same-named Wolfi package
ever outranking this epoch-100 build.
