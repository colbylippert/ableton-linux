/**
 * The audio device is part of a run's identity: runs on different interfaces (the laptop's
 * built-in speaker vs the USB Focusrite) never share a baseline or a trend line.
 */
import { describe, expect, it } from 'vitest';
import { identityKeyOf, identityOf, resolveBaseline, sameIdentity } from './gains';
import type { Run } from './types';

const SPEAKER = 'alsa_output.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Speaker__sink';
const FOCUSRITE = 'alsa_output.usb-Focusrite_Scarlett_2i4_USB-00.pro-output-0';

function run(overrides: Partial<Run>): Run {
  return {
    run_id: 'r',
    tag: 't',
    started_at: '2026-10-17T12:00:00Z',
    machine_id: 'm1',
    hostname: 'abletonlinux',
    virtualization: 'none',
    structure: 'benchmark',
    scenario: null,
    trace_mode: 'off',
    duration_s: 30,
    runtime: { dist_version: '2026.08.28.1', source_tree_sha: null, dev_info: null },
    switches: {},
    harness_sha: null,
    commit: null,
    trial: null,
    arm: null,
    source_dir: null,
    sets: {},
    ...overrides,
  };
}

describe('audio device identity', () => {
  it('splits identities by device and treats absent and null alike', () => {
    const speaker = run({ run_id: 'speaker', audio_device: SPEAKER });
    const focusrite = run({ run_id: 'focusrite', audio_device: FOCUSRITE });
    const legacy = run({ run_id: 'legacy' });
    expect(sameIdentity(speaker, focusrite)).toBe(false);
    expect(identityKeyOf(identityOf(speaker))).not.toBe(identityKeyOf(identityOf(focusrite)));
    expect(sameIdentity(legacy, run({ run_id: 'legacy2', audio_device: null }))).toBe(true);
    expect(sameIdentity(legacy, focusrite)).toBe(false);
  });

  it('resolves the device-specific baseline and never borrows another device', () => {
    const speaker = run({ run_id: 'speaker', audio_device: SPEAKER, started_at: '2026-10-17T03:42:59Z' });
    const focusrite = run({ run_id: 'focusrite', audio_device: FOCUSRITE, started_at: '2026-10-17T20:30:00Z' });
    const runs = [speaker, focusrite];
    const both = { m1: { 'benchmark/-': 'speaker', [`benchmark/- [${FOCUSRITE}]`]: 'focusrite' } };
    expect(resolveBaseline(runs, both, identityOf(focusrite))?.run_id).toBe('focusrite');
    expect(resolveBaseline(runs, both, identityOf(speaker))?.run_id).toBe('speaker');
    // Only the old device-less key: the Focusrite identity falls back to its own runs.
    const legacyOnly = { m1: { 'benchmark/-': 'speaker' } };
    expect(resolveBaseline(runs, legacyOnly, identityOf(focusrite))?.run_id).toBe('focusrite');
  });
});
