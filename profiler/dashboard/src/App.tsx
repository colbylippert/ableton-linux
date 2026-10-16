import { useCallback, useEffect, useMemo, useState, type ComponentType, type KeyboardEvent } from 'react';
import { DEFAULT_FILTER, type DashboardData, type FilterState } from './data/types';
import { applyFilter, filterOptions } from './data';
import FilterBar from './components/FilterBar';
import type { ViewProps } from './views/ViewProps';
import OverviewView from './views/Overview';
import TrendsView from './views/Trends';
import TrialsView from './views/Trials';
import CallSitesView from './views/CallSites';
import ScenariosView from './views/Scenarios';
import RunsView from './views/Runs';

export type TabId = 'overview' | 'trends' | 'trials' | 'callsites' | 'scenarios' | 'runs';

interface TabDef {
  id: TabId;
  label: string;
  view: ComponentType<ViewProps>;
}

/** Tab order is the reading order: headline → trends → what changed → why → diagnostics → raw. */
export const TABS: readonly TabDef[] = [
  { id: 'overview', label: 'Overview', view: OverviewView },
  { id: 'trends', label: 'Trends', view: TrendsView },
  { id: 'trials', label: 'Trials', view: TrialsView },
  { id: 'callsites', label: 'Call sites', view: CallSitesView },
  { id: 'scenarios', label: 'Scenarios', view: ScenariosView },
  { id: 'runs', label: 'Runs', view: RunsView },
];

export type ThemeChoice = 'system' | 'light' | 'dark';

const THEME_KEY = 'profiler-dashboard.theme';

function isTabId(value: string): value is TabId {
  return TABS.some((t) => t.id === value);
}

function readHashTab(): TabId {
  if (typeof window === 'undefined') return 'overview';
  const raw = window.location.hash.replace(/^#/, '');
  return isTabId(raw) ? raw : 'overview';
}

function readStoredTheme(): ThemeChoice {
  try {
    const v = localStorage.getItem(THEME_KEY);
    return v === 'light' || v === 'dark' ? v : 'system';
  } catch {
    return 'system';
  }
}

function applyTheme(choice: ThemeChoice) {
  const root = document.documentElement;
  if (choice === 'system') root.removeAttribute('data-theme');
  else root.setAttribute('data-theme', choice);
  try {
    if (choice === 'system') localStorage.removeItem(THEME_KEY);
    else localStorage.setItem(THEME_KEY, choice);
  } catch {
    /* per-viewer convenience only; storage may be unavailable */
  }
}

export interface AppProps {
  data: DashboardData;
}

/**
 * Tab shell. Owns the active tab (mirrored in the URL hash so a view is linkable), the
 * theme choice (system / light / dark, remembered per viewer) and the FilterBar state,
 * which scopes every view. Data is injected so tests can render the shell with fixtures.
 */
export default function App({ data }: AppProps) {
  const [tab, setTab] = useState<TabId>(readHashTab);
  const [theme, setTheme] = useState<ThemeChoice>(readStoredTheme);
  const [filter, setFilter] = useState<FilterState>(DEFAULT_FILTER);

  useEffect(() => {
    applyTheme(theme);
  }, [theme]);

  useEffect(() => {
    const onHash = () => setTab(readHashTab());
    window.addEventListener('hashchange', onHash);
    return () => window.removeEventListener('hashchange', onHash);
  }, []);

  const selectTab = useCallback((id: TabId) => {
    setTab(id);
    if (typeof window !== 'undefined' && window.location.hash !== `#${id}`) {
      window.history.replaceState(null, '', `#${id}`);
    }
  }, []);

  const onTabKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    const index = TABS.findIndex((t) => t.id === tab);
    let next = index;
    if (event.key === 'ArrowRight') next = (index + 1) % TABS.length;
    else if (event.key === 'ArrowLeft') next = (index - 1 + TABS.length) % TABS.length;
    else if (event.key === 'Home') next = 0;
    else if (event.key === 'End') next = TABS.length - 1;
    else return;
    event.preventDefault();
    const target = TABS[next];
    if (!target) return;
    selectTab(target.id);
    const button = document.getElementById(`tab-${target.id}`);
    button?.focus();
  };

  const active = useMemo(() => TABS.find((t) => t.id === tab) ?? TABS[0]!, [tab]);
  const View = active.view;

  const runs = data.runs.length;
  const trials = data.trials.length;

  return (
    <div className="app">
      <header className="app-header">
        <h1 className="app-title">Profiler gains</h1>
        <span className="app-meta" aria-live="polite">
          {runs} run{runs === 1 ? '' : 's'} · {trials} trial{trials === 1 ? '' : 's'}
          {data.loadErrors.length > 0 ? ` · ${data.loadErrors.length} load warning${data.loadErrors.length === 1 ? '' : 's'}` : ''}
        </span>
        <span className="spacer" />
        <div className="theme-toggle" role="group" aria-label="Theme">
          {(['system', 'light', 'dark'] as const).map((choice) => (
            <button key={choice} type="button" aria-pressed={theme === choice} onClick={() => setTheme(choice)}>
              {choice[0]!.toUpperCase() + choice.slice(1)}
            </button>
          ))}
        </div>
      </header>

      <div className="tablist" role="tablist" aria-label="Dashboard views" onKeyDown={onTabKeyDown}>
        {TABS.map((t) => (
          <button
            key={t.id}
            id={`tab-${t.id}`}
            className="tab"
            role="tab"
            type="button"
            aria-selected={t.id === tab}
            aria-controls={`panel-${t.id}`}
            tabIndex={t.id === tab ? 0 : -1}
            onClick={() => selectTab(t.id)}
          >
            {t.label}
          </button>
        ))}
      </div>

      {/* One row above the panel; it scopes every view. */}
      <div className="filterbar-slot">
        <FilterBar filter={filter} options={filterOptions(data.runs)} onChange={setFilter} runsInSlice={applyFilter(data.runs, filter).length} />
      </div>

      <main id={`panel-${active.id}`} className="tabpanel" role="tabpanel" aria-labelledby={`tab-${active.id}`}>
        <View data={data} filter={filter} onFilterChange={setFilter} />
      </main>
    </div>
  );
}
