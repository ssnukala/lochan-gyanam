#!/usr/bin/env bash
#
# record-asciinema-demo.sh — founder convenience for recording + trimming
# asciinema sessions that go into the lochan.ai hero block.
#
# Requires: asciinema (install: brew install asciinema), and optionally
# agg (https://github.com/asciinema/agg) for rendering to GIF.
#
# Usage:
#   util/scripts/record-asciinema-demo.sh <slug>
#     slug  - short dash-separated name (e.g. create-lifelight, wrap-covera)
#
# Produces:
#   util/asciinema/<slug>-YYYYMMDD-HHMMSS.cast     (raw recording)
#   util/asciinema/<slug>-YYYYMMDD-HHMMSS.json     (metadata)
#
# Upload flow:
#   1. Review:     asciinema play util/asciinema/<slug>-...cast
#   2. Upload:     asciinema upload util/asciinema/<slug>-...cast
#                  (copy the asciinema.org URL it returns)
#   3. Embed in framework/lochan/frontend/src/pages/Home.tsx by replacing
#      the "asciinema-demo" div contents with:
#        <script
#          src="https://asciinema.org/a/<id>.js"
#          id="asciicast-<id>"
#          async
#          data-speed="1.5"
#          data-theme="solarized-dark"
#        ></script>

set -euo pipefail

SLUG="${1:-demo}"
STAMP=$(date +%Y%m%d-%H%M%S)
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
OUT_DIR="$REPO_ROOT/util/asciinema"
OUT="$OUT_DIR/${SLUG}-${STAMP}.cast"

mkdir -p "$OUT_DIR"

if ! command -v asciinema >/dev/null 2>&1; then
  echo "error: asciinema not installed. brew install asciinema" >&2
  exit 1
fi

cat <<EOF

── Recording $OUT ──────────────────────────────────────────────────────

  Tips for a good hero-block demo:
    • Keep it under 45 seconds (hero visitors won't sit through more).
    • Clear screen first:       clear
    • Big font, dark terminal:  iTerm > Preferences > Profiles > Text
    • Type slower than usual    — the recording captures real timing.
    • Exit the shell to stop    — Ctrl-D or 'exit'.

  Asciinema starts NOW. Your next commands are being recorded.

─────────────────────────────────────────────────────────────────────────

EOF

exec asciinema rec \
  --title "Lochan demo — ${SLUG}" \
  --idle-time-limit 2 \
  --cols 110 \
  --rows 28 \
  "$OUT"
