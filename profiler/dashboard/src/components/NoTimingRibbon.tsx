/**
 * "No timing claims" ribbon for virtualised runs (DESIGN.md §1 rule 2). Status colour
 * (serious) sits on the border and the icon; the text stays ink. Renders nothing for bare
 * metal so callers can pass the slice's environment straight through.
 */
import type { Virtualization } from '../data/types';
import './components.css';

export interface NoTimingRibbonProps {
  virtualization: Virtualization;
  hostname?: string | null;
  runs?: number;
}

export default function NoTimingRibbon({ virtualization, hostname, runs }: NoTimingRibbonProps) {
  if (virtualization === 'none') return null;
  const parts: string[] = [`virtualised host (${virtualization})`];
  if (hostname) parts.push(hostname);
  if (runs !== undefined) parts.push(`${runs} run${runs === 1 ? '' : 's'} in this slice`);
  return (
    <div className="ribbon ribbon-notiming" role="status" data-virtualization={virtualization}>
      <span className="icon" aria-hidden="true">
        ⚠
      </span>
      <span>
        <strong>NO TIMING CLAIMS</strong> — {parts.join(' · ')}. Compare only with runs from the same virtualised host.
      </span>
    </div>
  );
}
