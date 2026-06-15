# Security Policy

## Threat model & scope

Slimg is a **fully on-device** macOS image optimizer. It has **no network access, no telemetry, no analytics, and no auto-update** — it never transmits your images or any data off your machine. This sharply limits the threat model: there is no server to attack and no data to exfiltrate remotely.

The only untrusted input Slimg processes is the **image file itself** (JPEG, PNG, GIF). Slimg parses these files with its own byte-level parsers and a small C zlib shim. The security-relevant risks are therefore:

- A **maliciously crafted image** that triggers a crash, an out-of-bounds read, or unbounded memory use (denial of service) while being parsed or recompressed.
- **Local file-handling** issues (e.g. clobbering or corrupting a file, following a symlink to write outside the intended location).

Slimg is designed to be **byte-for-byte lossless** (decoded pixels are never altered) and to **never produce a file larger than the input**; on any unexpected/malformed input it bails out and keeps your original bytes untouched.

### In scope

- Memory-safety bugs (out-of-bounds read/write, integer overflow) in the JPEG/PNG/GIF parsers or the `CZlib` shim.
- Decompression-bomb / unbounded-memory (DoS) issues in zlib inflate/deflate handling.
- File-handling bugs that could corrupt, destroy, or overwrite the wrong file, or write through a symlink to an unintended location.
- Any path that violates the lossless or "never grow" guarantees.

### Out of scope

- Issues requiring a compromised local account or already-arbitrary code execution on the machine.
- The behavior of macOS system frameworks (ImageIO, AppKit) or the system `zlib` library themselves.
- Social-engineering, physical access, or supply-chain attacks against your own build toolchain.
- Cosmetic/UI issues with no security impact.

## Supported versions

Slimg is distributed from this repository. Security fixes are applied to the **latest release / `main`**. Older tagged releases are not separately patched; please update to the latest version.

| Version            | Supported          |
|--------------------|--------------------|
| Latest release / `main` | :white_check_mark: |
| Older releases     | :x:                |

## Reporting a vulnerability

**Please report security issues privately — do not open a public issue or PR for a suspected vulnerability.**

Preferred channel:

- **GitHub Security Advisories** — use the repository's **"Report a vulnerability"** button under the **Security** tab (Private Vulnerability Reporting). This keeps the report confidential until a fix is available.

Alternative channel:

- **Email:** `nicolas@aguara.com.ar` with subject line `Slimg security`. If you wish to encrypt, mention so and we will arrange a key.

Please include, as much as you can:

- A description of the issue and its impact (crash, OOB read, OOM/DoS, data loss, etc.).
- A minimal **proof-of-concept input** (e.g. the crafted image file) and exact steps to reproduce.
- The Slimg version / commit, macOS version, and CPU architecture.
- Whether the CLI (`slimg`), the GUI (Slimg.app), or both are affected.

> ⚠️ If you are sending a crafted "bomb" or malformed image as a PoC, please note that in the report and, where practical, share it as a link or password-protected archive rather than inline.

## Response expectations

This is a small open-source project maintained on a best-effort basis. Typical targets:

- **Acknowledgement:** within **5 business days**.
- **Initial assessment / triage:** within **10 business days**.
- **Fix or mitigation:** prioritized by severity; critical memory-safety or DoS issues are addressed as quickly as is practical.

We will keep you updated on progress and coordinate a disclosure timeline with you. With your permission, we are happy to credit you in the release notes / advisory once a fix ships.

## Safe harbor

We will not pursue or support legal action against anyone who, in good faith:

- Reports a vulnerability through the private channels above,
- Makes a genuine effort to avoid privacy violations, data destruction, and service disruption while researching,
- Only interacts with files and systems they own or have permission to test, and
- Gives us a reasonable opportunity to address the issue before public disclosure.

Activity conducted consistent with this policy is considered authorized, and we will work with you to understand and resolve the issue quickly. If in doubt about whether a specific test is acceptable, ask us first via the contact above.
