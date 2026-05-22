#!/usr/bin/env python3
"""Generate HTML report of wrap results across multiple packages.

Shows: routes, frontend detection, entity mappings, nav items, page types.
Designed for human review and feedback.

Usage:
    python3 util/generate-wrap-report.py wrap/v10*
    # Opens report in browser
"""

import json
import sys
from pathlib import Path
from datetime import datetime


def load_wrap_result(wrap_dir: Path) -> dict | None:
    """Load wrap results from a directory."""
    ctx_file = wrap_dir / "vardhan-context.json"
    if not ctx_file.exists():
        # Try subdirectory (wrap/v10/lochan-opencats/)
        for sub in wrap_dir.iterdir():
            if sub.is_dir() and (sub / "vardhan-context.json").exists():
                ctx_file = sub / "vardhan-context.json"
                break
        if not ctx_file.exists():
            return None

    try:
        ctx = json.loads(ctx_file.read_text())
    except (json.JSONDecodeError, OSError):
        return None

    # Extract key data
    crawler = ctx.get("crawler", {})
    summary = crawler.get("summary", crawler)
    frontend_map = ctx.get("frontend_map", {})
    shell = frontend_map.get("shell", {}) if frontend_map else {}

    routes = crawler.get("routes", [])
    if isinstance(routes, int):
        routes = []

    return {
        "name": wrap_dir.name.replace("v10-", "").replace("lochan-", ""),
        "dir": str(wrap_dir),
        "stack": summary.get("stack", "?"),
        "entities": summary.get("entities", 0),
        "routes_total": summary.get("routes_total", 0),
        "crud_routes": summary.get("crud_routes", 0),
        "ip_routes": summary.get("ip_routes", 0),
        "routes": routes[:500],
        "frontend_map": frontend_map,
        "nav_type": shell.get("nav_type", "?"),
        "css_framework": shell.get("css_framework"),
        "js_libraries": shell.get("js_libraries", []),
        "nav_items": shell.get("nav_items", []),
        "pages": frontend_map.get("pages", []) if frontend_map else [],
        "module_entity_map": frontend_map.get("module_entity_map", {}) if frontend_map else {},
        "confidence": frontend_map.get("confidence", 0) if frontend_map else 0,
        "auth": ctx.get("auth_flows", {}),
    }


def generate_html(results: list[dict]) -> str:
    """Generate HTML report."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M")

    # Summary table
    summary_rows = ""
    for r in results:
        conf_color = "#4caf50" if r["confidence"] >= 0.8 else "#ff9800" if r["confidence"] >= 0.5 else "#f44336"
        summary_rows += f"""
        <tr>
            <td><strong>{r['name']}</strong></td>
            <td>{r['stack']}</td>
            <td>{r['entities']}</td>
            <td>{r['routes_total']}</td>
            <td>{r['crud_routes']}</td>
            <td>{r['ip_routes']}</td>
            <td>{r['nav_type']}</td>
            <td>{r['css_framework'] or 'custom'}</td>
            <td>{len(r['pages'])}</td>
            <td>{len(r['module_entity_map'])}</td>
            <td style="color:{conf_color};font-weight:bold">{r['confidence']:.2f}</td>
        </tr>"""

    # Per-package detail sections
    detail_sections = ""
    for r in results:
        # Routes table
        route_rows = ""
        routes_by_class = {}
        for route in r["routes"]:
            cls = route.get("classification", "unknown")
            routes_by_class.setdefault(cls, []).append(route)

        for cls in sorted(routes_by_class.keys()):
            for route in routes_by_class[cls][:50]:
                is_ip = route.get("is_ip", False)
                cls_color = "#4caf50" if cls == "crud" else "#2196f3" if is_ip else "#9e9e9e"
                method = route.get("method", "GET")
                method_color = "#1976d2" if method in ("POST", "PUT") else "#388e3c" if method == "GET" else "#f57c00"
                route_rows += f"""
                <tr>
                    <td><span style="color:{method_color};font-weight:bold;font-family:monospace">{method:6s}</span></td>
                    <td style="font-family:monospace">{route.get('path', '?')}</td>
                    <td><span style="color:{cls_color}">{cls}</span></td>
                    <td>{'💎' if is_ip else ''}</td>
                    <td style="font-size:0.8em;color:#666">{route.get('handler', '')[:60]}</td>
                    <td style="font-size:0.8em;color:#999">{route.get('source_file', '')[-40:]}</td>
                </tr>"""

        # Entity mapping table
        entity_rows = ""
        for mod, entity in r["module_entity_map"].items():
            entity_rows += f"<tr><td>{mod}</td><td>→</td><td><strong>{entity}</strong></td></tr>"

        # Pages table
        page_rows = ""
        for page in r["pages"]:
            comp_types = list(set(c.get("type", "?") for c in page.get("components", [])))
            page_rows += f"""
            <tr>
                <td>{page.get('url', '?')}</td>
                <td><strong>{page.get('page_type', '?')}</strong></td>
                <td>{page.get('lochan_component', '?')}</td>
                <td style="font-size:0.8em">{', '.join(comp_types[:5])}</td>
                <td>{len(page.get('components', []))}</td>
            </tr>"""

        # Nav items
        nav_rows = ""
        for nav in r.get("nav_items", []):
            nav_rows += f"<tr><td>{nav.get('label', '?')}</td><td>{nav.get('href', '?')}</td></tr>"

        detail_sections += f"""
        <div class="package-section" id="pkg-{r['name']}">
            <h2>📦 {r['name']} <span class="stack-badge">{r['stack']}</span></h2>

            <div class="stats-row">
                <div class="stat"><span class="num">{r['entities']}</span><br>Entities</div>
                <div class="stat"><span class="num">{r['routes_total']}</span><br>Routes</div>
                <div class="stat"><span class="num">{r['crud_routes']}</span><br>CRUD</div>
                <div class="stat"><span class="num">{r['ip_routes']}</span><br>IP</div>
                <div class="stat"><span class="num">{r['nav_type']}</span><br>Nav Type</div>
                <div class="stat"><span class="num">{r['css_framework'] or 'custom'}</span><br>CSS Framework</div>
                <div class="stat"><span class="num">{r['confidence']:.0%}</span><br>Confidence</div>
            </div>

            <h3>🗺️ Module → Entity Mapping ({len(r['module_entity_map'])})</h3>
            <table class="compact">{entity_rows or '<tr><td colspan="3">No mappings detected</td></tr>'}</table>

            <h3>📄 Detected Pages ({len(r['pages'])})</h3>
            <table>
                <thead><tr><th>URL</th><th>Type</th><th>Lochan Component</th><th>Components Found</th><th>#</th></tr></thead>
                <tbody>{page_rows or '<tr><td colspan="5">No pages detected</td></tr>'}</tbody>
            </table>

            <h3>🔗 Routes ({r['routes_total']})</h3>
            <details>
                <summary>Click to expand all {r['routes_total']} routes</summary>
                <table>
                    <thead><tr><th>Method</th><th>Path</th><th>Classification</th><th>IP?</th><th>Handler</th><th>Source</th></tr></thead>
                    <tbody>{route_rows}</tbody>
                </table>
            </details>

            {"<h3>🧭 Nav Items (" + str(len(r.get('nav_items',[]))) + ")</h3><table>" + nav_rows + "</table>" if nav_rows else ""}
        </div>
        """

    return f"""<!DOCTYPE html>
<html>
<head>
    <title>Vardhan Wrap Report — {len(results)} packages</title>
    <style>
        * {{ margin: 0; padding: 0; box-sizing: border-box; }}
        body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; padding: 20px; background: #f5f5f5; }}
        h1 {{ margin-bottom: 10px; }}
        h2 {{ margin: 30px 0 15px; padding: 10px; background: #1976d2; color: white; border-radius: 6px; }}
        h3 {{ margin: 20px 0 8px; color: #333; border-bottom: 2px solid #e0e0e0; padding-bottom: 5px; }}
        table {{ width: 100%; border-collapse: collapse; margin-bottom: 15px; background: white; }}
        th {{ background: #e3f2fd; padding: 8px 12px; text-align: left; font-size: 0.85em; border: 1px solid #ddd; }}
        td {{ padding: 6px 12px; border: 1px solid #eee; font-size: 0.85em; }}
        tr:hover {{ background: #f5f5f5; }}
        .compact {{ width: auto; }}
        .compact td {{ padding: 4px 12px; }}
        .stats-row {{ display: flex; gap: 15px; margin: 15px 0; flex-wrap: wrap; }}
        .stat {{ background: white; padding: 12px 20px; border-radius: 8px; text-align: center; min-width: 100px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }}
        .stat .num {{ font-size: 1.4em; font-weight: bold; color: #1976d2; }}
        .stack-badge {{ font-size: 0.6em; background: #e8f5e9; color: #2e7d32; padding: 3px 10px; border-radius: 12px; margin-left: 10px; }}
        .package-section {{ margin-bottom: 40px; }}
        details {{ margin: 10px 0; }}
        summary {{ cursor: pointer; padding: 8px; background: #fafafa; border: 1px solid #ddd; border-radius: 4px; }}
        .toc {{ background: white; padding: 15px; border-radius: 8px; margin-bottom: 20px; }}
        .toc a {{ margin-right: 15px; text-decoration: none; color: #1976d2; }}
        .toc a:hover {{ text-decoration: underline; }}
        .timestamp {{ color: #999; font-size: 0.85em; }}
    </style>
</head>
<body>
    <h1>Vardhan Wrap Report</h1>
    <p class="timestamp">Generated: {timestamp} | Packages: {len(results)}</p>

    <div class="toc">
        <strong>Jump to:</strong>
        {''.join(f'<a href="#pkg-{r["name"]}">{r["name"]}</a>' for r in results)}
    </div>

    <h2 style="background:#333">Summary</h2>
    <table>
        <thead>
            <tr><th>Package</th><th>Stack</th><th>Entities</th><th>Routes</th><th>CRUD</th><th>IP</th><th>Nav Type</th><th>CSS</th><th>Pages</th><th>Map</th><th>Conf</th></tr>
        </thead>
        <tbody>{summary_rows}</tbody>
    </table>

    {detail_sections}
</body>
</html>"""


def main():
    import glob
    import webbrowser

    dirs = []
    for pattern in sys.argv[1:] if len(sys.argv) > 1 else ["wrap/v10", "wrap/v10-*"]:
        dirs.extend(glob.glob(pattern))

    if not dirs:
        print("Usage: python3 util/generate-wrap-report.py wrap/v10*")
        sys.exit(1)

    results = []
    for d in sorted(dirs):
        p = Path(d)
        if p.is_dir():
            result = load_wrap_result(p)
            if result:
                results.append(result)
                print(f"  Loaded: {result['name']} ({result['stack']}, {result['routes_total']} routes)")
            else:
                print(f"  Skip: {d} (no vardhan-context.json)")

    if not results:
        print("No wrap results found.")
        sys.exit(1)

    output = Path("wrap/wrap-report.html")
    output.write_text(generate_html(results))
    print(f"\nReport: {output} ({len(results)} packages)")

    # Try to open in browser
    try:
        webbrowser.open(f"file://{output.resolve()}")
    except Exception:
        pass


if __name__ == "__main__":
    main()
