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
`build.py` and rebuild. CI fails when the two disagree, or when `site/` still
holds a page `build.py` no longer makes (a plain build deletes it).

**On a release,** set `VERSION` in `build.py` (pages write `{{VERSION}}`
wherever they show it), add the release to `pages/release-notes.html`, and
rebuild. `YEAR` in `build.py` is the footer's copyright year.

## Pages

| Path | What it is |
|---|---|
| `/` | Home, on the recipe |
| `/download` | The app (Slimg.dmg) and the command-line tool, with the first-launch steps |
| `/support` | Getting started, the command line, troubleshooting, questions, requirements, contact form |
| `/support/sent` | "Message sent." `noindex`, not in the sitemap |
| `/support/not-sent` | "Message not sent." when a field fails the Worker's checks. `noindex`, not in the sitemap |
| `/privacy` | Privacy policy, checked against `Sources/` on November 11, 2026 |
| `/release-notes` | From `CHANGELOG.md`, rewritten for customers |

Where Slimg differs from the recipe, and why:

- **`/download` exists** because Slimg is a direct-download build: it isn't on
  the Mac App Store (the sandbox doesn't fit its in-place, any-folder
  workflow; see `ROADMAP.md`). The page carries the Gatekeeper step that
  unnotarized builds need: System Settings > Privacy & Security > Open
  Anyway, which works on macOS 13 and later (macOS 15 removed the
  Control-click > Open shortcut).
- **No store badge.** The nav and the calls to action use a plain Download
  button that goes to `/download`. If Slimg ever ships on the Mac App Store,
  swap in Apple's "Download on the Mac App Store" badge.
- **The footer says License, not Terms.** Slimg is free and MIT-licensed,
  with no EULA. `/license` redirects to the LICENSE file.
- **No Purchases section and no Purchase topic.** Nothing is sold.
- **`/support/not-sent` exists** because the page has no script: when the
  Worker turns a post away, this page says what to check and that the
  browser's Back button still has the message, instead of a silent bounce
  to an empty form.
- **The honeypot field is `hp_leave_empty`, not `website`.** Browsers and
  password managers autofill fields named website, which would make real
  messages vanish as spam.
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
  from `form@slimg.app` to the `CONTACT_TO` secret, with Reply-To set to
  the customer. Email Routing is on in the slimg.app zone (its MX and SPF
  records), and `CONTACT_TO` must be a verified Email Routing destination
  address in the same Cloudflare account. 5 messages a minute per address; honeypot spam is
  dropped without a word. The email is 7-bit MIME with CRLF line ends: the
  subject is RFC 2047 encoded when it isn't plain ASCII, the body is base64,
  so any language and any message length up to the form's limit goes
  through. The server accepts exactly the email addresses the browser does.
- `site/_headers` sets the CSP (no scripts at all), and caches `/img/*` for a
  year.

### Before the first deploy

1. Check that `namespace_id` in `worker/wrangler.toml` (75464) isn't used by
   another studio site's rate limiter.
2. Point slimg.app's DNS at Cloudflare. The old site was on GitHub Pages; its
   workflow is gone, so the old pages stay up until DNS moves.
3. Make sure Email Routing is enabled in the slimg.app zone, so
   `form@slimg.app` can send, and that the `CONTACT_TO` inbox is a verified
   destination address.

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
  429, and the redirects resolve.
- **November 11, 2026.** Review fixes: email encoding (CRLF, base64 body,
  encoded subject), the body cap sized for non-ASCII messages, browser-matched
  email check, `/support/not-sent`, the honeypot rename, the macOS 15
  Gatekeeper steps, `{{VERSION}}` in pages, and stale-page detection. Checked
  with `wrangler dev`: multi-line, emoji, 1,500-character Japanese and
  5,000-character messages all arrive and decode exactly.
- **November 11, 2026.** Deployed to slimg.app as the `slimg-site` Worker.
  The zone's old CNAME to GitHub Pages had to be deleted in the dashboard
  first: `wrangler deploy` can't replace an existing DNS record (error
  100117) and doesn't offer to. The contact form sends from `form@slimg.app`
  to the `CONTACT_TO` secret. Checked live: every page and `robots.txt`,
  `sitemap.xml` and `llms.txt` return 200; the CSP header is on `/`;
  `/img/*` is cached for a year; `/support/sent` and `/support/not-sent`
  are `noindex`; `/download/Slimg.dmg`, `/source` and `/license` redirect
  (302) to GitHub; www redirects (301) to the apex; a cross-origin post to
  `/contact` gets 403; and one real test message sent through the support
  form reached the inbox.
- **November 11, 2026.** Redeployed for Slimg 1.1.1, after the release was
  published. Checked live: every page returns 200, the home and download
  pages show version 1.1.1, the release notes lead with 1.1.1, the CSP header
  is on `/`, a cross-origin post to `/contact` gets 403, and
  `/download/Slimg.dmg` serves the 1.1.1 DMG with a matching SHA-256. The
  `cf` CLI (`cf dns records ...`) can change the zone's DNS records, which
  `wrangler` can't.
