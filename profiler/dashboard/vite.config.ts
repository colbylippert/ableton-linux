import { fileURLToPath } from 'node:url';
import type { Plugin } from 'vite';
import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';

/**
 * The dashboard reads committed data from its parent directory (profiler/):
 *   history/runs/*.json, history/baselines.json, ledger.jsonl
 * Vite's dev server only serves files inside `server.fs.allow`, so profiler/ is
 * allowed explicitly (computed from this file's location, independent of cwd).
 * `base: './'` makes the built dist/ work from any static host or sub-path.
 */
const dashboardDir = fileURLToPath(new URL('.', import.meta.url));
const profilerDir = fileURLToPath(new URL('..', import.meta.url));
const historyDir = fileURLToPath(new URL('../history', import.meta.url));

/**
 * Vite's file watcher covers the Vite root (plus config, env and public files). The history
 * records are imported with `import.meta.glob` from profiler/history/, outside the root: a
 * record that is already loaded is watched on its own (editing it reloads the page), but a
 * NEW record written by `history-add` — or a first baselines.json — is only noticed when the
 * directory itself is watched. Adding it makes the glob plugin's create/delete handling
 * fire, which invalidates src/data/load.ts and reloads the page with the new run.
 */
function watchHistoryDir(): Plugin {
  return {
    name: 'profiler:watch-history',
    configureServer(server) {
      server.watcher.add(historyDir);
    },
  };
}

export default defineConfig({
  plugins: [react(), watchHistoryDir()],
  base: './',
  server: {
    host: true,
    port: 5173,
    strictPort: false,
    fs: {
      allow: [dashboardDir, profilerDir],
    },
  },
  preview: {
    host: true,
    port: 4173,
  },
  build: {
    outDir: 'dist',
    sourcemap: false,
  },
  test: {
    environment: 'jsdom',
    include: ['src/**/*.test.{ts,tsx}'],
    css: false,
  },
});
