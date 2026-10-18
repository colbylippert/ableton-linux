/**
 * Hex mirror of `src/theme.css` for Recharts.
 *
 * SVG presentation attributes (`stroke`, `fill`) need concrete colours, so charts read
 * them from here while everything HTML reads the CSS tokens. The columns are the palettes
 * chosen in Claude Design: Spectrum (light) and Abyss (dark) (DESIGN.md §7, validator output
 * in §7.4). Change a value here only together with `theme.css`, and re-run the validator.
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
  /** Slots 1..8 in theme order (Spectrum: indigo, tangerine, teal, amber, pink, sky, violet, red). */
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

export const PALETTE: Readonly<Record<ThemeMode, PaletteTokens>> = {
  // Spectrum (Claude Design, 2026-10-17): cool indigo base, full-rainbow Set hues.
  light: {
    page: '#f3f5ff',
    surface1: '#ffffff',
    surface2: '#e8edff',
    textPrimary: '#0b1033',
    textSecondary: '#434a75',
    textMuted: '#666c94',
    grid: '#e1e6fa',
    axis: '#c3c9ea',
    border: 'rgba(11, 16, 51, 0.1)',
    deltaGoodText: '#047857',
    focus: '#4f46e5',
    series: ['#4f46e5', '#ff6b35', '#00c2a8', '#ffc233', '#ff4fa3', '#22a6f2', '#9b5de5', '#f2545b'],
    seriesDim: '#8a8fb0',
    seq: SEQ,
    divNeg: '#f2545b',
    divMid: '#e8edff',
    divPos: '#4f46e5',
    ordBefore: '#a5a1f5',
    ordAfter: '#3730a3',
    status: { good: '#00b37e', warning: '#ffc233', serious: '#ff8a3d', critical: '#ef4444' },
  },
  // Abyss (Claude Design, 2026-10-17): deep ocean teal, cyan accents.
  dark: {
    page: '#061419',
    surface1: '#0c2129',
    surface2: '#133039',
    textPrimary: '#eafcff',
    textSecondary: '#aed3db',
    textMuted: '#7fa5ae',
    grid: '#1a3a44',
    axis: '#255059',
    border: 'rgba(255, 255, 255, 0.12)',
    deltaGoodText: '#4be3a0',
    focus: '#3fe0e6',
    // slots 3 and 6 swapped from the Abyss template: Inbuilts periwinkle vs Max4Live amber passes the CVD check
    series: ['#3fe0e6', '#ff8a5c', '#7aa8ff', '#ffd257', '#ff74b8', '#a6e85a', '#c79bff', '#ff6b72'],
    seriesDim: '#5f7f87',
    seq: SEQ,
    divNeg: '#ff6b72',
    divMid: '#1a3a44',
    divPos: '#3fe0e6',
    ordBefore: '#1f7f86',
    ordAfter: '#8ff2f5',
    status: { good: '#2ed398', warning: '#ffd257', serious: '#ffa05c', critical: '#ff5c5c' },
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
