#!/usr/bin/env bash
# evolve-timed.sh — timed, append-only history harness for `daksh evolve`.
#
# `evolve --all` is the binding DOD gate on EVERY check PR and is still the long
# pole (post-EVOLVE-PERF −69%, --all is ~8.5min). This wrapper MEASURES each run
# and appends a timestamped row to a rolling cross-run history, so a timing
# regression is visible the moment it lands — measure, don't assert (same
# discipline as the −69% win). Industry precedent: pytest-benchmark / hyperfine
# history JSON, CI build-time dashboards — append-only timed history keyed by commit.
#
# Builds ENTIRELY on existing data — no new engine instrumentation:
#   - wall-clock: bash start/end around the run (the real end-to-end cost).
#   - per-package timing/score/grade/errors: harvested from the engine's OWN
#     `--report json` output, whose `EvolveReport.to_dict()` already emits
#     `duration_ms` + `score` + `grade` + `error_count` per package
#     (engine.py:81-95). NOTE: the per-pkg `.daksh/evolve-log.json` does NOT
#     persist per-package timing (only score/grade/errors), so `--report json`
#     is the accurate source for the trend line — verified at HEAD 2026-06-24.
#
# Usage:
#   util/scripts/build/evolve-timed.sh [TARGET] [LABEL]
#     TARGET  package name / path, or "--all" (default --all)
#     LABEL   optional run label (e.g. "post-#1512") — tags the history row
#
# Output:
#   - appends one row to util/scripts/.probe-results/evolve-timing-history.json
#   - prints a per-package scoreboard + the delta vs the previous matching-target row
#
# Requires: daksh-cli, python3, git. READ-ONLY w.r.t. the repo (runs evolve; writes
# only the history JSON under .probe-results/).
set -euo pipefail

# REPO/CLI are pinned to the MAIN checkout BY DESIGN — not a portability miss.
# The evolve engine discovers framework checks by FILESYSTEM PATH
# (config.gyanam_dir/framework/lochan/packages), NOT via sys.path/PYTHONPATH, so
# a worktree's in-flight diff CANNOT be measured for framework checks — a worktree
# run would still execute the primary tree's check code. Therefore framework-check
# timing is captured AT MERGE, against main. (Adding a --worktree flag would falsely
# claim to measure a diff while running main code — worse than none.) This matches
# the sibling probes (probe-chat-writes.sh / probe-show-users-perf.sh), which pin
# the same REPO root. Single dev machine; the path is stable.
REPO="/Users/srinivasnukala/Dropbox/Sites/docker/gyanam"
CLI="framework/lochan/packages/daksh/daksh-cli"
TARGET="${1:---all}"
RUN_LABEL="${2:-}"
cd "$REPO"

RESULTS_DIR="util/scripts/.probe-results"
HISTORY_FILE="$RESULTS_DIR/evolve-timing-history.json"
mkdir -p "$RESULTS_DIR"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT

GIT_SHA="$(git -C "$REPO/framework/lochan" rev-parse --short HEAD 2>/dev/null || echo unknown)"

# Build the evolve argv. A package target is positional; --all is a flag.
if [ "$TARGET" = "--all" ]; then
  EVOLVE_ARGS=(evolve --all --report json)
else
  EVOLVE_ARGS=(evolve "$TARGET" --report json)
fi

echo "== evolve-timed :: target='$TARGET' :: sha=$GIT_SHA :: label='${RUN_LABEL:-<none>}' =="
echo "  running: $CLI ${EVOLVE_ARGS[*]}  (wall-clock + per-pkg duration_ms from --report json)"
echo

# ---- timed run: wall-clock around the engine; capture the JSON report ----
START="$(python3 -c 'import time; print(time.time())')"
"./$CLI" "${EVOLVE_ARGS[@]}" > "$OUT/report.json" 2> "$OUT/stderr.log" || EVOLVE_RC=$?
END="$(python3 -c 'import time; print(time.time())')"
EVOLVE_RC="${EVOLVE_RC:-0}"
WALL_S="$(python3 -c "print(round($END - $START, 1))")"

echo "  wall-clock: ${WALL_S}s   (evolve exit=$EVOLVE_RC)"
echo

# ---- parse the JSON report, append a history row, print scoreboard + delta ----
python3 - "$HISTORY_FILE" "$OUT/report.json" "$GIT_SHA" "$TARGET" "$WALL_S" "${RUN_LABEL:-}" "$EVOLVE_RC" <<'PYEOF'
import json, sys, datetime
from pathlib import Path

hist_file, report_f, git_sha, target, wall_s, label, rc = sys.argv[1:8]
wall_s = float(wall_s); rc = int(rc)

# The engine's --report json may print as {"packages":[...]} (--all summary) or a
# single {...} report (one package). Tolerate both; the report may be preceded by
# log noise on stderr (we captured stdout only) — find the JSON object.
raw = Path(report_f).read_text()
try:
    doc = json.loads(raw)
except json.JSONDecodeError:
    # Salvage the outermost JSON object if any banner leaked onto stdout.
    s = raw.find("{")
    doc = json.loads(raw[s:]) if s != -1 else {}

pkgs = doc.get("packages") if isinstance(doc, dict) and "packages" in doc else (
    [doc] if isinstance(doc, dict) and doc.get("pkg_name") else []
)

per_pkg = []
for p in pkgs:
    per_pkg.append({
        "pkg": p.get("pkg_name", "?"),
        "ms": round(float(p.get("duration_ms", 0.0)), 1),
        "score": p.get("score"),
        "grade": p.get("grade"),
        "errors": int(p.get("error_count", 0)),
    })
per_pkg.sort(key=lambda r: r["ms"], reverse=True)

total_ms_sum = round(sum(r["ms"] for r in per_pkg), 1)
total_errors = sum(r["errors"] for r in per_pkg)
scores = [r["score"] for r in per_pkg if isinstance(r["score"], (int, float))]
grand_score = round(sum(scores) / len(scores), 1) if scores else None

# now() is permitted in scripts (not in workflows); use UTC for stable ordering.
ts = datetime.datetime.now(datetime.timezone.utc).isoformat()

row = {
    "ts": ts,
    "git_sha": git_sha,
    "target": target,
    "label": label or None,
    "evolve_exit": rc,
    "wall_clock_s": wall_s,
    "total_ms_sum": total_ms_sum,
    "pkg_count": len(per_pkg),
    "grand_score": grand_score,
    "total_errors": total_errors,
    "per_pkg": per_pkg,
}

# Append-only history.
hp = Path(hist_file)
history = []
if hp.is_file():
    try:
        history = json.loads(hp.read_text())
        if not isinstance(history, list):
            history = []
    except json.JSONDecodeError:
        history = []

# Previous row for the SAME target → delta line.
prev = next((h for h in reversed(history) if h.get("target") == target), None)

history.append(row)
hp.write_text(json.dumps(history, indent=2))

# ---- scoreboard ----
print("  SCOREBOARD (per-package duration_ms, slowest first)")
if per_pkg:
    for r in per_pkg[:12]:
        flag = " ⚠" if r["errors"] else ""
        print(f"    {r['ms']:>9.1f} ms  {r['pkg']:<14} score={r['score']} grade={r['grade']} errors={r['errors']}{flag}")
    if len(per_pkg) > 12:
        print(f"    … {len(per_pkg) - 12} more packages")
else:
    print("    (no per-package report parsed — check evolve stderr)")
print()
print(f"  TOTALS: wall={wall_s}s  sum(pkg_ms)={total_ms_sum}ms  pkgs={len(per_pkg)}  "
      f"grand_score={grand_score}  total_errors={total_errors}  exit={rc}")

if prev:
    d_wall = round(wall_s - prev.get("wall_clock_s", 0), 1)
    d_sum = round(total_ms_sum - prev.get("total_ms_sum", 0), 1)
    d_err = total_errors - prev.get("total_errors", 0)
    arrow = lambda d: ("▲ +" if d > 0 else ("▼ " if d < 0 else "= "))
    print()
    print(f"  DELTA vs previous '{target}' row ({prev.get('git_sha')}, {prev.get('ts','')[:19]}):")
    print(f"    wall:        {arrow(d_wall)}{d_wall}s   ({prev.get('wall_clock_s')}s → {wall_s}s)")
    print(f"    sum(pkg_ms): {arrow(d_sum)}{d_sum}ms")
    print(f"    errors:      {arrow(d_err)}{d_err}   ({prev.get('total_errors')} → {total_errors})")
else:
    print()
    print(f"  (first '{target}' row — no previous to delta against)")

print()
print(f"  History: {hist_file}  ({len(history)} rows)")
PYEOF
