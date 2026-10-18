# Plans, designs and findings

The planning record of the Wine interface profiler: what was planned, how each part was
designed, what the investigations found, and the block-by-block execution log. The code these
documents describe lives in the rest of `profiler/` and in `patches/0108-…` / `patches/pipeasio/0017-…`.

| File | What it is |
|---|---|
| `wine-interface-profiler-plan.md` | The approved plan: goals, phase map, workstreams A–H, milestones, risks |
| `design-A-setup-and-dev-loop.md` | Machine setup script, root helper, golden snapshots, Wine dev loop |
| `design-B-tracer-and-probes.md` | USDT trace points, the eBPF tracer, symbolizer, output files |
| `design-C-control-suite-agent-loop.md` | AbletonOSC control layer, scenarios, bench integration, agent loop |
| `research-*.md` | Phase 0 research: the build system, installing and launching Live, the bench suite and telemetry |
| `resume-plan.md` | The block log (B0–B7, B5b, B5c), the strategy and the "proving gains" record — the current state lives here |
| `findings/b5-tproto-rootcause.md` | Root cause of the tracer crashes: kernel 7.2's per-CPU private BPF stack and preemptible uprobe programs |
| `findings/b5-kernel-oops-24441.txt` | The kernel oops that led to it |
| `findings/wf*.json` | Review findings from the first implementation workflows |
| `workflows/*.js` | The multi-agent workflow scripts that implemented each block (Claude Code workflows) |
| `tools/workflow-status.py` | Shows the progress of a running workflow (Windows side) |
