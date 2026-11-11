# slimg.app

Slimg's website, built to the Ladrillo Studio app site recipe: the same pages,
skeleton, hosting and home-page blocks as every studio app site, in Slimg's
teal. Unfolded's site is the reference.

```
web/
  build.py         Writes every page in site/ from one template, plus sitemap.xml, robots.txt, llms.txt
  pages/           The body of each page (everything between the nav and the footer)
  site/            What gets deployed. site.css, _headers, img/ and og.png are edited here directly
  shots/           Sources for the window images in site/img/ and for og.png
  worker/          The Cloudflare Worker: serves site/, the contact form, download redirects
```

## Working on it

```sh
python3 web/build.py            # rebuild site/ after changing build.py or pages/
python3 web/build.py --serve    # rebuild, then preview at http://localhost:8753
python3 web/build.py --check    # what CI runs: fails if site/ is out of date
node web/shots/render.mjs       # re-render site/img/*.webp and site/og.png
```

Never edit the HTML in `site/` by hand. Change `pages/` or the template in
`build.py` and rebuild. CI fails when the two disagree.

## Pages

| Path | What it is |
|---|---|
| `/` | Home, on the recipe |
| `/download` | The app (Slimg.dmg) and the command-line tool, with the first-launch steps |
| `/support` | Getting started, the command line, troubleshooting, questions, requirements, contact form |
| `/support/sent` | "Message sent." `noindex`, not in the sitemap |
| `/privacy` | Privacy policy, checked against `Sources/` on November 11, 2026 |
| `/release-notes` | From `CHANGELOG.md`, rewritten for customers |

Where Slimg differs from the recipe, and why:

- **`/download` exists** because Slimg is a direct-download build: it isn't on
  the Mac App Store (the sandbox doesn't fit its in-place, any-folder
  workflow; see `ROADMAP.md`). The page carries the Gatekeeper step that
  unnotarized builds need.
- **No store badge.** The nav and the calls to action use a plain Download
  button that goes to `/download`. If Slimg ever ships on the Mac App Store,
  swap in Apple's "Download on the Mac App Store" badge.
- **The footer says License, not Terms.** Slimg is free and MIT-licensed,
  with no EULA. `/license` redirects to the LICENSE file.
- **No Purchases section and no Purchase topic.** Nothing is sold.
- **A "Command line" section on the support page.** It's the reference for
  the `slimg` tool's options.
- **JSON-LD uses `SoftwareApplication`**, not `MobileApplication`, because
  Slimg is a Mac app.

## Links that leave the site

The pages never print the GitHub address, because the repository is under a
personal account. They link to slimg.app paths, and the Worker redirects each
one (the `REDIRECTS` table in `worker/src/index.js`):

| Path | Goes to |
|---|---|
| `/download/Slimg.dmg` (and `.sha256`) | The latest release's DMG on GitHub |
| `/download/slimg-cli-macos.tar.gz` (and `.sha256`) | The latest release's CLI archive |
| `/source` | The repository |
| `/license` | `LICENSE` in the repository |

If the repository moves, for example to a Ladrillo Studio organization,
change `REPO` in that file and redeploy. No page changes.

## Images

The window images in `site/img/` are **stand-ins**. They're drawn in HTML from
the app's SwiftUI source (`shots/shots.html`: same layout, labels, number
formatting and colors, in dark mode) because the site was built without a
Mac. Replace each one with a real capture: a dark-mode window with its
shadow on transparency, about 1600 px wide, WebP under 80 KB. Use a **new
file name** for each replacement (`main-window-2.webp`), because `/img/*` is
cached for a year.

| File | Shows |
|---|---|
| `main-window.webp` | Hero: the window after a drop of six images |
| `report.webp` | The advanced report for IMG_2048.jpg |
| `drop-folder.webp` | The empty window with a folder being dragged in |
| `settings.webp` | Settings, with the seven extra methods off |
| `terminal.webp` | `slimg --report`, `--dry-run` and `--recompress-gif` in Terminal |

All the numbers agree with each other: the 2.4 MB photo loses 288.0 KB of
EXIF, 12.4 KB of XMP and 3.1 KB of IPTC data, 303.5 KB or 12.4%, in the hero,
the report, the signature section and the terminal.

The signature section ("What a photo carries.") is SVG in `pages/index.html`,
with a wide version and a phone version.

## Hosting

Cloudflare, one Worker with static assets (`worker/wrangler.toml`):

- `slimg.app` as the Worker's custom domain. www redirects to the apex (a
  Redirect Rule in the zone). Always Use HTTPS on.
- `POST /contact` sends the support form through Cloudflare Email Routing,
  from `form@ladrillostudio.com` to the `CONTACT_TO` secret, with Reply-To
  set to the customer. 5 messages a minute per address; honeypot spam is
  dropped without a word.
- `site/_headers` sets the CSP (no scripts at all), and caches `/img/*` for a
  year.

### Before the first deploy

1. Set `namespace_id` in `worker/wrangler.toml` to a number no other studio
   site's rate limiter uses.
2. Point slimg.app's DNS at Cloudflare. The old site was on GitHub Pages; its
   workflow is gone, so the old pages stay up until DNS moves.
3. Make sure `form@ladrillostudio.com` can send to the studio inbox through
   Email Routing.

### Deploying (only on ladrillo's go)

```sh
export HOME=/private/tmp/slimg-cf WRANGLER_SEND_METRICS=false
cd web/worker
npx -y wrangler@4 login
npx -y wrangler@4 whoami
npx -y wrangler@4 deploy
npx -y wrangler@4 secret put CONTACT_TO     # once
npx -y wrangler@4 logout
rm -rf /private/tmp/slimg-cf
```

### Before every upload

1. Every page in light and dark, at 1280 px and 375 px. No sideways scroll.
2. Scan for personal names, usernames, personal email addresses and
   `/Users/` paths.
3. Every page returns 200; `/support/sent` is `noindex`.
4. The CSP header is live, a post to `/contact` from another origin gets 403,
   and one real test message reaches the inbox.
5. Update the log below.

## Log

- **November 11, 2026.** Rebuilt on the Ladrillo recipe, replacing the
  GitHub Pages site. Checked locally with `wrangler dev`: every page returns
  200, the headers are set, `/support/sent` is `noindex`, a cross-origin post
  gets 403, honeypot posts are dropped, the sixth message in a minute gets
  429, and the redirects resolve. **Not deployed yet.**
