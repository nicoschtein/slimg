// Slimg's site Worker: serves web/site/, answers POST /contact from the
// support page, relayed to the inbox through Cloudflare Email Routing, and
// redirects the download and source links to where the files live
// (web/README.md).
//
// The page has no script, so the form posts urlencoded fields and the answer
// is always a redirect: /support/sent when the message went (or was quietly
// dropped as spam), /support/not-sent when a field was wrong, which tells the
// person what to check and that Back still has their message. Nothing is
// stored. The destination address is an environment variable, never source.
import { EmailMessage } from "cloudflare:email";

const ORIGIN = "https://slimg.app";
const TOPICS = new Set(["Problem", "Question", "Idea"]);
// In UTF-16 units, the same unit the form's maxlength counts.
const LIMITS = { email: 254, message: 5000, versions: 120 };
// The largest body the form can send: every field at its maxlength in the
// worst case of URL encoding (a 3-byte UTF-8 character is 9 characters
// percent-encoded, per UTF-16 unit), plus the field names. Anything larger is
// not from our form.
const MAX_BODY = (LIMITS.email + LIMITS.message + LIMITS.versions + 40) * 9 + 200;
const FROM = "form@slimg.app";
const NOT_SENT = "/support/not-sent";

// The browser's own rule for type="email" (HTML Standard, "valid email
// address"), so the server never turns away an address the form accepted.
// It is ASCII only, which also keeps it safe to put in a header.
const EMAIL = /^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/;

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
  return String(value ?? "").replace(/\r\n?/g, "\n").trim().slice(0, max);
}

// A header value may not carry a line break (header injection).
function header(value) {
  return value.replace(/[\r\n]+/g, " ");
}

function base64(text) {
  const bytes = new TextEncoder().encode(text);
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

// A header holding any text: plain when it's printable ASCII, otherwise RFC
// 2047 encoded-words. Each word stays under 75 characters and never splits a
// character, so the header is 7-bit and every line is short.
function encodedHeader(text) {
  if (/^[\x20-\x7E]*$/.test(text)) return text;
  const words = [];
  let chunk = "";
  for (const char of text) {
    // 45 UTF-8 bytes is 60 base64 characters, 72 with the =?UTF-8?B?...?=.
    if (new TextEncoder().encode(chunk + char).length > 45) {
      words.push(chunk);
      chunk = "";
    }
    chunk += char;
  }
  if (chunk) words.push(chunk);
  return words.map((word) => `=?UTF-8?B?${base64(word)}?=`).join("\r\n ");
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
  if (!type.startsWith("application/x-www-form-urlencoded")) return redirect(request, NOT_SENT);
  if (Number(request.headers.get("content-length") || 0) > MAX_BODY) return redirect(request, NOT_SENT);
  const body = await request.text();
  if (body.length > MAX_BODY) return redirect(request, NOT_SENT);
  const form = new URLSearchParams(body);

  // The honeypot: a field people never see, with a name autofill has no
  // reason to fill. A bot that fills it gets the same answer a person does,
  // and nothing is sent.
  if (clean(form.get("hp_leave_empty"), 200)) return redirect(request, "/support/sent");

  const email = clean(form.get("email"), LIMITS.email);
  const topic = clean(form.get("topic"), 40);
  const message = clean(form.get("message"), LIMITS.message);
  const versions = clean(form.get("versions"), LIMITS.versions);
  if (!EMAIL.test(email) || !TOPICS.has(topic) || message.length === 0) {
    return redirect(request, NOT_SENT);
  }

  // A basic rate limit per address. Closed without it.
  if (!env.LIMITER) return new Response("The contact form is not set up yet.", { status: 503 });
  const ip = request.headers.get("cf-connecting-ip") || "unknown";
  const { success } = await env.LIMITER.limit({ key: ip });
  if (!success) {
    return new Response("Too many messages. Try again in a minute. Your browser's Back button still has what you wrote.", {
      status: 429,
      headers: { "content-type": "text/plain; charset=utf-8", "retry-after": "60" },
    });
  }

  const to = env.CONTACT_TO;
  if (!to) return new Response("The contact form is not set up yet.", { status: 503 });

  const firstLine = Array.from(message.split("\n")[0]).slice(0, 60).join("");
  const text = [
    `From: ${email}`,
    `Topic: ${topic}`,
    `Slimg and macOS version: ${header(versions) || "not given"}`,
    "",
    message,
  ].join("\n").replace(/\n/g, "\r\n");
  // The body goes as base64: 7-bit, CRLF only, and no line over 76
  // characters whatever the person typed.
  const encodedBody = base64(text).replace(/.{76}(?=.)/g, "$&\r\n");
  const raw = [
    `From: Slimg contact form <${FROM}>`,
    `To: ${header(to)}`,
    `Reply-To: ${email}`,
    `Subject: ${encodedHeader(`[Slimg] ${topic}: ${header(firstLine)}`)}`,
    `Message-ID: <${crypto.randomUUID()}@slimg.app>`,
    `Date: ${new Date().toUTCString()}`,
    "MIME-Version: 1.0",
    "Content-Type: text/plain; charset=utf-8",
    "Content-Transfer-Encoding: base64",
    "",
    encodedBody,
  ].join("\r\n");

  try {
    await env.CONTACT.send(new EmailMessage(FROM, to, raw));
  } catch (error) {
    return new Response("The message could not be sent. Try again later. Your browser's Back button still has what you wrote.", { status: 502 });
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
