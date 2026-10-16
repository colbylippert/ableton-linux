import { fileURLToPath } from 'node:url';
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

export default defineConfig({
  plugins: [react()],
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
