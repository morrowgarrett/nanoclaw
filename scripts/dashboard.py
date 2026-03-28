#!/usr/bin/env python3
"""
Relay Dashboard — lightweight project viewer for LAN access.
Serves active project markdown as mobile-friendly HTML on :8200.
No external dependencies — pure stdlib.
"""

import os
import re
import json
import glob
import socket
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import unquote
from pathlib import Path
from datetime import datetime

ACTIVE_DIR = Path.home() / "consulting" / "projects" / "active"
RELAY_PID = Path.home() / "nanoclaw" / "data" / "relay.pid"
PORT = 8200

# ── Markdown to HTML (simple, no dependencies) ──────────────────

def md_to_html(text):
    """Convert markdown to HTML using regex. Handles the basics."""
    if not text:
        return ""
    lines = text.split("\n")
    html_lines = []
    in_code_block = False
    in_list = False
    in_table = False
    table_has_header = False

    for line in lines:
        # Fenced code blocks
        if line.strip().startswith("```"):
            if in_code_block:
                html_lines.append("</code></pre>")
                in_code_block = False
            else:
                lang = line.strip()[3:].strip()
                html_lines.append(f'<pre><code class="lang-{lang}">' if lang else "<pre><code>")
                in_code_block = True
            continue
        if in_code_block:
            html_lines.append(_esc(line))
            continue

        # Table rows
        if "|" in line and line.strip().startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            # Separator row (---|---)
            if all(re.match(r'^[-:]+$', c) for c in cells):
                table_has_header = True
                continue
            if not in_table:
                html_lines.append('<div class="table-wrap"><table>')
                in_table = True
            tag = "th" if not table_has_header and in_table else "td"
            row = "".join(f"<{tag}>{_inline(c)}</{tag}>" for c in cells)
            html_lines.append(f"<tr>{row}</tr>")
            continue
        elif in_table:
            html_lines.append("</table></div>")
            in_table = False
            table_has_header = False

        stripped = line.strip()

        # Close list if not a list item
        if in_list and not re.match(r'^[-*+]\s|^\d+\.\s', stripped):
            html_lines.append("</ul>")
            in_list = False

        # Blank line
        if not stripped:
            html_lines.append("")
            continue

        # Headings
        m = re.match(r'^(#{1,6})\s+(.*)', line)
        if m:
            level = len(m.group(1))
            html_lines.append(f"<h{level}>{_inline(m.group(2))}</h{level}>")
            continue

        # Horizontal rule
        if re.match(r'^[-*_]{3,}\s*$', stripped):
            html_lines.append("<hr>")
            continue

        # Unordered list
        m = re.match(r'^[-*+]\s+(.*)', stripped)
        if m:
            if not in_list:
                html_lines.append("<ul>")
                in_list = True
            html_lines.append(f"<li>{_inline(m.group(1))}</li>")
            continue

        # Ordered list
        m = re.match(r'^\d+\.\s+(.*)', stripped)
        if m:
            if not in_list:
                html_lines.append("<ul>")
                in_list = True
            html_lines.append(f"<li>{_inline(m.group(1))}</li>")
            continue

        # Paragraph
        html_lines.append(f"<p>{_inline(stripped)}</p>")

    if in_list:
        html_lines.append("</ul>")
    if in_table:
        html_lines.append("</table></div>")
    if in_code_block:
        html_lines.append("</code></pre>")

    return "\n".join(html_lines)


def _esc(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _inline(text):
    """Handle inline markdown: bold, italic, code, links."""
    text = _esc(text)
    # Code spans first (so bold/italic don't match inside them)
    text = re.sub(r'`([^`]+)`', r'<code>\1</code>', text)
    # Bold + italic
    text = re.sub(r'\*\*\*(.+?)\*\*\*', r'<strong><em>\1</em></strong>', text)
    # Bold
    text = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', text)
    # Italic
    text = re.sub(r'\*(.+?)\*', r'<em>\1</em>', text)
    # Links
    text = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2">\1</a>', text)
    return text


# ── Relay Status ─────────────────────────────────────────────────

def relay_status():
    """Return dict with relay running state, PID, etc."""
    info = {"running": False, "pid": None}
    if RELAY_PID.exists():
        try:
            pid = int(RELAY_PID.read_text().strip())
            # Check if process is alive
            os.kill(pid, 0)
            info["running"] = True
            info["pid"] = pid
        except (ValueError, ProcessLookupError, PermissionError):
            pass
    return info


def project_relay_info(project_dir):
    """Parse RELAY.md and round files for status."""
    info = {"round": 0, "max_rounds": "?", "verdict": None, "started": None}
    relay_path = project_dir / "RELAY.md"
    if relay_path.exists():
        text = relay_path.read_text()
        m = re.search(r'\*\*Max rounds:\*\*\s*(\d+)', text)
        if m:
            info["max_rounds"] = m.group(1)
        m = re.search(r'\*\*Started:\*\*\s*(.+)', text)
        if m:
            info["started"] = m.group(1).strip()
        # Find highest round
        rounds = re.findall(r'=== Round (\d+)/', text)
        if rounds:
            info["round"] = max(int(r) for r in rounds)
        # Last verdict
        verdicts = re.findall(r'\*\*(APPROVED|REVISE|REJECTED)\*\*', text)
        if verdicts:
            info["verdict"] = verdicts[-1]
    return info


# ── Project Discovery ────────────────────────────────────────────

def list_projects():
    """Return list of (name, path) for active projects."""
    if not ACTIVE_DIR.exists():
        return []
    projects = []
    for p in sorted(ACTIVE_DIR.iterdir()):
        if p.is_dir() and (p / "BRIEF.md").exists():
            projects.append((p.name, p))
    return projects


def get_project_content(project_dir):
    """Build ordered sections for a project page."""
    sections = []
    p = project_dir

    # BRIEF.md first
    brief = p / "BRIEF.md"
    if brief.exists():
        sections.append(("Brief", brief.read_text()))

    # Rounds in order
    round_num = 1
    while True:
        gear_file = p / f".gear-round-{round_num}.txt"
        clutch_file = p / f".clutch-round-{round_num}.txt"
        has_gear = gear_file.exists()
        has_clutch = clutch_file.exists()
        if not has_gear and not has_clutch:
            break

        if has_gear:
            gear_text = gear_file.read_text()
            # Strip the nanoclaw wrapper if present
            m = re.search(r'---NANOCLAW_OUTPUT_START---\n(.*?)\n---NANOCLAW_OUTPUT_END---', gear_text, re.DOTALL)
            if m:
                try:
                    data = json.loads(m.group(1))
                    gear_text = data.get("result", gear_text)
                except json.JSONDecodeError:
                    gear_text = m.group(1)
            sections.append((f"Gear — Round {round_num}", gear_text))

        if has_clutch:
            clutch_text = clutch_file.read_text()
            m = re.search(r'---NANOCLAW_OUTPUT_START---\n(.*?)\n---NANOCLAW_OUTPUT_END---', clutch_text, re.DOTALL)
            if m:
                try:
                    data = json.loads(m.group(1))
                    clutch_text = data.get("result", clutch_text)
                except json.JSONDecodeError:
                    clutch_text = m.group(1)
            sections.append((f"Clutch Review — Round {round_num}", clutch_text))

        round_num += 1

    # RELAY.md last
    relay = p / "RELAY.md"
    if relay.exists():
        sections.append(("Relay Log", relay.read_text()))

    # Any other .md files not already shown
    shown = {"BRIEF.md", "RELAY.md"}
    for md_file in sorted(p.glob("*.md")):
        if md_file.name not in shown:
            sections.append((md_file.stem, md_file.read_text()))

    return sections


# ── CSS ──────────────────────────────────────────────────────────

CSS = """
:root {
    --bg: #1a1a2e;
    --surface: #16213e;
    --card: #0f3460;
    --text: #e0e0e0;
    --text-dim: #8a8a9a;
    --accent: #e94560;
    --accent2: #53d8a8;
    --link: #64b5f6;
    --border: #2a2a4a;
    --code-bg: #0d1117;
}

* { box-sizing: border-box; margin: 0; padding: 0; }

html {
    font-size: 18px;
    -webkit-text-size-adjust: 100%;
}

body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: var(--bg);
    color: var(--text);
    line-height: 1.65;
    padding: 1rem;
    max-width: 900px;
    margin: 0 auto;
}

a { color: var(--link); text-decoration: none; }
a:hover { text-decoration: underline; }

h1 { font-size: 1.6rem; margin: 0.8rem 0 0.5rem; color: #fff; }
h2 { font-size: 1.35rem; margin: 1.2rem 0 0.4rem; color: var(--accent2); }
h3 { font-size: 1.15rem; margin: 1rem 0 0.3rem; color: var(--link); }
h4, h5, h6 { font-size: 1rem; margin: 0.8rem 0 0.3rem; }

p { margin: 0.5rem 0; }

hr {
    border: none;
    border-top: 1px solid var(--border);
    margin: 1.2rem 0;
}

ul, ol {
    padding-left: 1.4rem;
    margin: 0.4rem 0;
}
li { margin: 0.25rem 0; }

code {
    background: var(--code-bg);
    padding: 0.15em 0.4em;
    border-radius: 4px;
    font-size: 0.9rem;
    font-family: "SF Mono", "Fira Code", Consolas, monospace;
}

pre {
    background: var(--code-bg);
    padding: 1rem;
    border-radius: 8px;
    overflow-x: auto;
    margin: 0.6rem 0;
    border: 1px solid var(--border);
}
pre code {
    background: none;
    padding: 0;
    font-size: 0.85rem;
    line-height: 1.5;
}

.table-wrap {
    overflow-x: auto;
    margin: 0.6rem 0;
}
table {
    border-collapse: collapse;
    width: 100%;
    font-size: 0.9rem;
}
th, td {
    border: 1px solid var(--border);
    padding: 0.5rem 0.7rem;
    text-align: left;
}
th { background: var(--card); font-weight: 600; }
td { background: var(--surface); }

strong { color: #fff; }

/* ── Layout components ─────────────────────────── */

.header {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 1rem 1.2rem;
    margin-bottom: 1rem;
}
.header h1 { margin: 0 0 0.3rem; }

.status-bar {
    display: flex;
    flex-wrap: wrap;
    gap: 0.6rem;
    align-items: center;
    font-size: 0.9rem;
    color: var(--text-dim);
}

.badge {
    display: inline-block;
    padding: 0.15rem 0.6rem;
    border-radius: 20px;
    font-size: 0.8rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.03em;
}
.badge-running { background: #1b5e20; color: #81c784; }
.badge-stopped { background: #4a1a1a; color: #ef9a9a; }
.badge-approved { background: #1b5e20; color: #a5d6a7; }
.badge-revise { background: #e65100; color: #ffcc80; }
.badge-rejected { background: #b71c1c; color: #ef9a9a; }

.project-card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 1rem 1.2rem;
    margin-bottom: 0.8rem;
    transition: border-color 0.2s;
}
.project-card:hover { border-color: var(--accent2); }
.project-card h2 { margin: 0 0 0.4rem; font-size: 1.1rem; }
.project-card .meta { font-size: 0.85rem; color: var(--text-dim); }

.section {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 1rem 1.2rem;
    margin-bottom: 1rem;
}
.section-title {
    font-size: 1.15rem;
    font-weight: 700;
    color: var(--accent2);
    margin-bottom: 0.6rem;
    padding-bottom: 0.4rem;
    border-bottom: 1px solid var(--border);
}
.section-gear .section-title { color: var(--link); }
.section-clutch .section-title { color: var(--accent); }
.section-relay .section-title { color: var(--text-dim); }

.back-link {
    display: inline-block;
    margin-bottom: 0.8rem;
    font-size: 0.95rem;
}

.footer {
    text-align: center;
    font-size: 0.75rem;
    color: var(--text-dim);
    margin-top: 2rem;
    padding: 1rem 0;
}

@media (max-width: 480px) {
    html { font-size: 17px; }
    body { padding: 0.6rem; }
    .header, .section, .project-card { padding: 0.8rem; }
}
"""

# ── HTML Templates ───────────────────────────────────────────────

def page_wrapper(title, body_html, refresh=True):
    refresh_tag = '<meta http-equiv="refresh" content="30">' if refresh else ""
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
{refresh_tag}
<title>{_esc(title)}</title>
<style>{CSS}</style>
</head>
<body>
{body_html}
<div class="footer">Relay Dashboard &mdash; auto-refresh 30s</div>
</body>
</html>"""


def index_page():
    status = relay_status()
    badge = '<span class="badge badge-running">Running</span>' if status["running"] else '<span class="badge badge-stopped">Stopped</span>'
    pid_info = f' &middot; PID {status["pid"]}' if status["pid"] else ""

    projects = list_projects()
    cards = []
    for name, path in projects:
        info = project_relay_info(path)
        meta_parts = []
        if info["round"]:
            meta_parts.append(f'Round {info["round"]}/{info["max_rounds"]}')
        if info["verdict"]:
            vc = info["verdict"].lower()
            meta_parts.append(f'<span class="badge badge-{vc}">{info["verdict"]}</span>')
        if info["started"]:
            meta_parts.append(info["started"])
        meta = " &middot; ".join(meta_parts) if meta_parts else "No relay data"

        # Friendly name: strip date prefix
        friendly = re.sub(r'^\d{4}-\d{2}-\d{2}-\d{4}-', '', name).replace("-", " ").title()

        cards.append(f"""
        <a href="/project/{name}" style="text-decoration:none;color:inherit">
        <div class="project-card">
            <h2>{_esc(friendly)}</h2>
            <div class="meta">{meta}</div>
        </div>
        </a>""")

    if not cards:
        cards.append('<div class="project-card"><p>No active projects found.</p></div>')

    body = f"""
    <div class="header">
        <h1>Relay Dashboard</h1>
        <div class="status-bar">
            {badge}{pid_info}
            &middot; {len(projects)} active project{"s" if len(projects) != 1 else ""}
            &middot; {datetime.now().strftime("%H:%M:%S")}
        </div>
    </div>
    {"".join(cards)}
    """
    return page_wrapper("Relay Dashboard", body)


def project_page(project_name):
    project_dir = ACTIVE_DIR / project_name
    if not project_dir.is_dir():
        return page_wrapper("Not Found", '<div class="section"><p>Project not found.</p></div>')

    friendly = re.sub(r'^\d{4}-\d{2}-\d{2}-\d{4}-', '', project_name).replace("-", " ").title()
    info = project_relay_info(project_dir)
    sections = get_project_content(project_dir)

    verdict_badge = ""
    if info["verdict"]:
        vc = info["verdict"].lower()
        verdict_badge = f' <span class="badge badge-{vc}">{info["verdict"]}</span>'

    round_info = ""
    if info["round"]:
        round_info = f" &middot; Round {info['round']}/{info['max_rounds']}"

    html_sections = []
    for title, content in sections:
        css_class = "section"
        if "gear" in title.lower():
            css_class += " section-gear"
        elif "clutch" in title.lower():
            css_class += " section-clutch"
        elif "relay" in title.lower():
            css_class += " section-relay"

        html_sections.append(f"""
        <div class="{css_class}">
            <div class="section-title">{_esc(title)}</div>
            {md_to_html(content)}
        </div>""")

    body = f"""
    <a href="/" class="back-link">&larr; All Projects</a>
    <div class="header">
        <h1>{_esc(friendly)}</h1>
        <div class="status-bar">
            {verdict_badge}{round_info}
        </div>
    </div>
    {"".join(html_sections)}
    """
    return page_wrapper(friendly, body)


# ── HTTP Server ──────────────────────────────────────────────────

class DashboardHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = unquote(self.path)

        if path == "/" or path == "":
            html = index_page()
            self._respond(200, html)
        elif path.startswith("/project/"):
            name = path[len("/project/"):].strip("/")
            html = project_page(name)
            self._respond(200, html)
        else:
            self._respond(404, page_wrapper("404", '<div class="section"><p>Not found.</p></div>'))

    def _respond(self, code, html):
        body = html.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        # Quiet logging — just timestamp + path
        pass


def main():
    server = HTTPServer(("0.0.0.0", PORT), DashboardHandler)
    hostname = socket.gethostname()
    print(f"Relay Dashboard running on http://0.0.0.0:{PORT}/")
    print(f"  LAN: http://192.168.1.236:{PORT}/")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.shutdown()


if __name__ == "__main__":
    main()
