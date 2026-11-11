#!/usr/bin/env python3
"""Builds the Slimg site (web/site/) from one template, so the head, nav and
footer never drift between pages.

    python3 web/build.py            write web/site/
    python3 web/build.py --check    exit 1 if web/site/ is out of date (CI)
    python3 web/build.py --serve    build, then serve web/site/ on :8753

Page bodies live in web/pages/. Everything else in web/site/ (site.css, img/,
_headers, icons) is edited in place and only copied around by hand.
See web/README.md for what each page is and how the site is deployed.
"""

import html
import http.server
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent
PAGES = ROOT / "pages"
SITE = ROOT / "site"
DOMAIN = "slimg.app"
ORIGIN = f"https://{DOMAIN}"
APP = "Slimg"
VERSION = "1.1.0"

OG_ALT = "The Slimg icon and the line: Slim your images. Lose nothing. Lossless image optimizer for Mac."

# Every page on the site. "src" is the body in web/pages/, "out" the file
# written into web/site/, "path" the URL Cloudflare serves it at.
PAGES_META = [
    {
        "src": "index.html",
        "out": "index.html",
        "path": "/",
        "title": "Slimg: lossless image optimizer for Mac",
        "description": "Slimg makes JPEG, PNG, GIF and HEIC files smaller on your Mac without changing a single pixel. Free and open source. Nothing leaves your Mac.",
    },
    {
        "src": "download.html",
        "out": "download.html",
        "path": "/download",
        "title": "Download Slimg for Mac",
        "description": "Download the Slimg app or the slimg command-line tool for macOS 13 or later, on Apple silicon and Intel.",
        "current": "/download",
    },
    {
        "src": "support.html",
        "out": "support.html",
        "path": "/support",
        "title": "Slimg Support",
        "description": "Help with Slimg: getting started, the command-line tool, troubleshooting, questions and how to reach us.",
        "current": "/support",
    },
    {
        "src": "support-sent.html",
        "out": "support/sent.html",
        "path": "/support/sent",
        "title": "Message sent. Slimg Support",
        "description": "Your message to Slimg support was sent.",
        "noindex": True,
    },
    {
        "src": "privacy.html",
        "out": "privacy.html",
        "path": "/privacy",
        "title": "Slimg Privacy Policy",
        "description": "Slimg works entirely on your Mac. It has no account, no analytics, no ads and makes no network connections.",
    },
    {
        "src": "release-notes.html",
        "out": "release-notes.html",
        "path": "/release-notes",
        "title": "Slimg Release Notes",
        "description": "What's new in each version of Slimg, the lossless image optimizer for Mac.",
    },
]

TEMPLATE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>{title}</title>
<meta name="description" content="{description}">
{canonical}<meta name="theme-color" content="#F5F5F7" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#0E0E10" media="(prefers-color-scheme: dark)">
<link rel="icon" href="/favicon-32.png" type="image/png" sizes="32x32">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<meta property="og:type" content="website">
<meta property="og:site_name" content="{app}">
<meta property="og:title" content="{title}">
<meta property="og:description" content="{description}">
<meta property="og:url" content="{url}">
<meta property="og:image" content="{origin}/og.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="{og_alt}">
<meta name="twitter:card" content="summary_large_image">
<link rel="stylesheet" href="/site.css">
{jsonld}</head>
<body>
<header class="nav">
  <div class="wrap">
    <a class="brand" href="/"><img src="/img/icon.png" alt="" width="30" height="30">{app}</a>
    <nav aria-label="Main"><a href="{home}#features">Features</a><a href="{home}#pricing">Pricing</a><a href="/support"{support_current}>Support</a></nav>
    <a class="btn" href="/download"{download_current}>Download</a>
  </div>
</header>

{body}
<footer>
  <div class="wrap">
    <div class="links"><a href="/privacy">Privacy</a><a href="/support">Support</a><a href="/license">License</a><a href="/release-notes">Release notes</a></div>
    <a class="ladrillo-app" href="https://ladrillostudio.com"><svg viewBox="0 0 100 50" aria-hidden="true"><rect x="0" y="27" width="48" height="23" rx="3"/><rect x="52" y="27" width="48" height="23" rx="3"/><rect x="26" y="0" width="48" height="23" rx="3"/></svg><span>A Ladrillo Studio app</span></a>
    <span>© 2026 Ladrillo Studio</span>
    <p class="tm">Apple, Mac, macOS, Finder, iPhone and Apple silicon are trademarks of Apple Inc., registered in the U.S. and other countries. Intel is a trademark of Intel Corporation.</p>
  </div>
</footer>
</body>
</html>
"""

JSONLD = {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    "name": APP,
    "description": "A lossless image optimizer for Mac. Slimg makes JPEG, PNG, GIF and HEIC files smaller without changing a single pixel.",
    "operatingSystem": "macOS 13 or later",
    "applicationCategory": "UtilitiesApplication",
    "softwareVersion": VERSION,
    "url": f"{ORIGIN}/",
    "downloadUrl": f"{ORIGIN}/download",
    "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
    "publisher": {"@type": "Organization", "name": "Ladrillo Studio", "url": "https://ladrillostudio.com"},
}

ROBOTS = f"""User-agent: *
Allow: /
Disallow: /support/sent

Sitemap: {ORIGIN}/sitemap.xml
"""

LLMS = f"""# {APP}

> {APP} is a lossless image optimizer for Mac, made by Ladrillo Studio. It makes JPEG, PNG, GIF and HEIC files smaller by removing metadata (camera details, location, editor notes) and storing the same pixels more efficiently. The decoded pixels are identical to the original, and a file never comes out larger. It runs entirely on the Mac: no uploads, no account, no analytics. Free and open source under the MIT License. Requires macOS 13 or later, on Apple silicon or Intel.

## Pages

- [Home]({ORIGIN}/): what {APP} does, its features and price (free)
- [Download]({ORIGIN}/download): the app (Slimg.dmg) and the slimg command-line tool
- [Support]({ORIGIN}/support): getting started, command-line options, troubleshooting, questions, and the contact form
- [Privacy]({ORIGIN}/privacy): {APP} keeps nothing and sends nothing; everything stays on the Mac
- [Release notes]({ORIGIN}/release-notes): what changed in each version

## Facts

- Current version: {VERSION}
- Formats: JPEG, PNG, GIF, HEIC and HEIF (HEVC images)
- Price: free
- License: MIT ({ORIGIN}/license)
- Source code: {ORIGIN}/source
- Contact: the form at {ORIGIN}/support#contact
"""

# Files copied from brand/web/ (made by Scripts/generate-icons.swift).
BRAND_WEB = ROOT.parent / "brand" / "web"
COPIES = {
    "favicon-32.png": "favicon-32.png",
    "favicon-180.png": "apple-touch-icon.png",
}


def render(meta):
    body = (PAGES / meta["src"]).read_text(encoding="utf-8")
    path = meta["path"]
    url = ORIGIN + path
    is_home = path == "/"
    if meta.get("noindex"):
        canonical = '<meta name="robots" content="noindex">\n'
    else:
        canonical = f'<link rel="canonical" href="{url}">\n'
    jsonld = ""
    if is_home:
        jsonld = '<script type="application/ld+json">' + json.dumps(JSONLD, separators=(",", ":")) + "</script>\n"
    current = meta.get("current")
    return TEMPLATE.format(
        title=html.escape(meta["title"]),
        description=html.escape(meta["description"]),
        canonical=canonical,
        url=url,
        origin=ORIGIN,
        app=APP,
        og_alt=html.escape(OG_ALT),
        jsonld=jsonld,
        home="" if is_home else "/",
        support_current=' aria-current="page"' if current == "/support" else "",
        download_current=' aria-current="page"' if current == "/download" else "",
        body=body if body.endswith("\n") else body + "\n",
    )


def sitemap():
    urls = "".join(
        f"  <url><loc>{ORIGIN}{m['path']}</loc></url>\n" for m in PAGES_META if not m.get("noindex")
    )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        f"{urls}</urlset>\n"
    )


def outputs():
    """Every generated file: relative path in web/site/ -> bytes."""
    files = {m["out"]: render(m).encode("utf-8") for m in PAGES_META}
    files["sitemap.xml"] = sitemap().encode("utf-8")
    files["robots.txt"] = ROBOTS.encode("utf-8")
    files["llms.txt"] = LLMS.encode("utf-8")
    for src, dst in COPIES.items():
        files[dst] = (BRAND_WEB / src).read_bytes()
    return files


def main(argv):
    files = outputs()
    if "--check" in argv:
        stale = [name for name, data in files.items() if not (SITE / name).exists() or (SITE / name).read_bytes() != data]
        if stale:
            print("web/site/ is out of date. Run: python3 web/build.py", file=sys.stderr)
            for name in stale:
                print(f"  {name}", file=sys.stderr)
            return 1
        print("web/site/ is up to date.")
        return 0

    for name, data in files.items():
        target = SITE / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    print(f"Wrote {len(files)} files to {SITE.relative_to(ROOT.parent)}/")

    if "--serve" in argv:
        serve()
    return 0


def serve(port=8753):
    """Serves web/site/ the way Cloudflare does: /support -> support.html."""

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(SITE), **kwargs)

        def translate_path(self, path):
            local = pathlib.Path(super().translate_path(path))
            page = local.with_suffix(".html")
            if local.suffix == "" and not (local / "index.html").exists() and page.exists():
                return str(page)
            return str(local)

    print(f"Serving http://localhost:{port}/")
    http.server.ThreadingHTTPServer(("", port), Handler).serve_forever()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
