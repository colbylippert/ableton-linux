/**
 * Library entry for the dashboard's component set — what `npm run build:lib` compiles into
 * dist-lib/ and the design-sync converter bundles for Claude Design. The app itself does not
 * use this file (src/main.tsx is its entry). The theme tokens come along so every component
 * renders with the dashboard's own colours, type and spacing.
 */
import './theme.css';

export { default as Badge, EnvironmentBadge } from './components/Badge';
export type { BadgeProps, EnvironmentBadgeProps, BadgeStatus, BadgeKind } from './components/Badge';
export { default as KpiTile, HeroFigure, Sparkline } from './components/KpiTile';
export type { KpiTileProps, HeroFigureProps, SparklineProps, KpiDelta } from './components/KpiTile';
export { default as NoTimingRibbon } from './components/NoTimingRibbon';
export type { NoTimingRibbonProps } from './components/NoTimingRibbon';
export { default as DataTable } from './components/DataTable';
export type { DataTableProps, Column, SortState } from './components/DataTable';
export { default as RunTable } from './components/RunTable';
export type { RunTableProps } from './components/RunTable';
export { default as FilterBar } from './components/FilterBar';
export type { FilterBarProps, FilterOptions } from './components/FilterBar';
export { default as ChartFrame } from './components/ChartFrame';
export type { ChartFrameProps, ChartView } from './components/ChartFrame';
export { default as TrendChart } from './components/TrendChart';
export type { TrendChartProps, TrendSeries, TrendPoint, TrendMarker, TrendBaseline, TrendNoiseBand } from './components/TrendChart';
export { DeltaBars, DeltaBarsTable } from './components/DeltaBars';
export type { DeltaBarsProps, DeltaBarsTableProps, DeltaBarsNames } from './components/DeltaBars';
export { PairedDots, PairedDotsTable } from './components/PairedDots';
export type { PairedDotsProps, PairedDotsTableProps, PairedDotsPair } from './components/PairedDots';
export { CallSiteTrend, CallSiteTrendTable } from './components/CallSiteTrend';
export type { CallSiteTrendProps, CallSiteTrendTableProps } from './components/CallSiteTrend';
export { default as CompareDrawer } from './components/CompareDrawer';
export type { CompareDrawerProps } from './components/CompareDrawer';
export { default as TrialCard } from './components/TrialCard';
export type { TrialCardProps } from './components/TrialCard';
