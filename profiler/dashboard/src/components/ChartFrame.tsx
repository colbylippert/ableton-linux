/**
 * ChartFrame (DESIGN.md calls it `ChartCard`): the <figure> that owns a chart's title,
 * subtitle, key row, the chart | table toggle and the empty state. Every chart renders
 * through it so a value is never reachable only by hovering. The chosen view is remembered
 * per viewer when an `id` is given (localStorage, guarded: private windows, blocked storage).
 */
import { useCallback, useState, type ReactNode } from 'react';
import './components.css';

export type ChartView = 'chart' | 'table';

export interface ChartFrameProps {
  title: string;
  subtitle?: string;
  /** Legend or key, shown above the chart (not above the table). */
  keyRow?: ReactNode;
  chart: ReactNode;
  table: ReactNode;
  defaultView?: ChartView;
  footer?: ReactNode;
  /** When set, replaces chart and table with this message and hides the toggle. */
  empty?: ReactNode;
  /** Stable id used to remember the view per viewer. Omit to never persist. */
  id?: string;
  className?: string;
}

const STORAGE_PREFIX = 'profiler-dashboard.chartview.';

function readStoredView(id: string | undefined): ChartView | null {
  if (!id) return null;
  try {
    const value = localStorage.getItem(STORAGE_PREFIX + id);
    return value === 'chart' || value === 'table' ? value : null;
  } catch {
    return null;
  }
}

function storeView(id: string, view: ChartView) {
  try {
    localStorage.setItem(STORAGE_PREFIX + id, view);
  } catch {
    /* per-viewer convenience only */
  }
}

function cx(...parts: (string | false | null | undefined)[]): string {
  return parts.filter(Boolean).join(' ');
}

export default function ChartFrame({ title, subtitle, keyRow, chart, table, defaultView, footer, empty, id, className }: ChartFrameProps) {
  const [view, setView] = useState<ChartView>(() => readStoredView(id) ?? defaultView ?? 'chart');
  const choose = useCallback(
    (next: ChartView) => {
      setView(next);
      if (id) storeView(id, next);
    },
    [id],
  );
  const isEmpty = empty !== undefined && empty !== null && empty !== false;

  return (
    <figure className={cx('card', 'chart-frame', className)} data-view={isEmpty ? 'empty' : view}>
      <figcaption className="chart-frame-head">
        <div className="chart-frame-titles">
          <h3 className="card-title">{title}</h3>
          {subtitle ? <p className="card-subtitle">{subtitle}</p> : null}
        </div>
        {isEmpty ? null : (
          <div className="chart-frame-toggle" role="group" aria-label={`${title}: view as`}>
            <button type="button" aria-pressed={view === 'chart'} onClick={() => choose('chart')}>
              Chart
            </button>
            <button type="button" aria-pressed={view === 'table'} onClick={() => choose('table')}>
              Table
            </button>
          </div>
        )}
      </figcaption>
      {isEmpty ? (
        <div className="chart-frame-empty">{empty}</div>
      ) : (
        <>
          {view === 'chart' && keyRow ? <div className="chart-frame-key">{keyRow}</div> : null}
          <div className="chart-frame-body">{view === 'chart' ? chart : table}</div>
        </>
      )}
      {footer ? <div className="chart-frame-footer">{footer}</div> : null}
    </figure>
  );
}

/** DESIGN.md's name for the same component. */
export { ChartFrame as ChartCard };
