// Slimg's site Worker: serves web/site/, answers POST /contact from the
// support page, relayed to the inbox through Cloudflare Email Routing, and
// redirects the download and source links to where the files live
// (web/README.md).
//
// The page has no script, so the form posts urlencoded fields and the answer
// is always a redirect: /support/sent when the message went (or was quietly
// dropped as spam), /support#contact when a field was missing. Nothing is
// stored. The destination address is an environment variable, never source.
import { EmailMessage } from "cloudflare:email";

const ORIGIN = "https://slimg.app";
const TOPICS = new Set(["Problem", "Question", "Idea"]);
const LIMITS = { email: 254, message: 5000, versions: 120 };
const FROM = "form@ladrillostudio.com";

// Where the releases and the source live. The site's pages only ever link to
// the slimg.app paths on the left, so moving the repository means changing
// this one table and nothing else.
const REPO = "https://github.com/nicoschtein/slimg";
const LATEST = `${REPO}/releases/latest/download`;
const REDIRECTS = new Map([
  ["/download/Slimg.dmg", `${LATEST}/Slimg.dmg`],
  ["/download/Slimg.dmg.sha256", `${LATEST}/Slimg.dmg.sha256`],
  ["/download/slimg-cli-macos.tar.gz", `${LATEST}/slimg-cli-macos.tar.gz`],
  ["/download/slimg-cli-macos.tar.gz.sha256", `${LATEST}/slimg-cli-macos.tar.gz.sha256`],
  ["/source", REPO],
  ["/license", `${REPO}/blob/main/LICENSE`],
]);

function redirect(request, path) {
  return Response.redirect(new URL(path, request.url).toString(), 303);
}

function clean(value, max) {
  return String(value ?? "").replace(/\r/g, "").trim().slice(0, max);
}

// A header value may not carry a line break (header injection).
function header(value) {
  return value.replace(/[\r\n]+/g, " ");
}

async function contact(request, env) {
  if (request.method !== "POST") return redirect(request, "/support#contact");

  // Only the site's own form may post. A browser sends the page's origin
  // with a form post; a post from another origin is not our form. A missing
  // Origin is let through: some browsers and privacy settings omit it, and
  // the rate limit still applies.
  const origin = request.headers.get("origin");
  if (origin !== null && origin !== ORIGIN) {
    return new Response("Forbidden", { status: 403, headers: { "content-type": "text/plain; charset=utf-8" } });
  }

  const type = request.headers.get("content-type") || "";
  if (!type.startsWith("application/x-www-form-urlencoded")) return redirect(request, "/support#contact");
  const body = await request.text();
  if (body.length > 16000) return redirect(request, "/support#contact");
  const form = new URLSearchParams(body);

  // The honeypot: a field people never see. A bot that fills it gets the
  // same answer a person does, and nothing is sent.
  if (clean(form.get("website"), 200)) return redirect(request, "/support/sent");

  const email = clean(form.get("email"), LIMITS.email);
  const topic = clean(form.get("topic"), 40);
  const message = clean(form.get("message"), LIMITS.message);
  const versions = clean(form.get("versions"), LIMITS.versions);
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || !TOPICS.has(topic) || message.length < 2) {
    return redirect(request, "/support#contact");
  }

  // A basic rate limit per address. Closed without it.
  if (!env.LIMITER) return new Response("The contact form is not set up yet.", { status: 503 });
  const ip = request.headers.get("cf-connecting-ip") || "unknown";
  const { success } = await env.LIMITER.limit({ key: ip });
  if (!success) {
    return new Response("Too many messages. Try again in a minute.", {
      status: 429,
      headers: { "content-type": "text/plain; charset=utf-8", "retry-after": "60" },
    });
  }

  const to = env.CONTACT_TO;
  if (!to) return new Response("The contact form is not set up yet.", { status: 503 });

  const subject = header(`[Slimg] ${topic}: ${message.split("\n")[0].slice(0, 60)}`);
  const text = [
    `From: ${email}`,
    `Topic: ${topic}`,
    `Slimg and macOS version: ${versions || "not given"}`,
    "",
    message,
  ].join("\n");
  const raw = [
    `From: Slimg contact form <${FROM}>`,
    `To: ${header(to)}`,
    `Reply-To: ${header(email)}`,
    `Subject: ${subject}`,
    `Message-ID: <${crypto.randomUUID()}@ladrillostudio.com>`,
    `Date: ${new Date().toUTCString()}`,
    "MIME-Version: 1.0",
    "Content-Type: text/plain; charset=utf-8",
    "Content-Transfer-Encoding: 8bit",
    "",
    text,
  ].join("\r\n");

  try {
    await env.CONTACT.send(new EmailMessage(FROM, to, raw));
  } catch (error) {
    return new Response("The message could not be sent. Try again later.", { status: 502 });
  }
  return redirect(request, "/support/sent");
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/contact") return contact(request, env);
    const target = REDIRECTS.get(url.pathname);
    if (target) return Response.redirect(target, 302);
    // Everything else is the static site.
    return env.ASSETS.fetch(request);
  },
};
