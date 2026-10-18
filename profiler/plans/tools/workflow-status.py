"""Show the progress of the newest (or a named) Claude Code workflow run.

  python C:\\src\\AbletonLinux\\plans\\tools\\workflow-status.py            one snapshot
  python C:\\src\\AbletonLinux\\plans\\tools\\workflow-status.py --watch 30 refresh every 30 s (Ctrl+C stops)
  python C:\\src\\AbletonLinux\\plans\\tools\\workflow-status.py --laptop   also show what the laptop is doing
  python C:\\src\\AbletonLinux\\plans\\tools\\workflow-status.py wf_42af6292-9d3

For each agent: its stage, whether it has reported, and how long ago it last wrote anything.
For a running agent, also its current step. An agent that has written nothing for a long time
is either waiting on one long command (shown as "waiting on") or stuck.
"""
import argparse
import glob
import json
import os
import subprocess
import sys
import time

PROJECT = os.path.expanduser(r"~\.claude\projects\c--src-AbletonLinux")

LAPTOP_SCRIPT = r"""
now=$(date +%s)
n=$(find ~/.local/share/profiler/runs /tmp/profiler-b5b -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)
[ -n "$n" ] && echo "  newest run file: $(( (now - n) / 60 )) min ago"
echo "  load: $(cut -d' ' -f1-3 /proc/loadavg)"
flock -n ~/.local/state/profiler/live-session.lock true && echo "  session lock: free" || echo "  session lock: held"
p=$(pgrep -af 'Ableton Live|bpftrace|wine-trace|bench-suite|podman|make' | cut -c1-90 | head -4)
[ -n "$p" ] && echo "$p" | sed 's/^/  running: /' || echo "  running: nothing heavy"
echo "  kernel errors since boot: $(sudo -n dmesg 2>/dev/null | grep -c -E 'BUG:|Oops')"
"""


def read_jsonl(path):
    rows = []
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if line.strip():
                    try:
                        rows.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
    except FileNotFoundError:
        pass
    return rows


def ago(ts):
    m = int((time.time() - ts) / 60)
    return "just now" if m < 1 else f"{m} min ago" if m < 120 else f"{m // 60} h {m % 60} min ago"


def current_step(transcript):
    """('waiting on' | 'last step', description) from the agent's transcript."""
    calls, answered, last_text = {}, set(), ""
    for row in read_jsonl(transcript):
        content = (row.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for c in content:
            kind = c.get("type")
            if kind == "tool_use":
                inp = c.get("input") or {}
                desc = inp.get("description") or inp.get("command") or inp.get("file_path") or inp.get("pattern") or ""
                calls[c.get("id")] = f"{c.get('name')}: {' '.join(str(desc).split())[:110]}"
            elif kind == "tool_result":
                answered.add(c.get("tool_use_id"))
            elif kind == "text" and c.get("text", "").strip():
                last_text = " ".join(c["text"].split())[:110]
    pending = [v for k, v in calls.items() if k not in answered]
    if pending:
        return "waiting on", pending[-1]
    if calls:
        return "last step", list(calls.values())[-1] + (f'  ("{last_text}")' if last_text else "")
    return "last step", last_text or "(nothing yet)"


def snapshot(run_dir, laptop):
    journal = os.path.join(run_dir, "journal.jsonl")
    rows = read_jsonl(journal)
    started = [(r["agentId"], r.get("label", ""), r.get("phase", "")) for r in rows if r.get("type") == "started" and r.get("agentId")]
    reported = {r.get("agentId") for r in rows if r.get("type") == "result"}
    lines = [f"workflow {os.path.basename(run_dir)}   (journal updated {ago(os.path.getmtime(journal))})"]
    for aid, label, phase in started:
        tr = os.path.join(run_dir, f"agent-{aid}.jsonl")
        last = os.path.getmtime(tr) if os.path.exists(tr) else None
        state = "reported" if aid in reported else "RUNNING"
        lines.append(f"  {phase:<7} {label:<28} {state:<9} last wrote {ago(last) if last else '?'}")
        if aid not in reported and last:
            kind, desc = current_step(tr)
            lines.append(f"          {kind}: {desc}")
            idle = (time.time() - last) / 60
            if idle > 20:
                lines.append(f"          ! nothing written for {idle:.0f} min: a long command or stuck; check the laptop (--laptop)")
    if started and all(a in reported for a, _, _ in started):
        lines.append("  no agent running: the workflow is between stages or finished")
    if laptop:
        try:
            out = subprocess.run(["ssh", "-o", "ConnectTimeout=8", "ableton-laptop", "bash -s"],
                                 input=LAPTOP_SCRIPT.encode(), capture_output=True, timeout=60)
            lines.append("laptop:")
            lines.append((out.stdout or out.stderr).decode("utf-8", "replace").rstrip())
        except Exception as exc:
            lines.append(f"laptop: unreachable ({exc})")
    return "\n".join(lines)


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="replace")
    ap = argparse.ArgumentParser(description="Progress of a Claude Code workflow run")
    ap.add_argument("run_id", nargs="?", help="e.g. wf_42af6292-9d3 (default: the most recently active run)")
    ap.add_argument("--watch", type=int, metavar="SEC", help="refresh every SEC seconds")
    ap.add_argument("--laptop", action="store_true", help="also show what the laptop is doing")
    a = ap.parse_args()
    runs = glob.glob(os.path.join(PROJECT, "*", "subagents", "workflows", a.run_id or "wf_*"))
    runs = [r for r in runs if os.path.exists(os.path.join(r, "journal.jsonl"))]
    if not runs:
        print("no workflow runs found under", PROJECT)
        return 1
    run_dir = max(runs, key=lambda r: max(os.path.getmtime(p) for p in glob.glob(os.path.join(r, "*"))))
    while True:
        text = snapshot(run_dir, a.laptop)
        if a.watch:
            os.system("cls" if os.name == "nt" else "clear")
            print(time.strftime("%H:%M:%S"), "\n" + text)
            time.sleep(a.watch)
        else:
            print(text)
            return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        pass
