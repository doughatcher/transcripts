#!/usr/bin/env python3
"""Render the marketing page and the user guide into site/public/.

Deliberately not Hugo, which is the convention on hatcher.ltd. This is seven
pages with no taxonomy, no feed and no pagination, and Hugo would need to be
installed and given a theme to produce them. The Markdown in docs/guide/ is the
portable layer — swap this renderer for Hugo later and the content is unchanged.

The guide is written beside the code it documents, on purpose. Docs in a
separate wiki rot because nothing forces them past a code change; docs in the
repo show up in the same diff.

    python3 site/build.py            # → site/public/
    python3 site/build.py --serve    # build, then serve on :8000
"""
import html
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GUIDE_SRC = ROOT / "docs" / "guide"
OUT = ROOT / "site" / "public"


def mac_version() -> str:
    """The shipping macOS version, read from the one place that sets it.

    project.yml is the source of truth — release.sh edits it and xcodegen builds
    from it — so the page cannot advertise a version the artifact isn't. A
    hardcoded string in the HTML is how a site ends up offering 0.1.0 of a build
    that says 1.0.0 on its About tab.
    """
    spec = (ROOT / "project.yml").read_text()
    block = spec.split("  TranscriptsMac:", 1)
    if len(block) == 2:
        m = re.search(r'MARKETING_VERSION: "([^"]+)"', block[1])
        if m:
            return m.group(1)
    return "0.0.0"

# Guide order is editorial, not alphabetical — it is the order you meet the app.
GUIDE_PAGES = [
    ("index", "Getting started"),
    ("install", "Installing"),
    ("recording", "Recording"),
    ("live", "The live transcript"),
    ("transcripts", "Your transcripts"),
    ("handoff", "iPhone, iPad and Mac"),
    ("settings", "Settings"),
    ("privacy", "Privacy"),
    ("changelog", "Changelog"),
]


# --- A very small Markdown subset -------------------------------------------
# Enough for the guide: headings, lists, code, links, emphasis, images, rules.
# Anything fancier is a signal the guide is drifting toward prose it shouldn't be.

def md(text: str) -> str:
    out, lines = [], text.split("\n")
    i, in_list, in_code = 0, False, False
    while i < len(lines):
        line = lines[i]

        if line.startswith("```"):
            if in_code:
                out.append("</code></pre>")
                in_code = False
            else:
                if in_list:
                    out.append("</ul>"); in_list = False
                out.append("<pre><code>")
                in_code = True
            i += 1
            continue
        if in_code:
            out.append(html.escape(line))
            i += 1
            continue

        if not line.strip():
            if in_list:
                out.append("</ul>"); in_list = False
            i += 1
            continue

        if line.startswith("---"):
            if in_list:
                out.append("</ul>"); in_list = False
            out.append("<hr>")
            i += 1
            continue

        m = re.match(r"^(#{1,4})\s+(.*)", line)
        if m:
            if in_list:
                out.append("</ul>"); in_list = False
            level = len(m.group(1))
            slug = re.sub(r"[^a-z0-9]+", "-", m.group(2).lower()).strip("-")
            out.append(f'<h{level} id="{slug}">{inline(m.group(2))}</h{level}>')
            i += 1
            continue

        m = re.match(r"^\s*[-*]\s+(.*)", line)
        if m:
            if not in_list:
                out.append("<ul>"); in_list = True
            # A list item continues onto indented following lines.
            item = [m.group(1)]
            i += 1
            while i < len(lines) and lines[i].startswith("  ") and lines[i].strip() \
                    and not re.match(r"^\s*[-*]\s+", lines[i]):
                item.append(lines[i].strip())
                i += 1
            out.append(f"<li>{inline(' '.join(item))}</li>")
            continue

        if in_list:
            out.append("</ul>"); in_list = False
        # Consecutive non-blank lines are ONE paragraph. The guide is hard
        # wrapped at 80 columns, so treating each line as its own <p> turned
        # every paragraph into a column of orphaned sentences.
        para = [line]
        i += 1
        while i < len(lines) and lines[i].strip() \
                and not lines[i].startswith(("#", "```", "---")) \
                and not re.match(r"^\s*[-*]\s+", lines[i]):
            para.append(lines[i].strip())
            i += 1
        out.append(f"<p>{inline(' '.join(para))}</p>")

    if in_list:
        out.append("</ul>")
    if in_code:
        out.append("</code></pre>")
    return "\n".join(out)


def inline(s: str) -> str:
    s = html.escape(s)
    s = re.sub(r"!\[([^\]]*)\]\(([^)]+)\)", r'<img src="\2" alt="\1" loading="lazy">', s)
    s = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', s)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"<em>\1</em>", s)
    return s


# --- Shell -------------------------------------------------------------------

# Analytics: Cloudflare Web Analytics, not Google.
#
# It answers the actual question — who is looking, where from, which pages —
# without cookies, which means no consent banner and no asterisk beside a
# product sold on not tracking anyone. GTM was here briefly and did the same job
# with a cookie obligation attached.
#
# The usual way to turn this on is the Pages dashboard (project ▸ Settings ▸ Web
# Analytics ▸ Enable), which injects the beacon at the edge and needs no code at
# all — leave BEACON_TOKEN empty for that. Set it only to pin the beacon in the
# markup instead, e.g. to serve the same build from somewhere other than Pages.
BEACON_TOKEN = ""

ANALYTICS = (
    f"""<script defer src="https://static.cloudflareinsights.com/beacon.min.js"
 data-cf-beacon='{{"token": "{BEACON_TOKEN}"}}'></script>"""
    if BEACON_TOKEN else ""
)


def page(title: str, body: str, *, nav: str = "", cls: str = "") -> str:
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<meta name="description" content="Live transcripts of every meeting, recorded, transcribed and summarized entirely on your own Mac, iPhone and iPad.">
<link rel="stylesheet" href="/style.css">
<link rel="icon" href="/icon.png">
{ANALYTICS}
</head>
<body class="{cls}">
<header class="top">
  <a class="wordmark" href="/"><img src="/icon.png" alt="" width="28" height="28">Transcripts</a>
  <nav><a href="/guide/">User guide</a><a href="/#download">Download</a></nav>
</header>
<main>{nav}{body}</main>
<footer>
  <p>Transcripts is made by <a href="https://hatcher.ltd">Doug Hatcher</a>.
     <a href="/guide/privacy/">Privacy</a> ·
     <a href="https://github.com/hatcher-ltd/transcripts-support/issues">Report an issue</a> ·
     <a href="mailto:support@hatcher.ltd">Support</a></p>
</footer>
</body>
</html>
"""


def build():
    if OUT.exists():
        shutil.rmtree(OUT)
    (OUT / "guide").mkdir(parents=True)

    # Assets
    shutil.copy(ROOT / "site" / "style.css", OUT / "style.css")
    icon = ROOT / "Sources/Transcripts/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
    if icon.exists():
        shutil.copy(icon, OUT / "icon.png")
    images = GUIDE_SRC / "images"
    if images.exists():
        shutil.copytree(images, OUT / "guide" / "images")

    # Landing page. Version placeholders are filled from project.yml so the
    # download link and the badge always name the build that release.sh made.
    version = mac_version()
    landing = (ROOT / "site" / "index.html").read_text()
    landing = landing.replace("{{VERSION}}", version)
    landing = landing.replace("{{ZIP}}", f"Transcripts-{version}.zip")
    (OUT / "index.html").write_text(page("Transcripts — live meeting transcripts, entirely on device",
                                         landing, cls="landing"))
    print(f"  · version {version}")

    # A real 404 page. Without one, Pages answers every missing path with
    # index.html and a 200 — which meant the updater fetching a channel that
    # does not exist got HTML, failed to decode it, and reported "the manifest
    # could not be read" instead of "no stable release yet".
    (OUT / "404.html").write_text(
        page("Not found — Transcripts", (ROOT / "site" / "404.html").read_text(), cls="landing"))

    # Guide
    links = "".join(
        f'<a href="/guide/{"" if slug == "index" else slug + "/"}">{html.escape(title)}</a>'
        for slug, title in GUIDE_PAGES)
    nav = f'<nav class="guide-nav">{links}</nav>'
    for slug, title in GUIDE_PAGES:
        src = GUIDE_SRC / f"{slug}.md"
        if not src.exists():
            print(f"  ! missing {src.relative_to(ROOT)}")
            continue
        body = md(src.read_text())
        dest = OUT / "guide" / ("index.html" if slug == "index" else f"{slug}/index.html")
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(page(f"{title} — Transcripts guide", body, nav=nav, cls="guide"))
        print(f"  ✓ /guide/{'' if slug == 'index' else slug + '/'}")

    print(f"✓ built → {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    build()
    if "--serve" in sys.argv:
        import http.server, os, socketserver
        os.chdir(OUT)
        print("→ http://localhost:8000")
        socketserver.TCPServer(("", 8000), http.server.SimpleHTTPRequestHandler).serve_forever()
