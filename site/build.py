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
import hashlib
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

# Order is editorial, not alphabetical — it is the order you meet the app — and
# grouped, because a flat list of eleven says nothing about what belongs with
# what. Sections are the structure a reader uses to decide what to skip.
GUIDE_SECTIONS = [
    ("Start here", [
        ("index", "Getting started"),
        ("install", "Installing"),
    ]),
    ("Recording", [
        ("recording", "Recording"),
        ("live", "The live transcript"),
        ("overlay", "The overlay"),
        ("transcripts", "Your transcripts"),
        ("handoff", "iPhone, iPad and Mac"),
    ]),
    ("Configuring", [
        ("settings", "Settings"),
        ("routing", "Sorting and sessions"),
        ("reference", "routing.json reference"),
    ]),
    ("About", [
        ("privacy", "Privacy"),
        ("changelog", "Changelog"),
    ]),
]

GUIDE_PAGES = [pair for _, pages in GUIDE_SECTIONS for pair in pages]


# --- A very small Markdown subset -------------------------------------------
# Enough for the guide: headings, lists, code, links, emphasis, images, rules.
# Anything fancier is a signal the guide is drifting toward prose it shouldn't be.
#
# Two things it deliberately lacks, because both have bitten: ordered lists
# ("1. …" renders as a paragraph — use "- " and let the prose carry the order)
# and fenced code inside a list item (the fence collapses the list). Put the
# fence after the list.

def md(text: str) -> str:
    out, lines = [], text.split("\n")
    i, in_list, in_code, code_lang = 0, False, False, ""
    while i < len(lines):
        line = lines[i]

        if line.startswith("```"):
            if in_code:
                out.append("</code></pre>")
                in_code = False
                code_lang = ""
            else:
                if in_list:
                    out.append("</ul>"); in_list = False
                code_lang = line[3:].strip().lower()
                cls = f' class="lang-{code_lang}"' if code_lang else ""
                out.append(f"<pre{cls}><code>")
                in_code = True
            i += 1
            continue
        if in_code:
            out.append(highlight(line, code_lang))
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

        # Pipe tables. Added after writing a reference page full of them and
        # finding every one rendered as literal pipes — a schema table is the
        # one thing that page is for.
        if line.lstrip().startswith("|") and i + 1 < len(lines) \
                and re.match(r"^\s*\|[\s:|-]+\|\s*$", lines[i + 1]):
            if in_list:
                out.append("</ul>"); in_list = False

            def cells(row: str) -> list[str]:
                # An escaped \| is a literal pipe in a cell — "command \| null"
                # is one type, not two. Splitting naively shifted every
                # subsequent cell right and silently dropped the last one.
                PIPE = "\x00"
                row = row.replace("\\|", PIPE)
                # Strip the outer pipes before splitting, so an empty leading or
                # trailing cell is not invented.
                return [c.strip().replace(PIPE, "|")
                        for c in row.strip().strip("|").split("|")]

            head = cells(line)
            out.append("<table><thead><tr>")
            out.extend(f"<th>{inline(c)}</th>" for c in head)
            out.append("</tr></thead><tbody>")
            i += 2
            while i < len(lines) and lines[i].lstrip().startswith("|"):
                row = cells(lines[i])
                # Pad or trim to the header width so a miscounted row cannot
                # break the table's shape.
                row = (row + [""] * len(head))[:len(head)]
                out.append("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in row) + "</tr>")
                i += 1
            out.append("</tbody></table>")
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


# --- Syntax highlighting -----------------------------------------------------
# Two languages, a few hundred tokens. A highlighter library would be a
# dependency and a render-blocking script for that; these are line-oriented
# regexes over already-escaped text, which is enough for JSON and shell and
# cannot mangle anything it does not recognise.

def highlight(line: str, lang: str) -> str:
    esc = html.escape(line)
    if lang == "json":
        # Keys before values: the key pattern is anchored on the following colon,
        # so a string value is never mistaken for one.
        esc = re.sub(r'(&quot;[^&]*?&quot;)(\s*:)', r'<span class="tok-key">\1</span>\2', esc)
        esc = re.sub(r'(:\s*)(&quot;.*?&quot;)', r'\1<span class="tok-str">\2</span>', esc)
        esc = re.sub(r'\b(-?\d+\.?\d*)\b', r'<span class="tok-num">\1</span>', esc)
        esc = re.sub(r'\b(true|false|null)\b', r'<span class="tok-lit">\1</span>', esc)
        # A trailing // comment is not legal JSON, but the examples use them to
        # annotate; they are marked as comments so nobody copies one by accident.
        esc = re.sub(r'(//.*)$', r'<span class="tok-com">\1</span>', esc)
    elif lang in ("bash", "sh", "shell"):
        esc = re.sub(r'^(\s*)(#.*)$', r'\1<span class="tok-com">\2</span>', esc)
        esc = re.sub(r'(\$\{?[A-Za-z_][A-Za-z0-9_]*\}?)', r'<span class="tok-var">\1</span>', esc)
        esc = re.sub(r'\b(if|then|fi|for|do|done|while|read|echo|cd|mkdir|cp|git|export|local)\b',
                     r'<span class="tok-kw">\1</span>', esc)
    elif lang == "swift":
        esc = re.sub(r'\b(let|var|func|struct|enum|public|return|if|else|guard|for|in)\b',
                     r'<span class="tok-kw">\1</span>', esc)
        esc = re.sub(r'(//.*)$', r'<span class="tok-com">\1</span>', esc)
    return esc


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


# Content hash of the stylesheet, appended to its URL.
#
# Pages serves assets with `cache-control: max-age=14400`, so a visitor can hold
# a four-hour-old stylesheet while fetching fresh HTML. That combination is not
# merely stale, it is broken: the hero canvas relies on CSS to be positioned and
# sized, and without it the element falls into normal flow at its attribute size
# — shoving the page down and putting the wave off-centre. Hashing the URL means
# changed CSS is always a different URL, so the two can never disagree.
def asset_version() -> str:
    css = (ROOT / "site" / "style.css").read_bytes()
    return hashlib.sha256(css).hexdigest()[:10]


def page(title: str, body: str, *, nav: str = "", cls: str = "") -> str:
    open_body = '<article class="guide-body">' if cls == "guide" else ""
    close_body = "</article>" if cls == "guide" else ""
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<meta name="description" content="Live transcripts of every meeting, recorded, transcribed and summarized entirely on your own Mac, iPhone and iPad.">
<link rel="stylesheet" href="/style.css?v={ASSET_V}">
<link rel="icon" href="/icon.png">
{ANALYTICS}
</head>
<body class="{cls}">
<header class="top">
  <a class="wordmark" href="/"><img src="/icon.png" alt="" width="28" height="28">Transcripts</a>
  <nav><a href="/guide/">User guide</a><a href="/#download">Download</a></nav>
</header>
<main>{nav}{open_body}{body}{close_body}</main>
<footer>
  <p>Transcripts is made by <a href="https://hatcher.ltd">Doug Hatcher</a>.
     <a href="/guide/privacy/">Privacy</a> ·
     <a href="https://github.com/hatcher-ltd/transcripts-support/issues">Report an issue</a> ·
     <a href="mailto:support@hatcher.ltd">Support</a></p>
</footer>
</body>
</html>
"""


ASSET_V = ""


def build():
    global ASSET_V
    ASSET_V = asset_version()
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
    def sidebar(current: str) -> str:
        out = ['<nav class="guide-nav" aria-label="Guide">']
        for heading, pages in GUIDE_SECTIONS:
            # Each section is one element, so the narrow-screen grid keeps a
            # heading with its own links instead of flowing them into separate
            # columns.
            out.append(f'<div class="nav-section"><h4>{html.escape(heading)}</h4><ul>')
            for slug, title in pages:
                href = "/guide/" + ("" if slug == "index" else slug + "/")
                # aria-current is the accessible signal; the class is the visual
                # one. Both, because "where am I" is the question a sidebar
                # exists to answer.
                mark = ' class="here" aria-current="page"' if slug == current else ""
                out.append(f'<li><a href="{href}"{mark}>{html.escape(title)}</a></li>')
            out.append("</ul></div>")
        out.append("</nav>")
        return "".join(out)

    for slug, title in GUIDE_PAGES:
        src = GUIDE_SRC / f"{slug}.md"
        if not src.exists():
            print(f"  ! missing {src.relative_to(ROOT)}")
            continue
        body = md(src.read_text())
        dest = OUT / "guide" / ("index.html" if slug == "index" else f"{slug}/index.html")
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(page(f"{title} — Transcripts guide", body,
                             nav=sidebar(slug), cls="guide"))
        print(f"  ✓ /guide/{'' if slug == 'index' else slug + '/'}")

    # Cloudflare Pages redirects. /privacy is the URL given to App Store Connect
    # as the Privacy Policy link, and Apple re-fetches it for as long as the app
    # is listed — so it has to be a path the guide's structure cannot break. The
    # page itself stays in the guide, where it is written and reviewed.
    (OUT / "_redirects").write_text(
        "/privacy    /guide/privacy/    301\n"
        "/support    /guide/            301\n")
    print("  ✓ /privacy → /guide/privacy/")

    print(f"✓ built → {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    build()
    if "--serve" in sys.argv:
        import http.server, os, socketserver
        os.chdir(OUT)
        print("→ http://localhost:8000")
        socketserver.TCPServer(("", 8000), http.server.SimpleHTTPRequestHandler).serve_forever()
