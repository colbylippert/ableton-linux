import { DataTable, Sparkline } from 'profiler-dashboard';
import type { Column, SparklineProps } from 'profiler-dashboard';

type Slot = NonNullable<SparklineProps['slot']>;

const rows = { display: 'grid', gridTemplateColumns: '150px 120px auto', alignItems: 'center', gap: '6px 14px' };
const name = { color: 'var(--text-secondary)', fontSize: 13 };
const value = { fontSize: 13, fontVariantNumeric: 'tabular-nums' as const };

interface Trend {
  label: string;
  slot: Slot;
  values: number[];
  latest: string;
}

function TrendRows({ trends }: { trends: Trend[] }) {
  return (
    <div style={rows}>
      {trends.map((t) => (
        <div key={t.label} style={{ display: 'contents' }}>
          <span style={name}>{t.label}</span>
          <Sparkline values={t.values} slot={t.slot} label={t.label} />
          <span style={value}>{t.latest}</span>
        </div>
      ))}
    </div>
  );
}

/** Live CPU / core over the last 12 untraced runs (T0001 A1 → T0002 B3): gray body, latest point in the Set's hue. */
export const SetTrends = () => (
  <TrendRows
    trends={[
      { label: 'Zero', slot: 1, values: [36.6, 34.2, 38.5, 39.0, 38.5, 37.2, 38.0, 38.9, 38.6, 38.7, 38.5, 41.5], latest: '41.5%' },
      { label: 'Empty', slot: 2, values: [37.7, 39.4, 34.2, 34.3, 38.1, 39.8, 33.7, 41.8, 41.6, 38.2, 37.1, 34.5], latest: '34.5%' },
      { label: 'Inbuilts', slot: 3, values: [65.2, 67.0, 59.4, 58.5, 55.3, 65.4, 54.9, 63.3, 61.3, 64.7, 54.4, 63.0], latest: '63.0%' },
      { label: 'Max4Live', slot: 4, values: [68.2, 65.3, 65.8, 72.7, 65.9, 60.2, 69.6, 56.7, 64.2, 56.1, 68.4, 65.2], latest: '65.2%' },
      { label: 'VSTs', slot: 5, values: [51.8, 51.1, 50.5, 59.2, 63.7, 53.1, 58.7, 51.4, 56.6, 64.6, 58.3, 58.7], latest: '58.7%' },
    ]}
  />
);

/** Guard metrics: a clean series draws flat at mid-height; one early blip still shows. */
export const GuardMetricsFlatAndBlip = () => (
  <TrendRows
    trends={[
      { label: 'Xruns · Zero', slot: 1, values: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], latest: '0' },
      { label: 'PipeWire errors · Empty', slot: 2, values: [0, 2, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0], latest: '0' },
      { label: 'Xruns · Max4Live', slot: 4, values: [0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 0, 0], latest: '0' },
    ]}
  />
);

interface SiteRow {
  site: string;
  detail: string;
  slot: Slot;
  shares: number[];
}

// VSTs share of lost slack across b5b-verify-traced → b5c-verifier-traced → b5c-final-traced.
const SITES: SiteRow[] = [
  { site: 'NtWaitForSingleObject', detail: 'syscall · kernelbase.dll!WaitForSingleObject+0x49 <- Ableton Live 12 Trial.exe+0x4f8c119', slot: 1, shares: [0.1177, 0.9573, 0.9651] },
  {
    site: 'NtWaitForAlertByThreadId',
    detail: 'syscall · ntdll.dll!RtlWaitOnAddress+0x16d <- ntdll.dll!RtlSleepConditionVariableSRW+0x14b <- kernelbase.dll!SleepConditionVariableSRW+0x2c <- SpliceAbletonLive.vst3+0x559c60',
    slot: 3,
    shares: [0.2978, 0, 0],
  },
  { site: 'NtDelayExecution', detail: 'syscall · dwmapi.dll!DwmFlush+0x1b3 <- Ableton Live 12 Trial.exe+0x31f0886', slot: 4, shares: [0.1198, 0, 0] },
  { site: 'NtSetEvent', detail: 'syscall · kernelbase.dll!SetEvent+0xf <- Ableton Live 12 Trial.exe+0x33f587e', slot: 8, shares: [0.0258, 0.019, 0.0234] },
];

const pct = (v: number) => `${(v * 100).toFixed(1)}%`;

const COLUMNS: Column<SiteRow>[] = [
  {
    key: 'site',
    header: 'Call site',
    render: (r) => (
      <span>
        {r.site} <span className="mono muted" style={{ fontSize: 11 }}>{r.detail}</span>
      </span>
    ),
  },
  { key: 'latest', header: 'Latest share', numeric: true, render: (r) => pct(r.shares[r.shares.length - 1]!), sortValue: (r) => r.shares[r.shares.length - 1]! },
  { key: 'trend', header: 'Trend (3 traced runs)', render: (r) => <Sparkline values={r.shares} slot={r.slot} width={96} height={22} label={`${r.site} share`} /> },
];

/** Compact sparklines inside a call-site table, each in its call site's fixed hue. */
export const InTableCells = () => (
  <div style={{ maxWidth: 720 }}>
    <DataTable caption="VSTs call sites, share of lost slack" captionHidden columns={COLUMNS} rows={SITES} rowKey={(r) => r.detail} dense />
  </div>
);
