import React from 'react';
import { createRoot } from 'react-dom/client';
import './theme.css';
import App from './App';
import { loadDashboardData } from './data/load';

// The history records, baselines.json and the ledger are imported by src/data/load.ts at
// module evaluation, so the data is read exactly once per page load. Under `npm run dev`
// Vite watches those files (vite.config.ts adds profiler/history/ to the watcher because it
// lies outside the Vite root): a record `history-add` writes or a ledger line the agent
// appends invalidates load.ts, nothing in the import chain accepts the update, and Vite
// reloads the page with the new data. The active tab (URL hash), the theme (localStorage)
// and the filter (sessionStorage) survive that reload. A static `dist/` has the data
// inlined at build time: rebuild after new runs land.
const data = loadDashboardData();

const container = document.getElementById('root');
if (!container) {
  throw new Error('index.html is missing <div id="root">');
}

createRoot(container).render(
  <React.StrictMode>
    <App data={data} />
  </React.StrictMode>,
);
