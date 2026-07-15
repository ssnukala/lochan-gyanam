"""probe-wrap-answer-keys.py — in-container scorer for the wrap answer-key harness.

Runs ONE tier-2 semantic answer key against the target app's LIVE intent corpus
(`IntentEmbeddingIndex.search`) and prints a single-line JSON verdict the calling
`probe-wrap-answer-keys.sh` aggregates. Runs INSIDE the app backend container
(needs the app DB + the local embedding endpoint) — the wrapper `docker cp`s this
file + the key JSON into /tmp and `docker exec`s it.

Answer-key contract (see the key JSONs' own `contract` field):
  - a normal row PASSES when its `expected_tool` (aka `expected`) is the TOP-1
    match at tier<=top_k;
  - a `defer` row PASSES when nothing resolves at/above the confidence threshold
    (llm-fallback/clarify IS the correct outcome for an out-of-scope utterance).

Usage (in-container):
  python /tmp/probe-wrap-answer-keys.py <key.json> [threshold] [top_k]
    threshold  confidence floor for a real match / the defer ceiling (default 0.55)
    top_k      candidates to pull (top-1 is scored; default 3)

Output: exactly one line `ANSWERKEY_JSON {...}` to stdout (the wrapper greps it).
Fail-loud: an unreadable key, a missing corpus index, or a DB/embed failure raises
(no silent except) so a broken run is a hard error, never a silent 0%.
"""
import asyncio
import json
import logging
import sys

# Silence SQLAlchemy engine echo so the single ANSWERKEY_JSON line is grep-clean.
for _n in ("sqlalchemy.engine", "sqlalchemy.engine.Engine", "sqlalchemy"):
    logging.getLogger(_n).setLevel(logging.CRITICAL)
    logging.getLogger(_n).disabled = True

from muulam.data import async_session
from gyanam.services.intent.intent_embedding_index import IntentEmbeddingIndex


def _expected_tool(entry: dict) -> str:
    """The key uses `expected_tool`; tolerate the older `expected` alias."""
    exp = entry.get("expected_tool") or entry.get("expected")
    if exp is None:
        raise ValueError(f"answer-key entry missing expected_tool/expected: {entry!r}")
    return exp


def _match_tool(match) -> str | None:
    """The tool name a search match resolves to (via its example's intent_json)."""
    if match is None:
        return None
    example = getattr(match, "example", None)
    intent_json = (getattr(example, "intent_json", None) or {}) if example else {}
    return intent_json.get("tool")


def _match_score(match) -> float | None:
    return getattr(match, "similarity", None)


async def _score_key(key: dict, threshold: float, top_k: int) -> dict:
    package = key["package"]
    entries = key["entries"]
    index = IntentEmbeddingIndex()
    ok = 0
    misses = []
    async with async_session() as db:
        for entry in entries:
            expected = _expected_tool(entry)
            matches = await index.search(
                db, entry["utterance"], top_k=top_k, threshold=0.0, packages=[package]
            )
            top = matches[0] if matches else None
            top_tool = _match_tool(top)
            top_score = _match_score(top)
            if expected == "defer":
                passed = top is None or (top_score is not None and top_score < threshold)
            else:
                passed = top_tool == expected
            if passed:
                ok += 1
            else:
                misses.append({
                    "utterance": entry["utterance"],
                    "expected": expected,
                    "got_tool": top_tool,
                    "got_score": round(top_score, 3) if top_score is not None else None,
                })
    total = len(entries)
    return {
        "package": package,
        "pass": ok,
        "total": total,
        "accuracy_pct": round(100 * ok / total, 1) if total else 0.0,
        "threshold": threshold,
        "top_k": top_k,
        "misses": misses,
    }


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("usage: probe-wrap-answer-keys.py <key.json> [threshold] [top_k]")
    key_path = sys.argv[1]
    threshold = float(sys.argv[2]) if len(sys.argv) > 2 else 0.55
    top_k = int(sys.argv[3]) if len(sys.argv) > 3 else 3
    with open(key_path) as fh:
        key = json.load(fh)
    result = asyncio.run(_score_key(key, threshold, top_k))
    print("ANSWERKEY_JSON " + json.dumps(result))


if __name__ == "__main__":
    main()
