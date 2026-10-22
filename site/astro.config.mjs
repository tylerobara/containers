// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// Project Pages site: served from https://tylerobara.github.io/containers/, so
// every internal link goes through lib/catalog.ts's `href()` to pick up `base`.
export default defineConfig({
  site: 'https://tylerobara.github.io',
  base: '/containers/',
  trailingSlash: 'ignore',
  build: {
    format: 'directory',
  },
  integrations: [
    sitemap({
      serialize(item) {
        const p = new URL(item.url).pathname.replace(/^\/containers/, '');
        item.changefreq = p.startsWith('/images/') ? 'daily' : 'weekly';
        return item;
      },
    }),
  ],
});
