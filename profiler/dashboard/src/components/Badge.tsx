/**
 * Badge / chip: the one place status colours are allowed to appear next to text.
 *
 * Rules (DESIGN.md §1, §5, §7.2): the status colour sits on the dot only, the label is
 * always ink, and every status ships with an icon + label so colour never carries meaning
 * alone. Mappings: verdict keep → good ✓ · revert → critical ✗ · inconclusive → warning ≈ ·
 * tooling / mechanism-confirmed → dim; significance beyond & better → good ▲ · beyond &
 * worse → critical ▼ · within → warning ≈ · unknown → dim ?.
 */
import type { Significance, TraceMode, Verdict, Virtualization } from '../data/types';
import './components.css';

export type BadgeStatus = 'good' | 'warning' | 'serious' | 'critical' | 'dim' | 'none';

export type BadgeKind = 'verdict' | 'significance' | 'environment' | 'structure' | 'trace' | 'arm' | 'switch' | 'neutral';

export interface BadgeProps {
  kind: BadgeKind;
  value: string;
  status?: BadgeStatus;
  /** Overrides the status glyph. An empty string suppresses it. */
  icon?: string;
  title?: string;
  className?: string;
}

/** Direction of a delta after the sign flip (positive = improvement). */
export type DeltaDirection = 'better' | 'worse' | 'flat' | 'neutral';

/** Glyph paired with each status; `none` has no glyph unless the caller passes one. */
export const STATUS_ICON: Readonly<Record<BadgeStatus, string>> = {
  good: '✓',
  warning: '≈',
  serious: '⚠',
  critical: '✗',
  dim: '·',
  none: '',
};

function cx(...parts: (string | false | null | undefined)[]): string {
  return parts.filter(Boolean).join(' ');
}

export default function Badge({ kind, value, status = 'none', icon, title, className }: BadgeProps) {
  const glyph = icon ?? STATUS_ICON[status];
  return (
    <span className={cx('chip', `chip-${status}`, className)} data-kind={kind} data-status={status} title={title}>
      <span className="dot" aria-hidden="true" />
      {glyph ? (
        <span className="chip-icon" aria-hidden="true">
          {glyph}
        </span>
      ) : null}
      <span className="chip-label">{value}</span>
    </span>
  );
}

export function verdictBadge(verdict: Verdict): BadgeProps {
  switch (verdict) {
    case 'keep':
      return { kind: 'verdict', value: 'keep', status: 'good', icon: '✓', title: 'Kept: the change cleared the noise gate' };
    case 'revert':
      return { kind: 'verdict', value: 'revert', status: 'critical', icon: '✗', title: 'Reverted' };
    case 'inconclusive':
      return { kind: 'verdict', value: 'inconclusive', status: 'warning', icon: '≈', title: 'Inconclusive: within the A/A noise' };
    case 'tooling':
      return { kind: 'verdict', value: 'tooling', status: 'dim', icon: '·', title: 'Tooling change, no performance claim' };
    case 'mechanism-confirmed':
      return { kind: 'verdict', value: 'mechanism confirmed', status: 'dim', icon: '·', title: 'Mechanism confirmed, outcome not claimed' };
    default:
      return { kind: 'verdict', value: String(verdict), status: 'dim', icon: '·' };
  }
}

export function significanceBadge(significance: Significance, direction: DeltaDirection): BadgeProps {
  if (direction === 'neutral') {
    return { kind: 'significance', value: 'informational', status: 'none', icon: '·', title: 'Neutral metric: no direction, no significance' };
  }
  if (significance === 'beyond') {
    if (direction === 'worse') {
      return { kind: 'significance', value: 'beyond noise', status: 'critical', icon: '▼', title: 'Regression larger than 2 × the A/A spread' };
    }
    if (direction === 'better') {
      return { kind: 'significance', value: 'beyond noise', status: 'good', icon: '▲', title: 'Improvement larger than 2 × the A/A spread' };
    }
  }
  if (significance === 'within' || significance === 'beyond') {
    return { kind: 'significance', value: 'within noise', status: 'warning', icon: '≈', title: '|Δ| ≤ 2 × the A/A spread' };
  }
  return { kind: 'significance', value: 'no A/A data', status: 'dim', icon: '?', title: 'No A/A pairs for this identity: significance unknown' };
}

export function traceBadge(mode: TraceMode): BadgeProps {
  if (mode === 'off') return { kind: 'trace', value: 'untraced', status: 'none', icon: '', title: 'Outcome metrics are authoritative' };
  return { kind: 'trace', value: `traced · ${mode}`, status: 'none', icon: '', title: 'Interface metrics only; outcome metrics carry tracing overhead' };
}

export function environmentBadge(virtualization: Virtualization): BadgeProps {
  if (virtualization === 'none') return { kind: 'environment', value: 'bare metal', status: 'none', icon: '', title: 'Bare metal: timing claims allowed' };
  return { kind: 'environment', value: `virtualised · ${virtualization}`, status: 'serious', icon: '⚠', title: 'Virtualised host: no timing claims' };
}

export interface EnvironmentBadgeProps {
  machineId: string;
  hostname: string;
  virtualization: Virtualization;
}

/** Machine identity line: environment chip + hostname + machine id. */
export function EnvironmentBadge({ machineId, hostname, virtualization }: EnvironmentBadgeProps) {
  return (
    <span className="env-badge" data-virtualization={virtualization}>
      <Badge {...environmentBadge(virtualization)} />
      <span className="env-host">
        {hostname} <span className="mono muted">({machineId})</span>
      </span>
    </span>
  );
}
