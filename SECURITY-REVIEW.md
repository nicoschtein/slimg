# Slimg — Security & Correctness Review

**Scope:** `Sources/SlimgCore/**`, `Sources/CZlib/**`, `Sources/slimg/main.swift`, `Sources/SlimgApp/OptimizerModel.swift`
**Date:** 2026-06-15
**Reviewer:** automated security pass (pre-public-release)
**Threat model in brief:** Slimg is a fully on-device tool with **no network access and no telemetry**. The only untrusted input is the **image file bytes** the user feeds it (JPEG/PNG/GIF), parsed by hand-rolled byte parsers and a C zlib shim. The realistic attacker is therefore a **crafted/malicious image file** aiming to crash the process, read out of bounds, or exhaust memory (DoS) — there is no remote attack surface and no secrets to exfiltrate.

---

## Executive summary

The hand-written JPEG/PNG/GIF parsers are, overall, **well defended**: each one performs explicit bounds checks before every multi-byte read, advances its cursor monotonically (so it cannot loop forever), and bails out (returns `nil`) on any structural surprise, in which case `Slimg.optimize` keeps the original bytes untouched. The "never grow / never change pixels" safety net in `Slimg.optimize` is correct, and the CRC32 recompute used when rebuilding PNG IDAT is a correct standard CRC-32/ISO-HDLC implementation.

The **one serious vulnerability** was a classic **zlib decompression bomb** in the C inflate shim: the output buffer doubled without any ceiling, so a few-hundred-KB PNG IDAT (or any crafted zlib stream) could inflate to many gigabytes and OOM/crash the process. This has been **fixed** with a hard 512 MiB output ceiling, overflow-safe size arithmetic, and `uInt`-windowed input/output handling so 32-bit zlib fields can never be truncated on large buffers. A regression test deflates 600 MiB of zeros into a small payload and asserts inflate **refuses** it without OOM.

All other findings are bounds-hardening, defense-in-depth, or product/UX notes. Several safe, behavior-preserving fixes were applied (atomic writes in the CLI, symlink/package skipping during recursive folder expansion). The remaining items are documented as recommendations.

**Most important takeaway for the repo owner:** the inflate decompression-bomb fix (F1). Before it, a single crafted PNG could OOM-crash both the CLI and the GUI; it is now bounded and the original file is preserved on overflow.

### Severity table

| ID  | Title                                                            | Severity | Status                |
|-----|-----------------------------------------------------------------|----------|-----------------------|
| F1  | Unbounded inflate output buffer (zlib decompression bomb / OOM) | **High** | **Fixed**             |
| F2  | `uInt` truncation of >4 GiB sizes in zlib shim casts            | Medium   | **Fixed**             |
| F3  | CLI overwrites original with a non-atomic write (corruption on crash) | Medium | **Fixed**           |
| F4  | Recursive folder expansion could write through embedded symlinks | Medium   | **Fixed** (safe default) |
| F5  | Backup write does not capture a user-edited "second original"   | Low      | Recommended / by-design |
| F6  | Backup `fileExists`→`write` TOCTOU window                        | Low      | Recommended           |
| F7  | Dead `length >= 0` guard in PNG parser (misleading, not a bug)   | Info     | Recommended           |
| F8  | GIF application-ID match accepts ID-size ≥ expected (prefix match) | Info   | Won't-fix (harmless)  |
| —   | JPEG / PNG / GIF parser bounds + termination                    | —        | Verified sound        |

---

## Findings

### F1 — Unbounded inflate output buffer (zlib decompression bomb) — **High** — **Fixed**

**Location:** `Sources/CZlib/shim.c`, `czlib_inflate` (original lines ~17–43).

**Description.** The inflate loop grew its output buffer with `ncap = cap * 2` every time it filled, with **no upper bound**. DEFLATE achieves ratios up to ~1032:1, so a tiny crafted zlib stream — e.g. a PNG `IDAT` chunk of a few hundred KB — could decompress to **many gigabytes**, exhausting memory and crashing the process (a denial-of-service). Slimg reaches this path automatically: `PNGOptimizer.optimize` concatenates all `IDAT` data and calls `Zlib.inflate` to re-deflate it whenever `recompress` is on (the default).

**Attack scenario.** A user opens (or batch-drops) a small, innocuous-looking `.png`. Its `IDAT` is a "zip bomb" zlib stream. `czlib_inflate` allocates and doubles until the machine runs out of memory; the CLI or GUI process is killed (or the whole machine thrashes). Because the file is small, nothing looks suspicious up front.

**Fix.** Introduced `CZLIB_INFLATE_MAX = 512 MiB` as a hard ceiling. When the output reaches the ceiling but the stream is not finished, inflate now **returns `NULL`** (failure) instead of growing further. Because Slimg only inflates in order to re-deflate, a failed inflate simply means the optimizer bails and `Slimg.optimize` keeps the original file — the **lossless guarantee is preserved**, and no real-world PNG's filtered scanlines come anywhere near 512 MiB for this tool's purpose. The initial `srcLen*4 + CHUNK` guess is now overflow-checked and clamped to the ceiling.

**Test.** `testZlibRejectsDecompressionBomb` deflates 600 MiB of zeros (a few hundred KB compressed) and asserts `Zlib.inflate` returns `nil` without OOM. `testZlibInflatesHighlyCompressibleStream` confirms a 4 MB all-zero payload still round-trips exactly (the cap does not break legitimate high-ratio streams under the ceiling).

---

### F2 — `uInt` truncation of large sizes in the zlib shim — **Medium** — **Fixed**

**Location:** `Sources/CZlib/shim.c`, both `czlib_inflate` and `czlib_deflate` (the `s.avail_in = (uInt)srcLen` and `s.avail_out = (uInt)cap` casts, original lines ~25–27, ~41, ~85–87, ~99–107).

**Description.** zlib's `avail_in`/`avail_out` are `uInt` (32-bit on every common platform), but `srcLen`/`cap` are `size_t` (64-bit). If a buffer exceeded 4 GiB, the cast `(uInt)` silently truncated the length. For inflate the truncation would mean only the low 32 bits of the input length were ever fed to zlib (data loss / mis-parse); for deflate the same on input and, separately, the output-grow path computed `avail_out` from a `size_t` difference cast to `uInt`. In normal Slimg flow inputs are well under 4 GiB, but this is a latent correctness/safety bug if the shim is reused or fed a very large stream.

**Fix.** Both functions now drive zlib in a loop that **re-clamps `avail_in`/`avail_out` to a `<= UINT_MAX` window each iteration** and tracks absolute `inPos`/`produced` offsets in `size_t`, so no 64-bit size is ever truncated into a 32-bit field. The deflate loop also only switches to `Z_FINISH` once all input has actually been handed to zlib, avoiding a premature `Z_STREAM_END`.

**Test.** Covered indirectly by the existing/`testZlibRoundTrip`, the new `testZlibInflatesHighlyCompressibleStream` (multi-MB), and `testZlibInflateTruncatedStreamFailsCleanly`. (A true >4 GiB allocation is impractical to assert in CI.)

---

### F3 — CLI overwrites the original with a non-atomic write — **Medium** — **Fixed**

**Location:** `Sources/slimg/main.swift` (original lines ~133–139).

**Description.** The CLI wrote both the backup and the optimized output with plain `Data.write(to:)` (no `.atomic`). A crash, power loss, or full disk **mid-write to the original file** could leave a truncated/corrupted image. Combined with the backup write also being non-atomic, a worst-case interruption could destroy the only copy of the user's data. (`OptimizerModel.swift` already used `.atomic` — the CLI was inconsistent.)

**Fix.** Both writes in the CLI now use `options: .atomic`, matching the GUI. An interrupted write leaves the original intact; the new content only replaces it once fully written.

**Verification.** End-to-end CLI run (create PNG → `--backup` → re-run → run on a `.bak` file) confirms correct, lossless backup/overwrite behavior with no clobbering and atomic semantics.

---

### F4 — Recursive folder expansion could write through embedded symlinks — **Medium** — **Fixed (conservative default)**

**Location:** `Sources/SlimgApp/OptimizerModel.swift`, `expand(_:)` (original lines ~70–79).

**Description.** When a user drops a **folder**, `FileManager.enumerator(at:)` walks it. `enumerator(at:)` does *not* descend into symlinked **directories**, but a symlinked **file** with a supported extension (e.g. `evil.png -> /Users/you/Documents/important.png`) would be returned, then optimized **in place** — i.e. Slimg would write through the symlink and replace the *target's* contents (and, if backups are on, create a `.bak` next to the symlink, not next to the real target). This lets a crafted folder cause writes to files outside the dropped tree.

**Fix (chosen safe default).** Recursive expansion now uses `options: [.skipsHiddenFiles, .skipsPackageDescendants]` and **skips any item that is a symbolic link** (`isSymbolicLinkKey`). This prevents a symlink embedded in a dropped folder from ever being followed. A symlink the user *explicitly* selects in the open panel is still honored (it goes through the non-directory branch), preserving intentional UX while closing the surprise-write vector. This matches the project's conservative posture.

**Note.** This only affects the GUI's folder expansion. The CLI processes exactly the paths it is given and does not recurse, so it is unaffected.

---

### F5 — Backup does not capture a user-edited "second original" — **Low** — **Recommended / by-design**

**Location:** `Sources/slimg/main.swift` `backupURL`/backup logic; `Sources/SlimgApp/OptimizerModel.swift` `run(...)`.

**Description.** Backup logic intentionally **never clobbers an existing `name.bak.ext`** (to protect the true original across re-runs — verified correct). A side effect: if a user runs `--backup` (creating the backup), then *replaces* the working file with a new version and runs again, the new run optimizes the new file in place but **skips** the backup write because the backup already exists. The `.bak` therefore still holds the *first* original, not the just-overwritten second version. No data the tool itself produced is lost, but a user could lose an intermediate edit they assumed was being backed up.

**Recommendation.** This is a reasonable default; document it in the README/CLI help ("`--backup` preserves the *first* seen original and will not overwrite an existing backup"). If stronger guarantees are desired, consider a timestamped/numbered backup scheme (`name.bak.N.ext`) — a product decision, not forced here.

---

### F6 — Backup `fileExists` → `write` TOCTOU window — **Low** — **Recommended**

**Location:** `Sources/slimg/main.swift` (~131–135) and `Sources/SlimgApp/OptimizerModel.swift` (~125–128).

**Description.** Backups use `if !FileManager.default.fileExists(atPath: bak.path) { try data.write(to: bak) }`. Between the existence check and the write, another process could create the backup; the subsequent `.write(to:)` would then overwrite it. The exposure is minimal for a desktop tool operating on user-owned files, and the failure mode is "backup overwritten" rather than memory corruption.

**Recommendation.** If hardening is desired, write the backup with `O_CREAT | O_EXCL` semantics (e.g. `Data.write(to:options:)` does not offer exclusive-create; a low-level `open(..., O_EXCL)` or `FileManager.createFile` with a pre-check loop would). Low priority given the threat model. Not changed to avoid altering behavior for a marginal gain.

---

### F7 — Dead `length >= 0` guard in PNG parser — **Info** — **Recommended**

**Location:** `Sources/SlimgCore/PNGOptimizer.swift:27`.

**Description.** `let length = (Int(data[i]) << 24) | ...` builds a non-negative value from four bytes (max 4,294,967,295), so on 64-bit `Int` `guard length >= 0` is **always true** — it reads as a bounds check but is dead code. The actual protection is `guard crcEnd <= n`, which is correct. PNG mandates chunk length ≤ 2^31−1; the code does not enforce that specific cap but does not need to for safety (the `crcEnd <= n` check rejects anything that doesn't fit the file).

**Recommendation.** Replace the misleading guard with an explicit spec cap for clarity, e.g. `guard length <= 0x7FFF_FFFF else { return nil }`, or drop it and rely on the existing bounds check. Cosmetic; no behavior change required. Left as-is to avoid touching otherwise-correct parsing.

---

### F8 — GIF application-ID match is a prefix match — **Info** — **Won't-fix (harmless)**

**Location:** `Sources/SlimgCore/GIFOptimizer.swift:117–126`, `isApplicationID`.

**Description.** The check uses `idSize >= idBytes.count` (rather than `==`) and compares only the first `idBytes.count` bytes, so an application block whose ID merely *starts with* `NETSCAPE` or `XMP Data` would match. In practice GIF application IDs are a fixed 11 bytes and the worst case is mis-labeling a removed block in the report or keeping a non-looping `NETSCAPE…`-prefixed block. No memory-safety impact (all reads are bounds-checked) and no losslessness impact (kept blocks are copied verbatim, dropped blocks are genuine metadata).

**Status.** Won't-fix; harmless. Could tighten to an exact-length match if desired.

---

## Verified-sound areas (no action needed)

- **`Slimg.optimize` safety net** (`Slimg.swift:127`): only adopts optimizer output when `output.bytes.count < bytes.count`, else returns the original bytes and an empty report. The "never grow" invariant holds even if an optimizer emitted something malformed-but-smaller, because the optimizers only ever **copy verbatim or drop** segments/chunks (JPEG/GIF) — they never rewrite pixel/scan data. PNG re-deflate is guarded by an inflate→deflate round-trip and only adopted when smaller; the filtered scanlines are unchanged, so decoded pixels are identical. Existing pixel-equality tests confirm this.
- **JPEG parser** (`JPEGOptimizer.swift`): every multi-byte read is preceded by a bounds guard (`j < n`, `j + 2 < n`, `segEnd <= n`); `len >= 2` prevents an inverted `payloadStart..<segEnd` range; the cursor `i` strictly increases each iteration (standalone markers `i = j+1`, segments `i = segEnd > i`), so the loop always terminates; SOS copies to EOF verbatim (the losslessness anchor). `classify`/`startsWith`/`isICCProfile` all check `end - start >= prefix.count` before indexing.
- **PNG parser** (`PNGOptimizer.swift`): chunk walk guards `i + 8 <= n`, `typeStart + 4 <= n`, and `crcEnd <= n` before any access; non-ASCII chunk types cause a clean bail. `textKeyword` is bounded by the chunk's own range and an 79-byte keyword cap. CRC32 table/algorithm is the correct standard polynomial `0xEDB88320`.
- **GIF parser** (`GIFOptimizer.swift`): header/LSD guarded by `n > 13`; color-table sizes checked with `i + size <= n`; `skipSubBlocks` guards `i < n` per byte and rejects `i > n`; image-descriptor/extension branches each advance the cursor, guaranteeing termination; unrecognized blocks bail out (`return nil`).
- **`detectFormat`** (`Slimg.swift:98`): reads only from `data.prefix(8)` with explicit `b.count >=` guards, safe on short inputs.

## Testing added

All in `Tests/SlimgCoreTests/SlimgCoreTests.swift`:

- `testZlibRejectsDecompressionBomb` — F1 regression: a small payload that inflates past 512 MiB is rejected (no OOM).
- `testZlibInflatesHighlyCompressibleStream` — confirms high-ratio streams under the cap still round-trip exactly.
- `testZlibInflateGarbageFailsCleanly` — empty/garbage/valid-header-then-junk inflate inputs return `nil`, no crash.
- `testZlibInflateTruncatedStreamFailsCleanly` — truncated valid stream rejected.
- `testOptimizeRandomGarbageNeverCrashes` — random bytes of every length 0–299 behind each format magic; never crashes, never grows, preserves unchanged content.
- `testOptimizeTruncatedValidImagesNeverCrash` — every truncation of real JPEG/PNG/GIF samples is handled safely.
- `testPNGOversizedChunkLengthBailsOut`, `testJPEGOversizedSegmentLengthBailsOut`, `testGIFOversizedColorTableBailsOut` — declared-length-exceeds-file inputs bail out and preserve the original.

CLI backup/no-clobber/atomic behavior (F3, F5) was verified end-to-end against the built `slimg` binary in a temp directory.
