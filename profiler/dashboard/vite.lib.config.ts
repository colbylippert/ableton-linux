import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

/**
 * Library build of the dashboard's components (src/lib.ts) into dist-lib/: one ES module plus
 * one stylesheet (theme tokens + component CSS). React, ReactDOM and Recharts stay external —
 * the consumer (the design-sync converter's bundle) provides them. Type declarations come from
 * `tsc -p tsconfig.lib.json` in the same `npm run build:lib`. The app build (vite.config.ts) is
 * unaffected.
 */
export default defineConfig({
  plugins: [react()],
  publicDir: false,
  build: {
    outDir: 'dist-lib',
    emptyOutDir: true,
    sourcemap: false,
    cssCodeSplit: false,
    lib: {
      entry: 'src/lib.ts',
      formats: ['es'],
      fileName: () => 'index.js',
      cssFileName: 'style',
    },
    rolldownOptions: {
      external: ['react', 'react-dom', 'react/jsx-runtime', 'recharts'],
    },
  },
});
