/**
 * Hex mirror of `src/theme.css` for Recharts.
 *
 * SVG presentation attributes (`stroke`, `fill`) need concrete colours, so charts read
 * them from here while everything HTML reads the CSS tokens. Both columns are the dataviz
 * reference palette (DESIGN.md §7; validator output for light and dark in §7.4). Change a
 * value here only together with `theme.css` and re-run the validator.
 *
 * `useThemeMode()` follows the viewer's toggle (`<html data-theme>`) and the OS preference
 * so a theme switch re-renders every chart with the matching column.
 */
import { useEffect, useState } from 'react';

export type ThemeMode = 'light' | 'dark';

/** Categorical slot (fixed order, never cycled) or the de-emphasis gray. */
export type SeriesSlot = 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 'dim';

export type StatusKey = 'good' | 'warning' | 'serious' | 'critical';

export interface PaletteTokens {
  page: string;
  surface1: string;
  surface2: string;
  textPrimary: string;
  textSecondary: string;
  textMuted: string;
  grid: string;
  axis: string;
  border: string;
  deltaGoodText: string;
  focus: string;
  /** Slots 1..8 in theme order: blue, orange, aqua, yellow, magenta, green, violet, red. */
  series: readonly [string, string, string, string, string, string, string, string];
  seriesDim: string;
  /** Blue sequential ramp, steps 100..700. */
  seq: Readonly<Record<100 | 150 | 200 | 250 | 300 | 350 | 400 | 450 | 500 | 550 | 600 | 650 | 700, string>>;
  divNeg: string;
  divMid: string;
  divPos: string;
  ordBefore: string;
  ordAfter: string;
  status: Readonly<Record<StatusKey, string>>;
}

const SEQ = {
  100: '#cde2fb',
  150: '#b7d3f6',
  200: '#9ec5f4',
  250: '#86b6ef',
  300: '#6da7ec',
  350: '#5598e7',
  400: '#3987e5',
  450: '#2a78d6',
  500: '#256abf',
  550: '#1c5cab',
  600: '#184f95',
  650: '#104281',
  700: '#0d366b',
} as const;

const STATUS = { good: '#0ca30c', warning: '#fab219', serious: '#ec835a', critical: '#d03b3b' } as const;

export const PALETTE: Readonly<Record<ThemeMode, PaletteTokens>> = {
  light: {
    page: '#f9f9f7',
    surface1: '#fcfcfb',
    surface2: '#f0efec',
    textPrimary: '#0b0b0b',
    textSecondary: '#52514e',
    textMuted: '#898781',
    grid: '#e1e0d9',
    axis: '#c3c2b7',
    border: 'rgba(11, 11, 11, 0.1)',
    deltaGoodText: '#006300',
    focus: '#2a78d6',
    series: ['#2a78d6', '#eb6834', '#1baf7a', '#eda100', '#e87ba4', '#008300', '#4a3aa7', '#e34948'],
    seriesDim: '#898781',
    seq: SEQ,
    divNeg: '#e34948',
    divMid: '#f0efec',
    divPos: '#2a78d6',
    ordBefore: '#86b6ef',
    ordAfter: '#1c5cab',
    status: STATUS,
  },
  dark: {
    page: '#0d0d0d',
    surface1: '#1a1a19',
    surface2: '#262624',
    textPrimary: '#ffffff',
    textSecondary: '#c3c2b7',
    textMuted: '#898781',
    grid: '#2c2c2a',
    axis: '#383835',
    border: 'rgba(255, 255, 255, 0.1)',
    deltaGoodText: '#0ca30c',
    focus: '#3987e5',
    series: ['#3987e5', '#d95926', '#199e70', '#c98500', '#d55181', '#008300', '#9085e9', '#e66767'],
    seriesDim: '#898781',
    seq: SEQ,
    divNeg: '#e66767',
    divMid: '#383835',
    divPos: '#3987e5',
    ordBefore: '#9ec5f4',
    ordAfter: '#3987e5',
    status: STATUS,
  },
};

/** Hex for a slot in the given mode (`'dim'` → the de-emphasis gray). */
export function seriesHex(slot: SeriesSlot, mode: ThemeMode): string {
  const pal = PALETTE[mode];
  return slot === 'dim' ? pal.seriesDim : (pal.series[slot - 1] ?? pal.seriesDim);
}

/** CSS custom property reference for a slot, for HTML/inline-SVG contexts (`style`). */
export function seriesVar(slot: SeriesSlot): string {
  return slot === 'dim' ? 'var(--series-dim)' : `var(--series-${slot})`;
}

export function statusHex(status: StatusKey, mode: ThemeMode): string {
  return PALETTE[mode].status[status];
}

/** Resolves the mode the page is showing right now: the viewer's toggle wins over the OS. */
export function currentThemeMode(): ThemeMode {
  if (typeof document === 'undefined') return 'light';
  const stamp = document.documentElement.getAttribute('data-theme');
  if (stamp === 'dark') return 'dark';
  if (stamp === 'light') return 'light';
  if (typeof window !== 'undefined' && typeof window.matchMedia === 'function') {
    try {
      return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
    } catch {
      return 'light';
    }
  }
  return 'light';
}

/**
 * Watches `<html data-theme>` (viewer toggle) and `prefers-color-scheme` (OS) so charts
 * re-render with the matching palette column. Safe under jsdom (no matchMedia).
 */
export function useThemeMode(): ThemeMode {
  const [mode, setMode] = useState<ThemeMode>(currentThemeMode);
  useEffect(() => {
    if (typeof document === 'undefined') return undefined;
    const update = () => setMode(currentThemeMode());
    const observer = typeof MutationObserver !== 'undefined' ? new MutationObserver(update) : null;
    observer?.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
    let media: MediaQueryList | null = null;
    try {
      media = typeof window.matchMedia === 'function' ? window.matchMedia('(prefers-color-scheme: dark)') : null;
    } catch {
      media = null;
    }
    media?.addEventListener?.('change', update);
    update();
    return () => {
      observer?.disconnect();
      media?.removeEventListener?.('change', update);
    };
  }, []);
  return mode;
}
