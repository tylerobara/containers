// Typed accessors over the generated dataset (src/data/images.json).
// The JSON is produced by scripts/build-data.mjs before every build.
import data from '../data/images.json';

export interface Specs {
  entrypoint: string | null;
  cmd: string | null;
  env: Record<string, string>;
  user: string | null;
  uid: number | null;
  workdir: string | null;
  archs: string[];
  labels: Record<string, string>;
  exposedPorts: string[];
  volumes: string[];
  packagesRequested: string[];
  layers?: number | null;
  created?: string | null;
  source: 'apko' | 'registry';
}

export interface Cve {
  id: string;
  severity: string;
  package: string;
  installed: string;
  fixedIn: string | null;
  fixState: string | null;
  url: string | null;
}

export interface Vulnerabilities {
  counts: Record<string, number>;
  fixable: number;
  total: number;
  lowPlus: number;
  scanner: string;
  dbBuilt: string | null;
  list: Cve[];
}

export interface ImageRecord {
  /** Registry identity: ghcr.io/<repository>/<name>. */
  name: string;
  /** Page identity: /images/<slug>/. Postgres majors get one page each. */
  slug: string;
  displayName: string;
  major: number | null;
  category: string;
  summary: string;
  description: string;
  upstreamUrl: string | null;
  primaryPackage: string | null;
  sourceDir: string;
  /** Workflow file that built + signed the image (the cosign identity). */
  workflow: string | null;
  repo: string;
  version: string | null;
  builtWith: string | null;
  tags: string[];
  digest: string | null;
  builtAt: string | null;
  updatedAgo: string | null;
  signed: boolean;
  size: { bytes: number; human: string | null } | null;
  archs: string[];
  specs: Specs | null;
  vulnerabilities: Vulnerabilities | null;
  dataStatus: { build: boolean; scan: boolean; apko: boolean; registry: boolean };
  degraded: boolean;
  notes: string[];
}

export interface Dataset {
  generatedAt: string;
  buildDate: string;
  commitSha: string;
  runUrl: string;
  registry: string;
  repository: string;
  categories: string[];
  hasScanData: boolean;
  lastBuild: string | null;
  clusterImageCatalog: { major: number; image: string }[];
  counts: { images: number; full: number; degraded: number };
  images: ImageRecord[];
}

export const dataset = data as unknown as Dataset;
export const images: ImageRecord[] = dataset.images;
export const categories = dataset.categories;

export const GITHUB_URL = `https://github.com/${dataset.repository}`;
export const OIDC_ISSUER = 'https://token.actions.githubusercontent.com';

/** Base-aware internal link: href('/images/') -> '/containers/images/'. */
export function href(path: string): string {
  const base = import.meta.env.BASE_URL.replace(/\/$/, '');
  return `${base}${path.startsWith('/') ? path : `/${path}`}`;
}

export function imageHref(slug: string): string {
  return href(`/images/${slug}/`);
}

export function categoryHref(category: string): string {
  return href(`/images/category/${categorySlug(category)}/`);
}

/** The anchored identity regexp cosign verify needs for the signing workflow. */
export function identityRegexp(workflow: string | null): string {
  const wf = (workflow || '').replace(/\./g, '\\.');
  return `^https://github\\.com/${dataset.repository.replace(/\./g, '\\.')}/\\.github/workflows/${wf}@refs/heads/main$`;
}

export function cosignVerify(img: ImageRecord): string {
  const ref = img.version ? `${img.repo}:${img.version}` : `${img.repo}:latest`;
  return `cosign verify \\
  --certificate-oidc-issuer ${OIDC_ISSUER} \\
  --certificate-identity-regexp '${identityRegexp(img.workflow)}' \\
  ${ref}`;
}

export function byCategory(): Record<string, ImageRecord[]> {
  const out: Record<string, ImageRecord[]> = {};
  for (const c of categories) out[c] = [];
  for (const img of images) (out[img.category] ??= []).push(img);
  return out;
}

export function totalCves(img: ImageRecord): number {
  return img.vulnerabilities ? img.vulnerabilities.total : 0;
}

/** A few site-wide numbers for the landing hero. */
export function siteStats() {
  const scanned = images.filter((i) => i.vulnerabilities);
  return {
    images: images.length,
    categories: categories.length,
    signed: images.filter((i) => i.signed).length,
    clean: scanned.filter((i) => i.vulnerabilities!.lowPlus === 0).length,
    scanned: scanned.length,
    hasScanData: dataset.hasScanData,
  };
}

// URL-safe slug for a category, e.g. "Kubernetes & Networking" -> "kubernetes-networking".
export function categorySlug(category: string): string {
  return category
    .toLowerCase()
    .replace(/&/g, ' ')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
}
