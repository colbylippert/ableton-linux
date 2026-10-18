import { Badge, HeroFigure } from 'profiler-dashboard';

/** A gain that clears the A/A noise: the only case where the figure wears the success colour. */
export const SignificantGain = () => (
  <HeroFigure
    label="Cumulative gain"
    value="▲ 12.3%"
    direction="better"
    significant
    sub="Late blocks / min, median of 2 Sets vs baseline 2026-10-17 20:44"
    chip={<Badge kind="significance" value="beyond noise" status="good" icon="▲" title="Improvement larger than 2 × the A/A spread" />}
    kept={1}
  />
);

/** An improvement inside the noise band stays ink; the chip says why. */
export const ImprovementWithinNoise = () => (
  <HeroFigure
    label="Cumulative gain"
    value="▲ 2.4%"
    direction="better"
    significant={false}
    sub="Live CPU / core, median of 5 Sets vs baseline 2026-10-18 00:05"
    chip={<Badge kind="significance" value="within noise" status="warning" icon="≈" title="|Δ| ≤ 2 × the A/A spread" />}
    kept={0}
  />
);

/** The latest untraced runs against aa-focusrite-1: a median regression, still within the A/A spread. */
export const Regression = () => (
  <HeroFigure
    label="Cumulative gain"
    value="▼ 7.8%"
    direction="worse"
    sub="Live CPU / core, median of 5 Sets vs baseline 2026-10-18 00:05"
    chip={<Badge kind="significance" value="within noise" status="warning" icon="≈" title="|Δ| ≤ 2 × the A/A spread" />}
    kept={0}
  />
);

/** No baseline for the headline identity yet: the figure falls back to "—". */
export const NoBaseline = () => (
  <HeroFigure
    label="Cumulative gain"
    value="—"
    sub="Late blocks / min: no baseline or no latest value in the slice"
    chip={<Badge kind="significance" value="no A/A data" status="dim" icon="?" title="No A/A pairs for this identity: significance unknown" />}
    kept={0}
  />
);
