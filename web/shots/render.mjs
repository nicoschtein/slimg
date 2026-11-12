// Renders shots.html scenes and og.html into web/site/ images.
//   node web/shots/render.mjs
// Needs Playwright with Chromium, and Python 3 with Pillow for WebP.
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import fs from "node:fs";
const { chromium } = createRequire(import.meta.url)("playwright");

const here = path.dirname(fileURLToPath(import.meta.url));
const img = path.join(here, "..", "site", "img");
const tmp = fs.mkdtempSync(path.join(process.env.TMPDIR || "/tmp", "slimg-shots-"));
fs.mkdirSync(img, { recursive: true });

const scenes = { main: "main-window", report: "report", drop: "drop-folder", settings: "settings", terminal: "terminal" };

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 800, height: 560 }, deviceScaleFactor: 2 });
for (const [scene, name] of Object.entries(scenes)) {
  await page.goto(`file://${path.join(here, "shots.html")}?scene=${scene}`);
  await page.evaluate(() => document.fonts.ready);
  const png = path.join(tmp, `${name}.png`);
  await page.screenshot({ path: png, omitBackground: true });
  if (scene === "main") console.log("totals", JSON.stringify(await page.evaluate(() => window.SUMMARY)));
  execFileSync("python3", [path.join(here, "webp.py"), png, path.join(img, `${name}.webp`)], { stdio: "inherit" });
}

const og = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
await og.goto(`file://${path.join(here, "og.html")}`);
await og.evaluate(() => document.fonts.ready);
await og.screenshot({ path: path.join(here, "..", "site", "og.png") });
await browser.close();
fs.rmSync(tmp, { recursive: true, force: true });
