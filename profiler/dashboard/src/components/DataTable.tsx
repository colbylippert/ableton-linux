/**
 * DataTable: the WCAG twin of every chart and the main table views.
 *
 * Sortable headers (buttons with `aria-sort`), optional row selection with a cap (FIFO: when
 * the cap is reached the oldest selection is dropped, so "pick two" never needs a deselect
 * first), nulls render as "—" and sort last in both directions.
 */
import { useMemo, useState, type ReactNode } from 'react';
import './components.css';

export interface Column<T> {
  key: string;
  header: string;
  numeric?: boolean;
  render?: (row: T) => ReactNode;
  /** Value used for sorting; defaults to the row property named by `key`. */
  sortValue?: (row: T) => number | string | null;
  width?: string;
  /** Tooltip on the header cell. */
  title?: string;
}

export interface SortState {
  key: string;
  dir: 'asc' | 'desc';
}

export interface DataTableProps<T> {
  caption: string;
  columns: Column<T>[];
  rows: T[];
  rowKey: (row: T) => string;
  defaultSort?: SortState;
  selectable?: { selected: string[]; max?: number; onChange: (next: string[]) => void };
  dense?: boolean;
  emptyMessage?: string;
  /** Keep the caption for assistive tech but hide it visually (the card already shows a title). */
  captionHidden?: boolean;
  className?: string;
}

function cx(...parts: (string | false | null | undefined)[]): string {
  return parts.filter(Boolean).join(' ');
}

/** Default cell rendering: null/undefined → "—", numbers with thousands separators. */
export function cellText(value: unknown): string {
  if (value === null || value === undefined || value === '') return '—';
  if (typeof value === 'number') return Number.isFinite(value) ? value.toLocaleString('en-US', { maximumFractionDigits: 2 }) : '—';
  if (typeof value === 'boolean') return value ? 'yes' : 'no';
  if (Array.isArray(value)) return value.length === 0 ? '—' : value.map(cellText).join(', ');
  if (typeof value === 'object') return JSON.stringify(value);
  return String(value);
}

function isNil(value: unknown): boolean {
  return value === null || value === undefined || value === '' || (typeof value === 'number' && Number.isNaN(value));
}

function compareValues(a: unknown, b: unknown): number {
  if (typeof a === 'number' && typeof b === 'number') return a - b;
  return String(a).localeCompare(String(b), 'en', { numeric: true, sensitivity: 'base' });
}

export default function DataTable<T>({
  caption,
  columns,
  rows,
  rowKey,
  defaultSort,
  selectable,
  dense,
  emptyMessage,
  captionHidden,
  className,
}: DataTableProps<T>) {
  const [sort, setSort] = useState<SortState | null>(defaultSort ?? null);

  const sorted = useMemo(() => {
    if (!sort) return rows;
    const column = columns.find((c) => c.key === sort.key);
    if (!column) return rows;
    const valueOf = (row: T): unknown =>
      column.sortValue ? column.sortValue(row) : (row as unknown as Record<string, unknown>)[column.key];
    const sign = sort.dir === 'asc' ? 1 : -1;
    return rows
      .map((row, index) => ({ row, index, value: valueOf(row) }))
      .sort((x, y) => {
        const xn = isNil(x.value);
        const yn = isNil(y.value);
        if (xn || yn) return xn && yn ? x.index - y.index : xn ? 1 : -1;
        const c = compareValues(x.value, y.value);
        return c === 0 ? x.index - y.index : c * sign;
      })
      .map((entry) => entry.row);
  }, [rows, columns, sort]);

  const toggleSort = (key: string) => {
    setSort((prev) => (prev && prev.key === key ? { key, dir: prev.dir === 'asc' ? 'desc' : 'asc' } : { key, dir: 'asc' }));
  };

  const toggleSelect = (key: string) => {
    if (!selectable) return;
    const { selected, max, onChange } = selectable;
    if (selected.includes(key)) {
      onChange(selected.filter((k) => k !== key));
      return;
    }
    let next = [...selected, key];
    if (max !== undefined && max > 0 && next.length > max) next = next.slice(next.length - max);
    onChange(next);
  };

  const colSpan = columns.length + (selectable ? 1 : 0);

  return (
    <div className={cx('table-wrap', className)}>
      <table className={cx('data', dense && 'data-dense')}>
        <caption className={captionHidden ? 'sr-only' : 'table-caption'}>{caption}</caption>
        <thead>
          <tr>
            {selectable ? (
              <th scope="col" className="col-select">
                <span className="sr-only">Select</span>
              </th>
            ) : null}
            {columns.map((column) => {
              const active = sort?.key === column.key;
              const ariaSort = active ? (sort.dir === 'asc' ? 'ascending' : 'descending') : 'none';
              return (
                <th
                  key={column.key}
                  scope="col"
                  className={cx(column.numeric && 'num')}
                  aria-sort={ariaSort}
                  style={column.width ? { width: column.width } : undefined}
                  title={column.title}
                >
                  <button type="button" className="th-sort" onClick={() => toggleSort(column.key)}>
                    {column.header}
                    <span className="sort-glyph" aria-hidden="true">
                      {active ? (sort.dir === 'asc' ? '▲' : '▼') : ''}
                    </span>
                  </button>
                </th>
              );
            })}
          </tr>
        </thead>
        <tbody>
          {sorted.length === 0 ? (
            <tr>
              <td colSpan={colSpan} className="table-empty">
                {emptyMessage ?? 'No rows'}
              </td>
            </tr>
          ) : (
            sorted.map((row) => {
              const key = rowKey(row);
              const isSelected = selectable ? selectable.selected.includes(key) : false;
              return (
                <tr key={key} className={cx(isSelected && 'is-selected')} aria-selected={selectable ? isSelected : undefined}>
                  {selectable ? (
                    <td className="col-select">
                      <input type="checkbox" checked={isSelected} onChange={() => toggleSelect(key)} aria-label={`Select ${key}`} />
                    </td>
                  ) : null}
                  {columns.map((column) => (
                    <td key={column.key} className={cx(column.numeric && 'num')}>
                      {column.render ? column.render(row) : cellText((row as unknown as Record<string, unknown>)[column.key])}
                    </td>
                  ))}
                </tr>
              );
            })
          )}
        </tbody>
      </table>
    </div>
  );
}
