import React from 'react';
import { createRoot } from 'react-dom/client';
import './theme.css';
import App from './App';
import { loadDashboardData } from './data/load';

// Data is loaded at module evaluation; Vite's HMR re-evaluates src/data/load.ts when a
// history record or ledger line changes, so a new run appears without a reload.
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
