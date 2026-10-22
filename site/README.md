# Catalog site

The image catalog at <https://tylerobara.github.io/containers/>, built with
[Astro](https://astro.build). Design and structure follow
[rtvkiz/minimal's site](https://github.com/rtvkiz/minimal/tree/main/site)
(MIT).

Built and deployed by `.github/workflows/site.yml`, which runs:

- as a **reusable workflow** from every image workflow's `pages` job — the
  run's fresh `pages-data-*` entries are merged over the live
  `data/index.json` (keyed on image+major, fresh wins) before the build;
- on **push to main** touching `site/**`, `catalog.json` or an apko config —
  a rebuild from the live index, no image build;
- on **pull requests** (build only) and **workflow_dispatch**.

The publish is a compare-and-swap (`--force-with-lease` against the gh-pages
commit the index was read from), retried on top of the winner when two image
workflows deploy at once — so no family's fresh entry is ever lost.

## How it works

```
catalog.json            (repo root: which images get pages + metadata)
  + images/<dir>/apko/* → requested packages, spec fallback
  + data/index.json     → version, tags, digest, signed, full grype report
                          (written by the image workflows, lives on gh-pages)
  + GHCR registry API   → image config (env, entrypoint, user), archs, size
            │
  scripts/build-data.mjs  →  src/data/images.json
            │
         astro build      →  dist/  (+ data/index.json, cluster-image-catalog.yaml)
                                 →  gh-pages
```

`build-data.mjs` isolates every image: a missing source degrades just that
page ("partial data"), never the build. PostgreSQL (`per_major: true`) gets
one page per published major.

## Local development

```bash
cd site
npm install
git show origin/gh-pages:data/index.json > index.json   # optional: real data
node scripts/build-data.mjs index.json                  # or no arg: metadata only
npx astro dev                                           # http://localhost:4321/containers/
```

`SKIP_REGISTRY=1` skips the GHCR lookups (fully offline).
`src/data/images.json` is committed as a seed so a fresh clone renders.

## Adding an image

Add an entry to `catalog.json` (`name` = the registry path under
`ghcr.io/tylerobara/containers/`, `dir`, `apko`, `workflow`, `category`,
`summary`, `description`). Index entries without a catalog entry are reported
as a warning and not rendered.
