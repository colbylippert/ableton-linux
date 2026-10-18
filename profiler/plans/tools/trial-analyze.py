"""Score an ABAB trial against its pre-registered rule (run on the laptop).

usage: ssh ableton-laptop python3 - TRIAL [--rule t0003|t0004] [--spread-from T0002] < plans/tools/trial-analyze.py
       PROFILER_ROOT=<checkout>/profiler python trial-analyze.py TRIAL [...]   (local checkout; no run dirs)
Pairs are trial-<TRIAL>-A<i> / -B<i>, i = 1..3. The DSP A/A spreads come from --spread-from (default T0002,
i.e. aa-focusrite-1..3). Rules are registered in profiler/plans/resume-plan.md before each run:

t0003 (dropouts):
  (a) B has fewer PipeWire errors than its paired A in >= 8 of the 9 Set-pairs
  (b) total PipeWire errors at least 40 % lower in B
  (c) no Set's median DSP average worse in B by more than 2x its A/A spread
t0004 (P-core affinity; both arms PIPEASIO_REALTIME=1):
  PASS iff ([D] or [E]) and both guards
  [D] median DSP average lower in B by more than 2x the A/A spread on at least one heavy Set
  [E] total PipeWire errors in B <= 0.6 x A, one-sided binomial test of B given A + B at p < 0.05
  guard: no Set's median DSP average worse in B by more than 2x its spread
  guard: total PipeWire errors not higher in B
"""
import argparse
import glob
import json
import math
import os
import pathlib
import statistics

ap = argparse.ArgumentParser()
ap.add_argument('trial')
ap.add_argument('--rule', default='t0003', choices=['t0003', 't0004'])
ap.add_argument('--spread-from', default='T0002')
args = ap.parse_args()
trial = args.trial

root = pathlib.Path(os.environ.get('PROFILER_ROOT', pathlib.Path.home() / 'Projects/ableton-linux/profiler'))
runs = {}
for p in sorted((root / 'history/runs').glob(f'trial-{trial}-*.json')):
    d = json.loads(p.read_text())
    runs[d['run_id']] = d
ledger = [json.loads(l) for l in (root / 'ledger.jsonl').read_text().splitlines() if l.strip()]
ref = next(e for e in ledger if e['trial'] == args.spread_from)
spread = {s: v['aa_spread'] for s, v in ref['metrics']['per_set'].items()}

pairs = [(f'trial-{trial}-A{i}', f'trial-{trial}-B{i}') for i in (1, 2, 3)]
missing = [r for pair in pairs for r in pair if r not in runs]
if missing:
    raise SystemExit(f'missing history records: {missing}')

sets = sorted({s for r in runs.values() for s in r['sets']})

print(f'== {trial} ({args.rule}): identity checks')
for rid, r in sorted(runs.items(), key=lambda kv: kv[1]['started_at']):
    print(f"  {rid:18} {r['started_at'][:19]}  arm={r['arm']}  dur={r['duration_s']}s  trace={r['trace_mode']}"
          f"  switches={r['switches']}  harness={r['harness_sha'][:8]}  device={r['audio_device']}")
for key in ('harness_sha', 'audio_device', 'machine_id', 'duration_s', 'trace_mode'):
    vals = {str(r[key]) for r in runs.values()}
    print(f"  {key}: {'same' if len(vals) == 1 else 'DIFFERS ' + str(vals)}")
if args.rule == 't0003':
    bad_sw = [rid for rid, r in runs.items() if (r['arm'] == 'B') != (r['switches'].get('PIPEASIO_REALTIME') == '1')]
    print(f"  switch matches arm: {'yes' if not bad_sw else 'NO ' + str(bad_sw)}")
else:
    bad_sw = [rid for rid, r in runs.items() if r['switches'].get('PIPEASIO_REALTIME') != '1']
    print(f"  PIPEASIO_REALTIME=1 on both arms: {'yes' if not bad_sw else 'NO ' + str(bad_sw)}")

print('\n== PipeWire errors per Set-pair (A -> B)')
fewer = total_a = total_b = 0
n_pairs = 0
for s in sets:
    cells = []
    for a, b in pairs:
        ea = runs[a]['sets'][s]['pipewire_errors']
        eb = runs[b]['sets'][s]['pipewire_errors']
        total_a += ea
        total_b += eb
        n_pairs += 1
        fewer += eb < ea
        cells.append(f'{ea:>3} -> {eb:<3}{" fewer" if eb < ea else " -"}')
    print(f'  {s:20} ' + '   '.join(cells))
drop = (total_a - total_b) / total_a if total_a else 0.0
n = total_a + total_b
p_binom = sum(math.comb(n, k) for k in range(total_b + 1)) / 2 ** n if n else 1.0
print(f'  B fewer in {fewer} of {n_pairs} pairs; total {total_a} -> {total_b} ({drop:+.1%} lower); '
      f'one-sided binomial p = {p_binom:.4f}')

print('\n== DSP average median per Set (A vs B; 2x A/A spread)')
dsp_better = []
dsp_worse = []
per_set = {}
for s in sets:
    a_vals = [v for v in (runs[a]['sets'][s]['dsp_avg'] for a, _ in pairs) if v is not None]
    b_vals = [v for v in (runs[b]['sets'][s]['dsp_avg'] for _, b in pairs) if v is not None]
    if not a_vals or not b_vals:
        per_set[s] = {'a_median': None, 'b_median': None, 'aa_spread': None, 'delta': None, 'ratio_to_spread': None}
        print(f'  {s:20} no DSP meter')
        continue
    am, bm = statistics.median(a_vals), statistics.median(b_vals)
    sp = spread.get(s)
    delta = bm - am
    worse = sp is not None and delta > 2 * sp
    better = sp is not None and -delta > 2 * sp
    if worse:
        dsp_worse.append(s)
    if better:
        dsp_better.append(s)
    ratio = abs(delta) / sp if sp else None
    per_set[s] = {'a_median': round(am, 2), 'b_median': round(bm, 2), 'aa_spread': sp,
                  'delta': round(delta, 2), 'ratio_to_spread': None if ratio is None else round(ratio, 2)}
    print(f'  {s:20} A {am:6.2f}  B {bm:6.2f}  delta {delta:+6.2f}  spread {sp}  '
          f'ratio {"-" if ratio is None else f"{ratio:.2f}"}  {"WORSE" if worse else "BETTER" if better else "within"}')

print('\n== audio threads (from the run directories, when present)')
for a, b in pairs:
    for rid in (a, b):
        src = os.path.expanduser(runs[rid]['source_dir'])
        cells = []
        for f in sorted(glob.glob(f'{src}/sets/*/raw/proc-delta.json')):
            d = json.loads(pathlib.Path(f).read_text())
            set_name = f.split('/sets/')[1].split('/')[0].split('-', 1)[1].replace('Benchmark_', '')
            aff, wait, on_e = set(), 0.0, 0
            for proc in d['processes']:
                for t in proc.get('threads', []):
                    c = t.get('comm', '')
                    if c.startswith('AudioCalc') or c == 'pipeasio-rt':
                        aff.add(t.get('cpus_allowed_list'))
                        if c.startswith('AudioCalc'):
                            wait += (t.get('schedstat') or {}).get('run_delay_ns', 0) / 1e6
                            on_e += (t.get('processor_at_end') or 0) >= 12
            cells.append(f"{set_name}: cpus {','.join(sorted(x for x in aff if x))} wait {wait:.0f} ms E@end {on_e}")
        if cells:
            print(f'  {rid:16} ' + ' | '.join(cells))

if args.rule == 't0003':
    crit = {'a': fewer >= 8, 'b': total_a > 0 and drop >= 0.40, 'c': not dsp_worse}
    verdict = 'PASS' if all(crit.values()) else 'FAIL'
else:
    crit = {'D': bool(dsp_better), 'E': total_b <= 0.6 * total_a and p_binom < 0.05,
            'guard_dsp': not dsp_worse, 'guard_err': total_b <= total_a}
    verdict = 'PASS' if (crit['D'] or crit['E']) and crit['guard_dsp'] and crit['guard_err'] else 'FAIL'

print('\n== context (not part of the rule)')
for s in sets:
    for key in ('dsp_peak', 'live_cpu_pct_per_core', 'xruns'):
        a_vals = [runs[a]['sets'][s][key] for a, _ in pairs]
        b_vals = [runs[b]['sets'][s][key] for _, b in pairs]
        fmt = (lambda v: '-' if v is None else f'{v:.1f}') if key != 'xruns' else str
        print(f"  {s:20} {key:22} A {' '.join(fmt(v) for v in a_vals):24} B {' '.join(fmt(v) for v in b_vals)}")
cpu_a = statistics.median(v for v in (runs[a]['sets'][s]['live_cpu_pct_per_core'] for a, _ in pairs for s in sets) if v is not None)
cpu_b = statistics.median(v for v in (runs[b]['sets'][s]['live_cpu_pct_per_core'] for _, b in pairs for s in sets) if v is not None)
xr_a = sum(runs[a]['sets'][s]['xruns'] for a, _ in pairs for s in sets)
xr_b = sum(runs[b]['sets'][s]['xruns'] for _, b in pairs for s in sets)

print(f'\n== {trial} pre-registered rule ({args.rule}): {verdict}  {crit}')
print(json.dumps({'verdict_rule': verdict, 'criteria': crit, 'fewer_pairs': fewer, 'n_pairs': n_pairs,
                  'pipewire_errors': {'a': total_a, 'b': total_b, 'drop': round(drop, 3), 'p_binom': round(p_binom, 4)},
                  'per_set': per_set, 'cpu_live_pct': {'a': round(cpu_a, 1), 'b': round(cpu_b, 1)},
                  'xruns': {'a': xr_a, 'b': xr_b}}))
