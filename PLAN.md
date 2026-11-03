# Reclaim — Engineering Specification & Development Plan

**Product:** Reclaim — native macOS Storage Management & Cleaning application
**Document version:** 1.0.0 (authoritative build spec)
**Date:** 2026-11-02
**Authors:** Principal macOS Systems Architect / Lead Swift Engineer (this thread)
**Status:** Approved for Phase 0 start. No application code exists yet; this document is the single source of truth.

> Reading rule: every section is normative unless marked *Informative*. "MUST / MUST NOT / SHOULD" follow RFC 2119. Identifiers in `monospace` are literal names that MUST be used in code (types, rule IDs, file names, bundle IDs).

---

## Table of Contents

0. [Executive Summary, Goals, Non-Goals, Glossary](#0-executive-summary)
1. [STEP 1 — Forensic Audit of the Cleanup Sessions](#1-step-1--forensic-audit-of-the-cleanup-sessions)
2. [STEP 2 — System Architecture & Technical Stack](#2-step-2--system-architecture--technical-stack)
3. [STEP 3 — Cleaning Rules Engine](#3-step-3--cleaning-rules-engine)
4. [STEP 4 — Safety & Non-Destructive Guardrails](#4-step-4--safety--non-destructive-guardrails)
5. [STEP 5 — UI/UX & Visualization](#5-step-5--uiux--visualization-design)
6. [STEP 6 — Phased Implementation Roadmap](#6-step-6--phased-implementation-roadmap)
7. [Appendices](#7-appendices)

---

## 0. Executive Summary

### 0.1 Why this product exists (Informative)

Over five sessions (2026-03-24 → 2026-10-30) a single 494 GB Mac repeatedly hit 0–3% free space. Manual forensics with `du`, `find`, `xcrun simctl`, `docker`, `tmutil`, `avdmanager` and `rm` recovered roughly **290 GB cumulatively**, but every pass took 20–60 minutes of shell work, `du` runs took 1–5 minutes each, and we hit the same ten classes of edge cases every time (sparse files misreported, zsh glob failures, EPERM/TCC walls, `df` vs purgeable discrepancies, mounted simulator volumes, running apps holding files). The same hogs regrew within 5 weeks: WhatsApp group/status media (up to 79 GB), Docker's sparse `Docker.raw` (20 GB allocated while empty), Electron app state (Cursor/Claude 10–12 GB each), Xcode device support (9.7 GB), Rust `target/` (20 GB), Android AVDs (25 GB), Telegram media (13 GB), an abandoned user home in `/Users/Deleted Users` (31 GB).

Reclaim productizes exactly that workflow: a **sub-10-second whole-disk scan**, an **explainable rules engine** that turns each manual discovery into a tested module, **non-destructive by default** deletion with a rollback ledger, and a **menu bar monitor** that catches regrowth before the disk is full.

### 0.2 Goals (Normative)

| ID | Goal | Measurable target |
|----|------|-------------------|
| G1 | Fast full scan | ≤ 10 s cold / ≤ 6 s warm for 2,000,000 entries on the author's M3 Pro (stretch 3 s); ≤ 15 s on the macos-15 CI runner. Peak RSS ≤ 300 MB for that fixture. Benchmarked in Phase 0–1; validated on the author's machine (~3–5 M entries, ≤ 25 s cold). See ADR-016. |
| G2 | Honest accounting | Reported "reclaimable" bytes = bytes actually returned by `statfs` after deletion, within ±2% for non-cloned data; sparse/clone/purgeable/hard-link cases never overstate savings. |
| G3 | Zero data-loss incidents | Protected-path blocklist, O_NOFOLLOW traversal, identity (dev/inode) re-verification, Trash-first tier, full rollback ledger. |
| G4 | Explainability | Every finding carries a human rationale and a regeneration statement ("recreated on next build"). |
| G5 | Replace the manual playbook | Every path, command and artifact in §1 maps to a rule module or a UI feature (traceability matrix §1.7). |
| G6 | Low footprint | Idle menu bar monitor ≤ 30 MB RSS, ≤ 0.1% CPU; full scan ≤ 400 MB RSS for 3 M entries. |

### 0.3 Non-Goals (v1)

- No App Store distribution (Full Disk Access + privileged helper are incompatible with the App Sandbox). Developer ID + notarization only.
- No cloud/telemetry. All data stays local.
- No "RAM cleaner", "startup optimizer", malware scanning, or uninstaller UI beyond orphan detection.
- No modification of APFS snapshots other than Time Machine local snapshots via `tmutil` (private `fs_snapshot_*` entitlements are unavailable).
- No Windows/Linux.

### 0.4 Glossary

| Term | Meaning |
|------|---------|
| **Logical size** | Byte length of file data (`st_size`, `ATTR_FILE_TOTALSIZE`, `NSURLFileSizeKey`). What `ls -l` shows. |
| **Allocated size** | Blocks actually reserved on disk (`st_blocks*512`, `ATTR_FILE_ALLOCSIZE`, `NSURLTotalFileAllocatedSizeKey`). What `du` shows. |
| **Private size** | Allocated bytes **not shared** with any other file via APFS clone (`ATTR_CMNEXT_PRIVATESIZE`). The only number that predicts freed space when one file is deleted. |
| **Sparse file** | Logical ≫ allocated (e.g. `Docker.raw`: 60 GB logical / 1.3–20 GB allocated). |
| **Clone** | APFS copy-on-write duplicate sharing blocks (`cp -c`, Finder duplicate). Deleting one frees only its private bytes. |
| **Firmlink** | Transparent cross-volume link from the sealed System volume into `/System/Volumes/Data` (e.g. `/Users` → `/System/Volumes/Data/Users`). Listed in `/usr/share/firmlinks`. |
| **Purgeable** | Space macOS can reclaim automatically (local TM snapshots, evictable iCloud files, flagged caches). Shown by Finder as part of "available"; never counted as savings by Reclaim. |
| **TCC / FDA** | Transparency, Consent & Control; Full Disk Access is the TCC service `kTCCServiceSystemPolicyAllFiles`. Denied access returns `EPERM`, not `EACCES`. |
| **SIP** | System Integrity Protection; paths flagged `SF_RESTRICTED` are immutable even to root. |
| **JID** | WhatsApp chat identifier (`<id>@g.us` group, `<id>@lid` / `<phone>@s.whatsapp.net` 1:1, `<id>@lid.status` / `<phone>@status` status caches). |
| **Finding** | A rule's concrete, sized, explained set of deletable items. |
| **Plan** | A user-approved set of findings plus a deletion tier. |
| **Tier** | `dryRun`, `trash` (default, undoable), `permanent` (requires confirmation + open-file pre-flight). |

---

## 1. STEP 1 — Forensic Audit of the Cleanup Sessions

This section is the complete inventory of what was inspected, run, deleted, and what went wrong in this thread. Every row feeds §1.7 (traceability) and §3 (rules).

### 1.1 Session timeline

| # | Date | Free before → after | Work performed |
|---|------|---------------------|----------------|
| S1 | 2026-03-24 | 3.0 GB (491.34/494.38 GB used) | Baseline only. Storage Settings reported: Applications 72.35 GB, Documents 112.7 GB, Developer 6.72 GB, Bin 673.6 MB, iCloud Drive 108.6 MB, Mail 14.9 MB, Messages 86.6 MB, **System Data 220.61 GB**. Produced a manual playbook. |
| S2 | 2026-05-01 | ~3 GB → **70 GB** | Scanned `~/Library/*`. Deleted 13 cache folders (7.5 → 3.3 GB). Inspected Docker (0 images, 19 named volumes = 807 MB; `Docker.raw` 60 GB logical / 1.3 GB allocated). WhatsApp `Message/Media` 81 GB → 17 GB by deleting 3 group JIDs (−63.4 GB). Telegram `postbox/media` 2.7 GB deleted. |
| S3 | 2026-07-27 | 7.4 GB → **46.7 GB** | WhatsApp 37 → 1.8 GB (2 groups + 130 `*.lid.status` folders). Removed iOS 26.0 simulator runtime via `xcrun simctl runtime delete 23A343` (−19 GB). Deleted 31 `node_modules` older than 90 days (−11 GB). Discovered `/Library/Developer/CoreSimulator` = 67 GB, `~/work` = 40 GB, `/usr/local` = 9.9 GB, Cryptex bundle mounted as a volume. |
| S4 | 2026-09-03 | **383 MB** → **89.4 GB** | WhatsApp 79 → 1.8 GB (30 GB group + 196 status folders incl. a single 24 GB status contact). Xcode `iOS DeviceSupport` 9.7 GB + `DerivedData` 628 MB. Safe caches ~10 GB. Claude `vm_bundles/claudevm.bundle` 9 GB. `Docker.raw` 20 GB allocated (Docker stopped). Movies: duplicate zip + extracted season (5 GB). Cursor `state.vscdb.backup` 1 GB. Wrote `~/bin/quickclean.sh` (prototype; see §1.6). |
| S5 | 2026-10-30 | 15.2 GB → **88.9 GB** | Whole-disk accounting (412 GB used: user 247 GB, `/Users/Deleted Users` 31 GB, `/Applications` 38 GB, system/dev ~21 GB). Removed deleted-user home (−31 GB, 61 MB residual EPERM), both Android AVDs via `avdmanager delete avd` (−25 GB), Telegram media (−13 GB). Identified Rust `target/` 20 GB, `qt-6.8` 4.8 GB, `~/.gradle` 5 GB, Cursor `state.vscdb` 5.7 GB, Claude VM 11 GB. |

Cumulative recovered ≈ 70 + 65 + 89 + 69 ≈ **293 GB**; the same categories regrew each time (see regrowth column in §1.2).

### 1.2 Inventory A — Every path inspected or cleaned

Legend — **Action**: I = inspected only, D = deleted/cleaned, T = tool-driven removal, R = report/recommend only, H = needed root/helper. **Regrowth**: observed re-accumulation between sessions.

#### 1.2.1 Volume and system-level paths

| Path | Observed size(s) | Action | Notes / regrowth |
|------|------------------|--------|------------------|
| `/` (`/dev/disk3s1s1`, sealed System snapshot volume) | Used 16 GiB | I | `df -h /` reports the System volume, **not** user data; "Avail" equals container free. |
| `/System/Volumes/Data` (`/dev/disk3s5`) | Used 338–420 GiB | I | The real data volume. All home paths resolve here via firmlinks. |
| `/System/Volumes/Preboot`, `/System/Volumes/VM`, `/System/Volumes/Update/mnt1`, Recovery | — | I | Enumerated via `diskutil apfs list`; never scanned for deletion. |
| `/private/var/vm` | 2.0 GB | I | Swap files. MUST never be touched. |
| `/private/var/folders` (= `/System/Volumes/Data/private/var/folders`) | 3.5 → 2.0 GB | I | Per-user `TMPDIR`/`DARWIN_USER_CACHE_DIR`. Same inode tree reachable via two paths → double-count risk. |
| `/private/var/log` (`asl/*.asl`) | — | R/H | Root-owned logs; recommended `sudo rm` only. |
| `/private/var/db` | — | I | Partially SIP-protected; excluded. |
| `/Library/Caches`, `/Library/Updates` | — | R/H | System-level caches; need root. |
| `/Library/Developer` | 8.3 GB | I | Parent of CoreSimulator. |
| `/Library/Developer/CoreSimulator` | 67 → 48 → 6.3 GB | T | Runtime disk images; shrank after `simctl runtime delete` and Xcode's own housekeeping. |
| `/Library/Developer/CoreSimulator/Volumes/iOS_22D8075` | 18 GB | I | iOS 18.3.1 runtime, **mounted APFS volume** (`disk9s1`). |
| `/Library/Developer/CoreSimulator/Volumes/iOS_23A343` | 15 GB | T | iOS 26.0 runtime; removed via `xcrun simctl runtime delete 23A343`. |
| `/Library/Developer/CoreSimulator/Volumes/iOS_23D8133` | 16 GB | I | iOS 26.3.1 runtime (kept). |
| `/Library/Developer/CoreSimulator/Cryptex/Images/bundle/SimRuntimeBundle-EB892DEF-…` | 8.1 GB | I | **Mounted** as "iOS 18.3.1 Simulator Bundle" (`disk7s1`). Must never be `rm`'d. |
| `/Library/Developer/CoreSimulator/Cryptex/Images/bundle/SimRuntimeBundle-04A9D688-…` and `…_1` | 0 B each | H | Empty root-owned leftovers; `sudo -n rm` failed (no TTY). |
| `/Applications` | 38 GB total | I | Top: Xcode 5.0, IntelliJ IDEA 4.6, Android Studio 2.5, Docker 2.1, TikTok LIVE Studio 1.5, Chrome 1.4, Maestro Studio 1.2, Citrix 1.0, Cursor 0.98, VS Code 0.91, GIMP 0.89, Lens 0.89, Favorited Studio 0.77, Ollama 0.70, Claude 0.62 GB. |
| `/usr/local` | 9.9 GB | R | Intel-Homebrew-era remnants (`/usr/local/opt/php@8.2`, `php@7.1` on PATH). Needs verification before removal. |
| `/opt/homebrew` | 1.5 GB | I | Current Homebrew prefix. |
| `/opt/local` | 1.1 GB | I | MacPorts prefix. |
| `/Users/Deleted Users/olawaleilesanmi` | 31 GB (`Library` 24, `Downloads` 2.5, `works` 1.2, `.rvm`, `Pictures` 101 MB) | D/H | Dir `root:admin 0770`; user-owned contents mostly deletable; 61 MB residual with `EACCES`/`EPERM` (`Library/Mobile Documents` → TCC). |
| `/Users/Shared` | 11 MB | I | — |
| `~/.Trash` | 673.6 MB (S1) | D | Emptied in prototype script. |
| Time Machine local snapshots | 3 × `com.apple.os.update-*` | I | OS-update snapshots; listed with `tmutil listlocalsnapshots /`; never deleted (require root, OS-managed). |

#### 1.2.2 `~/Library` paths

| Path | Observed size(s) | Action | Notes / regrowth |
|------|------------------|--------|------------------|
| `~/Library/Caches` | 9.9 → 7.5 → 3.3 → 15 → 16 → 4.0 GB | D | Full subfolder list in §1.2.3. Regrows ~10 GB / 2 months. |
| `~/Library/Application Support` | 27 → 44 → 49 → 54 GB | I/D | Subfolders in §1.2.4. Steady growth driven by Cursor, Claude, Google. |
| `~/Library/Containers` | 20 → 24 → 13 GB | I/D | Dominated by `com.docker.docker` (see below). |
| `~/Library/Containers/com.docker.docker` | 35 → 1.3 → 16 → 20 → 8.7 GB | D | `Data/vms/0/data/Docker.raw` is the whole story; `Data/log` 96 MB. |
| `~/Library/Containers/maccatalyst.com.frontrow.vlog` | 1.0 GB | I | Catalyst app data. |
| `~/Library/Containers/com.apple.CoreDevice.CoreDeviceService` | 519–539 MB | I | Device pairing/data; system-managed. |
| `~/Library/Containers/com.microsoft.teams2` | 495 MB | I | — |
| `~/Library/Containers/com.apple.wallpaper.agent` | 205–521 MB | I | System. |
| `~/Library/Containers/C7AD55A5-7724-4EA9-8486-77B71E0DDB23` | 367 MB | I | Unidentified UUID container (orphan candidate). |
| `~/Library/Containers/com.atlassian.trello`, `com.apple.geod`, `com.gameloft.asphalt8`, `com.apple.mediaanalysisd`, `net.whatsapp.WhatsApp` | 318 / 260–350 / 152 / 94–443 / 32–98 MB | I | — |
| `~/Library/Group Containers` | 47 → 79 → 37 → 19 GB | D | WhatsApp + Telegram. |
| `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared` | 47 → 81 → 17 → 37 → 1.8 → 79 → 1.8 → 5.7 GB | D | **Fastest regrowth on the machine** (≈ 15 GB/week peak). Media only; DB files kept. |
| `…/WhatsApp.shared/Message/Media/<JID>` | see §1.2.5 | D | Deleted selected JIDs and all `*.lid.status`. |
| `…/WhatsApp.shared/ChatStorage.sqlite` (+`-wal`) | 492 → 227 MB | I | Chat DB — protected. Holds JID→name mapping (`ZWACHATSESSION`). |
| `…/WhatsApp.shared/{LocalKeyValue,BackedUpKeyValue,Axolotl,LID,ContactsV2,Sticker,emoji}.sqlite*`, `fts`, `Library`, `Logs`, `stickers`, `Media`, `ExtChatDB`, `Biz`, `channels-fts`, `AppState` | 4–181 MB each | I | Protected (state/keys/index). |
| `~/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram` | 2.8 GB → 84 MB → 13 GB → 87 MB | D | Only `appstore/account-<id>/postbox/media` deleted; `postbox/db` (34 MB), `Wallpapers`, `logs`, `accounts-metadata` kept. |
| `~/Library/Group Containers/EQHXZ8M8AV.group.com.google.drivefs` et al. | ≤ 56 MB | I | — |
| `~/Library/Developer` | 7 → 9.7 → 16 → 6.5 GB | D | Xcode + CoreSimulator user data. |
| `~/Library/Developer/Xcode/DerivedData` | 61 MB → 628 MB | D | Safe; rebuilt on next build. |
| `~/Library/Developer/Xcode/iOS DeviceSupport` | 4.4 → 9.7 GB | D | Safe; re-downloaded from device on next connect. |
| `~/Library/Developer/Xcode/Archives` | 16 KB | D | Normally contains dSYMs needed for crash symbolication → medium risk in product. |
| `~/Library/Developer/CoreSimulator` | 1.9 → 4.5 GB | I | Per-device data (`Devices/<UDID>/data`). |
| `~/Library/Logs` | 858 MB → 1.0 GB | I | Includes `DiagnosticReports`. |
| `~/Library/Application Support/MobileSync/Backup` | absent | I | iOS backups location (none present). |
| `~/Library/CloudStorage`, `~/Library/Mobile Documents` | 12 KB / — | I | iCloud; protected. |
| `~/Library/Android/sdk` | (ANDROID_HOME) | I | SDK root; `system-images` are the big part. |

#### 1.2.3 `~/Library/Caches/*` observed (union of all sessions)

| Folder | Size(s) | Action | Classification |
|--------|---------|--------|----------------|
| `Google` | 4.7 / 3.0 / 4.1 GB → 74 MB | D | Chrome cache (`Chrome/Default/Cache`, `Code Cache`). |
| `Yarn` | 4.5 GB | D | Yarn v1 global cache. |
| `aws` | 1.1 GB / 781 MB | D | AWS CLI v2 cache. |
| `BraveSoftware` | 735 MB | D | Browser cache. |
| `com.spotify.client` | 708–975 MB | D | Streaming cache (offline songs re-download). |
| `Firefox` / `Mozilla` | 513/330/269 MB / 619/505 MB | D | Browser caches (`cache2`). |
| `lens-desktop-updater` | 412–468 MB | D | Updater staging. |
| `com.postmanlabs.mac.ShipIt`, `com.postmanlabs.agent.mac.ShipIt` | 307 / 309 MB | D | Squirrel.Mac staged updates. |
| `com.todesktop.230313mzl4w4u92.ShipIt` | 758 MB – 1.7 GB | D | **Cursor** updater staging (ToDesktop bundle ID). |
| `com.anthropic.claudefordesktop.ShipIt` | 695 MB | D | Claude Desktop updater staging. |
| `com.electron.kontena-lens.ShipIt` | 758 MB | D | Lens updater staging. |
| `com.hnc.Discord.ShipIt` | 445 MB | D | Discord updater staging. |
| `com.figma.Desktop.ShipIt` | 300 MB | D | Figma updater staging. |
| `com.google.antigravity.ShipIt` / `com.google.antigravity` | 464 / 348 MB | I | New in S5. |
| `com.obsproject.obs-studio` | 644 MB | D (partial) | Sparkle `org.sparkle-project.Sparkle/Installation/…/OBS.app` → **EACCES** on nested files (EC-05). |
| `ms-playwright` | 520 MB | D | Playwright browser binaries. |
| `composer` | 226 / 96 MB | D | PHP Composer cache. |
| `electron`, `node-gyp`, `typescript`, `hardhat-nodejs`, `go-build`, `pip` | 108 / 107 / 31–46 / 38 / 55 / 80 MB | D | Build-tool caches. |
| `Homebrew` | 63–144 MB | T | `brew cleanup --prune=all`. |
| `com.epicgames.EpicGamesLauncher` | 96 MB | D | — |
| `SiriTTS`, `GeoServices`, `com.apple.helpd`, `com.apple.e5rt.e5bundlecache` | 223 / 88–96 / 22–28 / 28 MB | I | Apple system caches — leave alone (regenerate at cost). |
| `dotslash`, `com.googlecode.iterm2`, `gift-studio`, `com.westbridge.stremio5-mac`, `mango-live-studio`, `com.mangoentertainment.livestudio`, `Sublime Merge` | 363 / 255 / 162 / 136 / 120 / 61 / 21 MB | I | App caches (generic rule). |

#### 1.2.4 `~/Library/Application Support/*` observed

| Folder | Size(s) | Sub-structure findings |
|--------|---------|------------------------|
| `Google` | 9.9 GB (stable) | Chrome profiles; only `*/Cache`, `*/Code Cache`, `*/GPUCache`, `*/Service Worker/CacheStorage` are deletable; `Login Data`, `Cookies`, `History`, `Bookmarks` protected. |
| `Cursor` | 5.8 → 8.8 → 10 → 11 GB | `User/globalStorage/state.vscdb` 4.0 → 5.7 GB (live SQLite, protected), `state.vscdb.backup` 1.0 GB (deleted), `anysphere.cursor-agent-worker` 534 MB, `User/workspaceStorage` 3.1 GB / **191 workspaces** (orphans likely), `User/History` 100 MB, `WebStorage` 596–794 MB, `Partitions` 181–190 MB, `logs` 149–183 MB, `Cache` 120 MB, `CachedData` 115–142 MB, `CachedExtensionVSIXs` 102–139 MB. |
| `Claude` | 533 MB → 7.1 → 10 → 12 GB | `vm_bundles/claudevm.bundle` 9 → 11 GB (deleted; recreated on next sandboxed code run), `vm_bundles/warm` 0 B, `claude-code-vm` 280–317 MB, `Cache` 314–637 MB, `Code Cache` 173–264 MB, `claude-code` 190–525 MB, `Partitions` 156 MB. |
| `Code` (VS Code) | 3.5–3.8 GB | Same layout as Cursor. |
| `MySQL` | 3.0 GB | Local databases — protected unless user opts in. |
| `discord` | 1.1–1.7 GB | Electron caches inside. |
| `Postman`, `Insomnia` | 1.3 GB / 680 MB | — |
| `TikTok LIVE Studio` | 1.0–1.4 GB | — |
| `Arc` | 1.2 GB | Browser; profile protected, caches deletable. |
| `Lens`, `Figma`, `Slack`, `Caches`, `com.apple.wallpaper`, `stremio-server`, `app_shell_cache_8311`, `dev.warp.Warp-Stable`, `Asana`, `zoom.us` | 0.3–1.0 GB each | Generic Electron/app caches. |

#### 1.2.5 WhatsApp `Message/Media/<JID>` observed

| JID | Sizes over time | Kind |
|-----|-----------------|------|
| `120363076093068126@g.us` | 52 → 30 (S3: 28) → 30 GB → 314 MB | Group — regrew ~30 GB in 5 weeks, twice. |
| `120363041027416563@g.us` | 9.5 → 7.5 → 1.5 → 1.4 GB | Group. |
| `120363152827291130@g.us` | 3.9 GB | Group. |
| `245861544149209@lid.status` | 24 GB | Status cache of one contact. |
| `232516762001527@lid.status` | 218 MB → 11 GB | Status cache. |
| `249675089236129@lid.status` | 74 MB → 6.0 GB | Status cache. |
| `24713359278286@lid.status` | 2.5 GB | Status cache. |
| `146789265051732@lid.status`, `146737725489221@lid.status`, `146063281385582@lid.status`, … | 1.0 GB, 715, 540, 459, 440, 416, 307, 289, 271, 257, 254 MB … | 130 (S3) → 196 (S4) status folders; long-tail: most 4–128 KB, a few GB-scale. |
| `245616714186934@lid`, `178159739736119@lid`, `132195201110025@lid`, `74105499955217@lid`, `133560816156858@lid`, `98058515808322@lid` … | 1.3 GB … 100 MB | 1:1 chats (LID-addressed). |
| `2348148500996@s.whatsapp.net`, `2349110209579@s.whatsapp.net` | 184 / 143 MB | 1:1 chats (phone-addressed). |
| `2348159505409@status`, `2347036227972@status`, `2347032922178@status` | 171 / 150 / 74 MB | Status caches (phone-addressed). |
| `120363421937967335@g.us`, `120363045471664534@g.us`, `120363185148323644@g.us`, `120363400071204799@g.us`, `120363406848072688@g.us`, `120363421610226631@g.us`, `120363424777002481@g.us` | 100–400 MB | Smaller groups. |

#### 1.2.6 Home directory paths

| Path | Size(s) | Action | Notes |
|------|---------|--------|-------|
| `~/work` | 40 → 35 → 61 GB | I/D | `mango-entertainment` 15 → 41 GB (see next row). |
| `~/work/mango-entertainment/mango-live-studio/desktop-app/target` | 20 GB | R | Rust/Tauri build output (`Cargo.lock`, `src-tauri` present). |
| `~/work/mango-entertainment/mango-obs-plugin/qt-6.8` | 4.8 GB | R | Vendored Qt SDK. |
| `~/work/mango-entertainment/mobile-app/{android,ios}` | 3.3 / 1.6 GB | R | Native build dirs. |
| `~/work/mango-entertainment/expo-mobile-app/node_modules` | 1.4 GB | I | Active. |
| `~/work/mango-entertainment/mango-backend/vendor` | 575 MB | I | Composer vendor. |
| `~/work/mango-entertainment/mango-gifts/{mango-gifts-desktop,Safari Lion,samurai_export}` | 2.3 GB / 373 / 294 MB | I | Assets. |
| `~/work/**/node_modules` (31 dirs S3, 2 dirs S4) | 4–1,600 MB each | D | Stale > 90 days by parent mtime. |
| `~/work/**/.next/standalone/node_modules`, `~/work/**/.claude/skills/gstack/node_modules` | 60 / 22–73 MB | D | Nested build/tooling copies. |
| `~/projects` | 10 → 6.8 → 7.5 GB | D | 15 `node_modules`, incl. `nativephp/explore-native/vendor/nativephp/electron/resources/js/node_modules` 688 MB. |
| `~/Downloads` | 4.7 → 2.9 → 7.8 GB | R | Never cleaned automatically. |
| `~/Documents` | 1.1 GB → 8 KB | I | (Storage Settings "Documents 112.7 GB" in S1 is a category, not this folder.) |
| `~/Movies` | 109 MB → 10 GB → 91 MB | D | `S01/` 5.0 GB + `Boston.Legal.S01….zip` 5.0 GB duplicate; zip deleted. |
| `~/Pictures`, `~/Music` | 5.9–74 MB / 9.3 MB | I | — |
| `~/sdk`, `~/flutter` | 3.9 / 3.9 GB | I | Android SDK copy, Flutter SDK (`~/sdk/flutter/bin` on PATH). |
| `~/pikvm-share.img` | 1.9 GB | R | Disk image. |
| `~/From Old PC`, `~/isds`, `~/Sites`, `~/apps`, `~/dumps` | 641 / 456 / 364 / 52 / 29 MB | I | — |
| `~/.android/avd/Medium_Phone_API_35.avd` | 20 GB (10 GB sdcard) | T | `avdmanager delete avd -n Medium_Phone_API_35`. |
| `~/.android/avd/Pixel_8_Pro_API_35.avd` | 4.6 GB | T | `avdmanager delete avd -n Pixel_8_Pro_API_35`. |
| `~/.gradle` | 5.0 GB | R | `caches/`, `wrapper/dists/`. |
| `~/.npm` | 2.3 → 1.8 GB | T | `npm cache clean --force`. |
| `~/.local`, `~/.docker`, `~/.cache`, `~/.composer` | 1.1 GB / 427–431 MB / 185 MB / 21 MB | I | — |
| `~/.cargo`, `~/.nvm`, `~/.rvm`, `~/.bun`, `~/.config/valet` | on PATH / not measured | I | Toolchain homes to include in dev rules. |
| `~/bin/quickclean.sh` | 11 KB | — | Prototype (§1.6). |

### 1.3 Inventory B — Every command/tool used, why, and its product replacement

| # | Command (as run) | Why we ran it / logic | What we learned | Product replacement |
|---|------------------|-----------------------|-----------------|---------------------|
| C1 | `du -sh <dir>`; `du -sh <dir>/* \| sort -rh \| head -N` | Allocated size per subtree; rank children. | 60–290 s per `~/Library` subtree; reports allocated (du) not logical. | `ScanEngine` (getattrlistbulk) + `FileIndex.children(sortedBy: .allocated)`. |
| C2 | `du -ch $(find …) \| tail -1`; awk unit summing | Aggregate many dirs. | awk unit math error-prone (GB/MB/KB mixing). | Native byte arithmetic in `SizeTriple`. |
| C3 | `df -h /`, `df -h /System/Volumes/Data`, `df -k` | Free space. | `/` shows System volume "Used 16Gi"; `Avail` ≈ container free; units GiB vs GB confusion. | `statfs()` on Data volume; `URLResourceValues.volumeAvailableCapacity*`; decimal GB display. |
| C4 | `diskutil info / \| grep "Container Free Space"` | Real container free space incl. purgeable semantics. | Differs from `df` by purgeable; parsing human text is fragile (bug B1). | `statfs` + `volumeAvailableCapacityForImportantUsageKey`; DiskArbitration for volume names. |
| C5 | `diskutil apfs list` | Volume topology; found mounted simulator volumes/Cryptex bundle. | Mount points inside `/Library/Developer/CoreSimulator`. | `getmntinfo_r_np` + `ATTR_DIR_MOUNTSTATUS` in `VolumeTopology`. |
| C6 | `tmutil listlocalsnapshots /` | Local TM snapshots may hold space. | Only OS-update snapshots present. | `TMUtilAdapter.listLocalSnapshots()` (no root); delete via helper. |
| C7 | `sudo tmutil deletelocalsnapshots /` (recommended) | Free snapshot space. | Requires root/TTY. | Helper op `deleteLocalSnapshots(excluding: ["com.apple.os.update-"])`. |
| C8 | `docker system df [-v]` | Docker usage. | 0 images, 19 named volumes 807 MB. | `DockerAdapter.systemDF()` (JSON `--format '{{json .}}'`). |
| C9 | `docker system prune -a --volumes` | Reclaim Docker. | Returned 0 B: named volumes not pruned by `--volumes`. | `docker volume prune -a -f` (Docker ≥ 23) surfaced as explicit high-risk action. |
| C10 | `ls -lh Docker.raw` vs `du -sh Docker.raw` | Sparse file check. | 60 GB logical vs 1.3/16/20/8.7 GB allocated. | Allocated/private sizes per entry; `EF_IS_SPARSE` badge. |
| C11 | `xcrun simctl list runtimes`, `list devices available/unavailable`, `runtime list` | Simulator inventory. | 3 runtimes, 39 devices, 23.4 GB disk images. | `SimctlAdapter` (`-j` JSON). |
| C12 | `xcrun simctl runtime delete 23A343` | Remove a runtime safely (unmounts image). | Freed 19 GB; `rm` would have been wrong (mounted volume). | Rule `dev.xcode.simulator-runtimes` → tool action. |
| C13 | `xcrun simctl delete unavailable` | Drop devices whose runtime is gone. | None present. | Rule `dev.xcode.simulator-unavailable`. |
| C14 | `brew --cache`; `brew cleanup --prune=all` | Homebrew cache. | 63–144 MB. | `BrewAdapter`. |
| C15 | `npm cache clean --force`; `composer clear-cache` | Package caches. | — | `NodeToolsAdapter`, `ComposerAdapter` (or direct dir deletion of `~/.npm/_cacache`). |
| C16 | `find <roots> -type d -name node_modules -not -path "*/node_modules/*/node_modules*" -prune` | Enumerate top-level `node_modules`. | 18–46 dirs, 4.5–13.5 GB. | Index predicate `name == "node_modules" && !ancestorIsNodeModules`. |
| C17 | `stat -f "%Sm" -t "%Y-%m-%d" <parent>`; `date -v-90d` | Staleness by parent mtime. | mtime of parent is a weak proxy (parent mtime changes on file add/remove only). | `ProjectActivity` = max(git HEAD commit time, `.git/index` mtime, newest source mtime sample, root mtime). |
| C18 | `find / -type f -size +500M -exec du -sh {} +` | Large files (recommended). | Slow full-disk `find`. | `FileIndex.largeFiles(min:)` from the same scan. |
| C19 | `ls -la`, `ls \| grep lid.status \| wc -l` | Count/list status folders when glob failed. | 130 → 196 folders. | Direct enumeration; no shell. |
| C20 | `rm -rf <path>` (absolute) | Delete. | Partial failures produce thousands of lines (15,206 lines, 2.5 MB for one tree). | `DeletionEngine` with per-item results + aggregation. |
| C21 | `osascript -e 'quit app "X"'` → `pkill -9 X` fallback; `pgrep -x X` | Quit WhatsApp/Telegram/Claude before deleting. | Process-name matching misses helpers. | `NSRunningApplication` by bundle ID → `terminate()` → `forceTerminate()`; `proc_listpidspath` for open files. |
| C22 | `sudo -n …` | Non-interactive root. | "a password is required"/"a terminal is required". | `SMAppService` daemon + XPC helper. |
| C23 | `avdmanager list avd`, `avdmanager delete avd -n <name>`, `emulator -list-avds` | Android emulator inventory/removal. | Deletion also cleans `.ini`; 25 GB freed. | `AvdManagerAdapter`; fallback to direct `.avd`+`.ini` deletion when tools absent. |
| C24 | `sync; sleep 2` | Let APFS settle before re-measuring. | `df` lagged after deletes (purgeable). | Re-measure via `statfs` after `fsync`/`F_FULLFSYNC` not needed; poll with 250 ms backoff up to 3 s. |
| C25 | `sed -n 's/…(\([0-9]*\) Bytes).*/\1/p'`, `bc` | Parse diskutil, format bytes. | Fragile. | Native APIs, `ByteCountFormatter`. |
| C26 | `chmod +x`, edit `~/.zshrc` PATH | Install script. | — | Signed app bundle + `reclaim` CLI symlink installer. |
| C27 | `pgrep -x Docker \|\| pgrep -x com.docker.backend` | Docker running? | Multiple process names. | `NSRunningApplication(bundleIdentifier: "com.docker.docker")` + socket probe `~/.docker/run/docker.sock`. |
| C28 | `qlmanage` (not run; recommended) | QuickLook cache. | — | Rule `sys.quicklook-thumbnails` via `/usr/bin/qlmanage -r cache`. |
| C29 | `tmutil listbackups` | iOS/TM backups (recommended). | — | Report only. |
| C30 | `docker volume prune -a -f` (recommended) | Named volumes. | — | Rule `dev.docker.volumes` (high risk). |

### 1.4 Inventory C — Developer artifacts, caches, container layers and orphan types targeted

| Category | Artifact | Location pattern | Regenerable? | Observed |
|----------|----------|------------------|--------------|----------|
| Xcode | DerivedData | `~/Library/Developer/Xcode/DerivedData` | Yes (next build) | 61 MB – 628 MB |
| Xcode | iOS DeviceSupport | `~/Library/Developer/Xcode/iOS DeviceSupport/<version>` | Yes (device reconnect) | 4.4 – 9.7 GB |
| Xcode | Archives | `~/Library/Developer/Xcode/Archives/<date>/*.xcarchive` | **No** (dSYMs) | 16 KB |
| Xcode | Simulator runtimes | `/Library/Developer/CoreSimulator/Volumes/iOS_*`, `Images/*.dmg`, `Cryptex/Images/bundle/*` | Yes (download) | 15–18 GB each |
| Xcode | Simulator devices/data | `~/Library/Developer/CoreSimulator/Devices/<UDID>/data` | Yes (`simctl erase`) | 1.9 – 4.5 GB |
| Xcode | Simulator caches | `~/Library/Developer/CoreSimulator/Caches` | Yes | — |
| Node | `node_modules` | `<project>/node_modules` (top-level only) | Yes (`npm i`) | 4 MB – 1.6 GB each |
| Node | Framework outputs | `.next`, `.next/standalone/node_modules`, `.turbo`, `.nuxt`, `.cache`, `.parcel-cache`, `.vite`, `.svelte-kit`, `.angular`, `dist` (opt-in) | Yes | 60 MB (`.next/standalone`) |
| Node | Package stores | `~/Library/Caches/Yarn`, `~/.yarn/berry/cache`, `~/.npm/_cacache`, `~/Library/pnpm/store`, `~/.pnpm-store`, `~/.bun/install/cache`, `~/Library/Caches/node-gyp`, `~/Library/Caches/typescript` | Yes | 4.5 GB Yarn, 1.8–2.3 GB npm |
| Python/AI | pip/uv/poetry caches | `~/Library/Caches/pip`, `~/.cache/pip`, `~/.cache/uv`, `~/Library/Caches/pypoetry` | Yes | 80 MB |
| Python/AI | venvs, `__pycache__` | `<project>/.venv`, `venv`, `**/__pycache__` | Yes | — |
| Python/AI | HF / torch / Ollama models | `~/.cache/huggingface/hub`, `~/.cache/torch`, `~/.ollama/models` | Yes (download, large) | Ollama.app installed (695 MB) |
| Python/AI | Conda pkgs | `~/miniconda3/pkgs`, `~/anaconda3/pkgs`, `~/.conda/pkgs` | Yes | — |
| Rust | `target/` | `<project with Cargo.toml>/target` | Yes (`cargo build`) | **20 GB** |
| Rust | registry/git caches | `~/.cargo/registry/{cache,src}`, `~/.cargo/git` | Yes | — |
| Go | build/mod caches | `~/Library/Caches/go-build`, `~/go/pkg/mod` | Yes | 55 MB |
| Java/Kotlin | Gradle | `~/.gradle/caches`, `~/.gradle/wrapper/dists`, `<project>/build`, `.gradle/` | Yes | 5.0 GB |
| Java | Maven | `~/.m2/repository` | Yes | — |
| Android | AVDs | `~/.android/avd/*.avd` + `.ini` | Yes (recreate) | 20 + 4.6 GB |
| Android | System images | `$ANDROID_HOME/system-images/*` | Yes | in 3.9 GB SDK |
| Flutter/Dart | SDK cache, pub cache, builds | `~/flutter/bin/cache`, `~/.pub-cache`, `<project>/build`, `.dart_tool` | Yes | 3.9 GB SDK |
| PHP | Composer | `~/Library/Caches/composer`, `~/.composer/cache`, `<project>/vendor` | Yes | 96–226 MB; vendor 575 MB |
| Docker | VM disk | `~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw` | Yes (**destroys** images/volumes) | 60 GB logical / 1.3–20 GB alloc |
| Docker | Images/volumes/build cache | via daemon | Yes (re-pull) | 807 MB volumes |
| Docker | CLI config/cache | `~/.docker` | Partially | 431 MB |
| OrbStack/Colima | VM data | `~/.orbstack`, `~/.colima` | Yes | not present |
| Electron | Squirrel staging | `~/Library/Caches/<bundle>.ShipIt` | Yes | 0.3–1.7 GB each |
| Sparkle | Update staging | `~/Library/Caches/<bundle>/org.sparkle-project.Sparkle/Installation` | Yes | 644 MB (EACCES inside) |
| Electron | App caches | `Application Support/<app>/{Cache,Code Cache,GPUCache,DawnCache,GraphiteDawnCache,CachedData,CachedExtensionVSIXs,logs}` | Yes | 100–800 MB each |
| Editors | State backups | `Cursor/User/globalStorage/state.vscdb.backup`, `Code/User/globalStorage/state.vscdb.backup` | Yes | 1.0 GB |
| Editors | Orphan workspaces | `*/User/workspaceStorage/<hash>` whose `workspace.json` folder no longer exists | Yes | 3.1 GB / 191 entries |
| Claude Desktop | Sandbox VM | `Application Support/Claude/vm_bundles/claudevm.bundle` | Yes (recreated) | 9–11 GB |
| Browsers | Caches | Chrome/Brave/Arc `*/Cache`, Firefox `cache2` | Yes | 3–5 GB |
| Messaging | WhatsApp media | `Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media/<JID>` | Yes (re-download while on server) | up to 79 GB |
| Messaging | Telegram media | `Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/appstore/account-*/postbox/media` | Yes | 2.7–13 GB |
| Homebrew | Download cache | `~/Library/Caches/Homebrew` | Yes | 63–144 MB |
| Homebrew | Legacy prefix | `/usr/local/{Cellar,opt,bin,lib}` | Risky | 9.9 GB |
| Playwright | Browsers | `~/Library/Caches/ms-playwright` | Yes | 520 MB |
| Cloud CLI | AWS cache | `~/Library/Caches/aws`, `~/.aws/cli/cache` | Yes | 0.8–1.1 GB |
| Orphans | Old user home | `/Users/Deleted Users/<name>` | n/a | 31 GB |
| Orphans | Containers of uninstalled apps | `~/Library/{Application Support,Containers,Group Containers,Caches,Preferences,Saved Application State}` keyed by bundle ID | n/a | UUID container 367 MB |
| Media | Archive + extracted duplicate | `~/Movies/*.zip` + sibling folder | n/a | 5 GB |
| Media | Disk images | `~/*.img`, `*.dmg` | n/a | 1.9 GB |
| System | Trash | `~/.Trash`, `/Volumes/*/.Trashes/<uid>` | n/a | 673 MB |
| System | TM local snapshots | APFS snapshots (`tmutil`) | Yes | 3 OS-update snapshots |

### 1.5 Inventory D — Errors, SIP/TCC boundaries, locks and edge cases (EC-xx)

| ID | What happened (verbatim evidence) | Root cause | Engineering requirement |
|----|-----------------------------------|------------|-------------------------|
| EC-01 | `rm -rf *.lid.status` → `(eval):13: no matches found: *.lid.status` though 130 folders existed; `find -maxdepth 1 -name "*.lid.status"` also returned 0 while `ls \| grep` found 130. | Shell glob/quoting under the non-interactive zsh harness (NOMATCH + `@`/`.` in names); `find -name` pattern mismatch due to leading path components. | **REQ-ENUM-1:** Never enumerate or delete via shell globbing or string-built commands. Use `getattrlistbulk`/`fts`, pass paths as arrays, treat every byte sequence as a valid name (NFD, `@`, spaces, newlines). |
| EC-02 | `sudo -n rm` → `sudo: a password is required`; later `sudo: a terminal is required to read the password`. | No TTY, no askpass. | **REQ-PRIV-1:** Root operations only through an `SMAppService` daemon over XPC with an allowlist; never spawn `sudo`. |
| EC-03 | `Deleted Users/olawaleilesanmi/Library/Mobile Documents: Operation not permitted` (EPERM). | TCC-protected iCloud Drive folder; FDA not granted to the shell process. | **REQ-TCC-1:** Detect FDA; classify `EPERM` as policy denial vs `EACCES` as POSIX permission; surface guidance instead of retrying. **REQ-PRIV-2:** Document that the helper is a separate TCC subject; provide "grant FDA to helper" flow. |
| EC-04 | Same tree: `…/Library/Audio/Plug-Ins: Permission denied`, `…/Downloads: Permission denied`, root `Operation not permitted`; 15,206 error lines (2.5 MB). | Parent `Deleted Users` is `root:admin 0770`; subdirs owned by another UID or mode-restricted; cascade of "Directory not empty". | **REQ-DEL-1:** Per-entry result codes aggregated into counts by `errno`; a failing child must not spam the UI; parent removal attempted only if all children succeeded. |
| EC-05 | `rm: …/com.obsproject.obs-studio/org.sparkle-project.Sparkle/Installation/…/OBS.app/Contents/PlugIns/obs-zego.plugin/…: Permission denied` chain. | Sparkle staged install with read-only directory modes inside the user's cache. | **REQ-DEL-2:** On `EACCES` for a user-owned directory, optionally `chmod u+rwx` the directory (never files' content) then retry once; else report partial. |
| EC-06 | `Docker.raw`: `ls -lh` = 60G, `du -sh` = 1.3G/16G/20G/8.7G. | Sparse file. | **REQ-SIZE-1:** Store logical, allocated and private sizes per entry; UI and savings use allocated/private. |
| EC-07 | `df` showed 27 GiB after deleting 5.6 GB of status folders (unchanged); `diskutil` container free 28.8 GB; later grew to 33 GiB "by itself". | APFS purgeable/snapshot retention and deferred reclamation; GiB vs GB. | **REQ-SIZE-2:** Report "freed" as Δ `statfs.f_bavail` measured after a settle loop; label purgeable separately; decimal units. |
| EC-08 | `df -h /` → `Used 16Gi` on a 460 Gi disk. | `/` is the sealed System snapshot volume; user data lives on Data volume. | **REQ-VOL-1:** Compute capacity from the Data volume; attribute System volume usage as "macOS". |
| EC-09 | `diskutil apfs list` showed simulator runtime volumes mounted at `/Library/Developer/CoreSimulator/Volumes/iOS_*` and a Cryptex bundle mounted at `…/Cryptex/Images/bundle/SimRuntimeBundle-EB892DEF…`. | Disk images mounted as APFS volumes inside a directory tree we were about to measure/delete. | **REQ-VOL-2:** Detect mount points (`ATTR_DIR_MOUNTSTATUS`, `st_dev` change, `getmntinfo`) and never recurse-delete across them; route to `simctl runtime delete`. |
| EC-10 | `docker system prune -a --volumes` → 0 B although 807 MB of volumes existed. | `--volumes` removes anonymous volumes only. | **REQ-TOOL-1:** Encode tool semantics per version; use `docker volume prune -a`. |
| EC-11 | `quickclean.sh` printed `Starting free space: 76910911512375027.9 GB`. | `gsub(/[^0-9]/,"")` concatenated every digit in the diskutil line. | **REQ-API-1:** Never parse human-readable tool output for numbers when an API exists; when parsing is unavoidable, use machine formats (`-j`, `--format json`, plist) and property-based tests. |
| EC-12 | `du` commands timed out at 30 s / 120 s / 180 s and had to be backgrounded; `~/Library/Application Support/*` took 287 s. | One `stat` per file over millions of files; no parallelism. | **REQ-PERF-1:** Bulk attribute reads per directory, parallel across directories, cached snapshot for re-use. |
| EC-13 | WhatsApp/Telegram/Claude/Docker had files open; we had to quit apps first (`osascript quit` → `pkill -9`). | Deleting files under a running app causes DB/WAL inconsistency or immediate regeneration. | **REQ-APP-1:** Per-rule `ownerBundleIDs`; block or offer graceful quit via `NSRunningApplication`; pre-flight `proc_listpidspath` for permanent tier. |
| EC-14 | Terminal file showed a later command executing with `cwd` inside `…/Message/Media` (state persisted across calls). | Persistent shell state; relative paths become dangerous. | **REQ-DEL-3:** All deletion uses absolute, canonicalized paths plus `(dev, ino)` identity captured at scan time and re-verified at delete time (TOCTOU). |
| EC-15 | WhatsApp JIDs are opaque (`120363076093068126@g.us`). | No name mapping outside the app DB. | **REQ-UX-1:** Resolve JID → chat name from a read-only copy of `ChatStorage.sqlite` (`ZWACHATSESSION.ZCONTACTJID/ZPARTNERNAME`) when WhatsApp is not running; fall back to JID. |
| EC-16 | `xcrun simctl delete unavailable` did nothing; runtimes had to be deleted explicitly; Cryptex bundle in use by iOS 18.3.1 could not be removed. | Runtime ownership model. | **REQ-TOOL-2:** Use `simctl runtime list -j` to map bundles → runtimes; only offer bundles with no owning runtime. |
| EC-17 | `/private/var/folders` appears under both `/private/var/folders` and `/System/Volumes/Data/private/var/folders`; `~/Library` equals `/System/Volumes/Data/Users/olawale/Library`. | Firmlinks. | **REQ-VOL-3:** Canonicalize via `realpath`/`ATTR_CMNEXT_NOFIRMLINKPATH`; dedupe by `(fsid, fileid)`; scan each inode once. |
| EC-18 | `du -sh ~/Documents` = 1.1 GB vs Storage Settings "Documents 112.7 GB". | Settings categories ≠ folders. | **REQ-UX-2:** Provide our own category taxonomy with explicit path attribution (§5.2). |
| EC-19 | Time Machine listed `com.apple.os.update-*` snapshots. | OS update rollback snapshots. | **REQ-TM-1:** Never delete snapshots whose name starts with `com.apple.os.update-`; only `com.apple.TimeMachine.*`. |
| EC-20 | `Movies`: 5 GB zip + 5 GB extracted folder of the same season. | Duplicate content in different containers. | **REQ-DUP-1:** Archive-vs-folder heuristic (name stem match + entry count/size parity) and content duplicate detection. |
| EC-21 | Cursor `state.vscdb` 4 → 5.7 GB live SQLite; `.backup` 1 GB. | App state DB grows; cannot be deleted while app runs; deleting loses chat history. | **REQ-RULE-1:** Rules distinguish *derived* (safe) from *stateful* (protected) files within the same app folder. |
| EC-22 | 191 `workspaceStorage` entries for ~40 live projects. | Editors never GC workspace state. | **REQ-RULE-2:** Orphan detection by dereferencing `workspace.json` → `folder`/`workspace` URI. |
| EC-23 | `find ~/work ~/projects … -prune` + `stat` loop took 50–160 s and we deleted by parent mtime. | mtime heuristic + slow enumeration. | **REQ-RULE-3:** Project activity from git + index; staleness thresholds configurable (default protect < 7 d, recommend ≥ 90 d). |
| EC-24 | `Container Free Space` vs `df Avail` differed by ~1.6 GB; Finder shows decimal GB. | Units + purgeable. | **REQ-UX-3:** One unit system (decimal, `ByteCountFormatter.countStyle = .file`), tooltips show exact bytes. |
| EC-25 | Needed `sudo` to delete 0-byte Cryptex directories and root logs; `/Library/Caches` untouched. | Root ownership. | **REQ-PRIV-3:** Helper allowlist includes exactly: TM local snapshots, `/Library/Caches/*`, `/Library/Logs/DiagnosticReports/*`, `/private/var/log/asl/*.asl`, `/Users/Deleted Users/*`, unreferenced Cryptex bundles, `/usr/local` legacy prefix (explicit). Nothing else. |
| EC-26 | Deleting `/Users/Deleted Users/…` first attempt produced "Directory not empty" at every ancestor. | Recursive delete continued past failures without summarizing. | **REQ-DEL-1** (dup) + **REQ-UX-4:** failure summary grouped by errno with "Reveal in Finder" and "Retry with helper". |
| EC-27 | Rapid regrowth (WhatsApp 1.8 → 79 GB in 5 weeks; `Docker.raw` 1.3 → 20 GB). | No monitoring. | **REQ-MON-1:** Menu bar monitor tracks watched roots and alerts on growth > threshold or free < threshold. |

### 1.6 The prototype: `~/bin/quickclean.sh` (Informative, with defects to avoid)

Behaviors to port: free-space before/after, `--dry-run` / `--report` / `--yes` flags, sectioned progress, quit-app-before-delete, skip Docker reset when Docker runs, stale `node_modules` by 90-day cutoff, Trash emptying, `brew cleanup` and `npm cache clean` invocations.

Defects found (each becomes a test in Phase 2/3):

| ID | Defect | Product rule |
|----|--------|--------------|
| B1 | Free-space digit concatenation (EC-11). | `statfs` API; property test: parse never used for numbers. |
| B2 | Hard-coded WhatsApp JID `120363076093068126@g.us`. | Rank by size; user picks; names resolved (REQ-UX-1). |
| B3 | `ls \| grep lid.status \| while read` — breaks on newlines in names. | API enumeration (REQ-ENUM-1). |
| B4 | `rm -rf "$CACHE_ROOT/$cache"` with no identity check. | REQ-DEL-3. |
| B5 | `pgrep -x` by process name. | Bundle-ID based detection (REQ-APP-1). |
| B6 | `--yes` resets `Docker.raw` without inspecting contents. | High-risk tier always requires explicit per-item confirmation (§4.4). |
| B7 | No ledger / undo. | §4.6. |
| B8 | Deleted `~/Library/Caches/Google` wholesale (includes Chrome `Default/Cache` plus non-cache data). | Scoped cache subpaths per browser (§3.4.1). |
| B9 | `Archives` deleted as "safe". | Medium risk; off by default. |
| B10 | Sequential `du` for reporting (slow). | Shared scan snapshot. |

### 1.7 Traceability matrix (edge case → requirement → component → test)

| EC | REQ | Component (module.type) | Test ID |
|----|-----|-------------------------|---------|
| EC-01, B3 | REQ-ENUM-1 | `ReclaimCore.BulkAttrEnumerator`, `FTSEnumerator` | T1-ENUM-NAMES (names with `@ . space \n`, NFD) |
| EC-02, EC-25 | REQ-PRIV-1/3 | `ReclaimHelper.HelperService`, `ReclaimXPC.HelperProtocol` | T5-HELPER-ALLOWLIST |
| EC-03 | REQ-TCC-1, REQ-PRIV-2 | `ReclaimSafety.PermissionProbe` | T2-TCC-CLASSIFY (mocked errno) |
| EC-04, EC-26 | REQ-DEL-1, REQ-UX-4 | `ReclaimSafety.DeletionEngine`, `OperationReport` | T2-DEL-PARTIAL |
| EC-05 | REQ-DEL-2 | `DeletionEngine.retryPolicy` | T2-DEL-CHMOD-RETRY |
| EC-06 | REQ-SIZE-1 | `ReclaimCore.SizeTriple`, `EntryRecord` | T1-SIZE-SPARSE |
| EC-07, EC-24 | REQ-SIZE-2, REQ-UX-3 | `ReclaimCore.VolumeStats`, `FreedSpaceMeter` | T2-FREED-DELTA |
| EC-08 | REQ-VOL-1 | `ReclaimCore.VolumeTopology` | T1-VOL-DATAVOLUME |
| EC-09 | REQ-VOL-2 | `VolumeTopology.mountPoints`, `PathGuard.mountGuard` | T1-VOL-MOUNTPOINT (hdiutil fixture) |
| EC-10 | REQ-TOOL-1 | `ReclaimRules.DockerAdapter` | T3-DOCKER-VOLUMES (mock CLI) |
| EC-11, B1 | REQ-API-1 | `ReclaimCore.VolumeStats` | T1-STATFS |
| EC-12 | REQ-PERF-1 | `ScanEngine` | T0-BENCH-2M |
| EC-13, B5 | REQ-APP-1 | `ReclaimSafety.AppCoordinator`, `ProcessInspector` | T2-OPENFILES, T2-QUIT-APP |
| EC-14, B4 | REQ-DEL-3 | `DeletionEngine.verifyIdentity` | T2-TOCTOU-SWAP |
| EC-15, B2 | REQ-UX-1 | `ReclaimRules.WhatsAppRule.NameResolver` | T3-WA-NAMES (fixture sqlite) |
| EC-16 | REQ-TOOL-2 | `SimctlAdapter` | T3-SIMCTL-MAP |
| EC-17 | REQ-VOL-3 | `PathCanonicalizer`, `FileIndex.identitySet` | T1-FIRMLINK-DEDUPE |
| EC-18 | REQ-UX-2 | `ReclaimRules.CategoryAttribution` | T3-CATEGORY-EXACTLY-ONCE |
| EC-19 | REQ-TM-1 | `TMUtilAdapter` | T5-TM-FILTER |
| EC-20 | REQ-DUP-1 | `ReclaimRules.DuplicateFinder`, `ArchiveFolderHeuristic` | T3-DUP-ARCHIVE |
| EC-21, B9 | REQ-RULE-1 | `ReclaimRules.EditorStateRule` | T3-EDITOR-PROTECT-LIVE-DB |
| EC-22 | REQ-RULE-2 | `EditorWorkspaceOrphanRule` | T3-WORKSPACE-ORPHAN |
| EC-23 | REQ-RULE-3 | `ReclaimSafety.ProjectActivity`, `GitInspector` | T2-GIT-DIRTY, T3-NODE-STALE |
| EC-27 | REQ-MON-1 | `ReclaimUI.MenuBarMonitor`, `GrowthTracker` | T4-MONITOR-THRESHOLD |
| B6 | §4.4 | `CleanExecutor.confirmationPolicy` | T2-HIGH-RISK-REQUIRES-CONFIRM |
| B7 | §4.6 | `ReclaimPersistence.LedgerStore` | T2-LEDGER-UNDO |
| B8 | §3.4.1 | `BrowserCacheRule` | T3-BROWSER-SCOPED |

---

## 2. STEP 2 — System Architecture & Technical Stack

### 2.1 Product scope and architectural principles

1. **One scan, many consumers.** A single `ScanSnapshot` (compact in-memory index + on-disk cache) feeds the dashboard, treemap, rules engine, duplicate finder and CLI. No rule performs its own filesystem walk; rules query the index. Only "deep" rules (hashing, SQLite reads, tool invocations) touch the disk again.
2. **Kernel-level truth.** Sizes, flags, identities and mount status come from `getattrlistbulk(2)`/`fstatat(2)`/`statfs(2)`, never from parsing tool output. External tools (`simctl`, `docker`, `brew`, `tmutil`, `avdmanager`) are used only for operations that have no public API, always with machine-readable output.
3. **Non-destructive by default.** Default tier is Trash with a ledger; permanent deletion is opt-in per operation; the helper's power is bounded by a compile-time allowlist.
4. **Explain everything.** A finding without `rationale` and `regeneration` text cannot compile (non-optional fields).
5. **Strict Swift 6 concurrency.** `-strict-concurrency=complete`; every cross-task type is `Sendable`; mutable shared state lives in actors; UI state is `@MainActor`.
6. **Test with real filesystems.** Fixtures are created on APFS temp volumes/directories with real sparse files, clones, hard links, symlink loops, immutable flags and mounted DMGs.

### 2.2 Technology stack and versions

| Concern | Choice | Rationale |
|---------|--------|-----------|
| Language | Swift 6.0 (Xcode 16.x), `swift-tools-version: 6.0`, strict concurrency | Actor isolation guarantees for a multi-threaded scanner. |
| Min OS | macOS 14.0 (Sonoma) | `@Observable`, `SwiftData` availability (not used), `SMAppService` (13+), `MenuBarExtra` (13+), `setCodeSigningRequirement` (13+). |
| UI | SwiftUI (app shell, dashboard, settings, menu bar) + AppKit bridges (`NSOutlineView`/`NSTableView` for dense tables, `NSBrowser`-style Miller columns, `QLPreviewPanel`, `NSWorkspace`) | SwiftUI `Table` degrades past ~50k rows; AppKit views are cell-recycled and keyboard-native. |
| Rendering | SwiftUI `Canvas` for treemap/sunburst with culling + LOD; layout computed off-main in an actor | 60 fps with ≤ 5k visible rects; avoids per-rect view overhead. |
| Filesystem | `getattrlistbulk(2)` primary; `fts(3)` fallback; `openat/fstatat/unlinkat` with `O_NOFOLLOW`; `statfs(2)`; `getmntinfo_r_np(3)`; `clonefile(2)` in tests | Fastest public APIs; symlink-safe. |
| Processes | `libproc` (`proc_listpidspath`, `proc_pidpath`), `NSRunningApplication` | Open-file pre-flight, app quit. |
| Privilege | `SMAppService.daemon` + `NSXPCConnection` with code-signing requirement | Modern replacement for `SMJobBless`; no `sudo`. |
| Persistence | SQLite 3 (system `libsqlite3`) via a thin actor wrapper, WAL mode | Ledger must be queryable by CLI and robust across crashes; SwiftData adds schema migration risk and MainActor coupling. |
| Snapshot cache | Custom little-endian binary format `.rclsnap` (versioned) | Reload 3 M entries in < 1 s. |
| Hashing | CryptoKit `SHA256` (full) + 64-bit non-cryptographic fingerprint (`SipHash-1-3` implementation in-repo) for prefilter | No third-party dependency; BLAKE3 optional later behind a protocol. |
| CLI | `swift-argument-parser` (Apple) | Only external dependency in v1. |
| Logging | `os.Logger` subsystems `com.olawale.reclaim.{scan,rules,safety,helper,ui}` | Unified logging, privacy-redacted paths by default. |
| Tests | Swift Testing (`import Testing`) for unit/integration; XCTest for `measure` benchmarks and XCUITest smoke | Parallel, expressive, trait-based (`.tags(.requiresAPFS)`). |
| Packaging | Developer ID Application cert, Hardened Runtime, `notarytool`, `stapler`, DMG via `hdiutil`; Sparkle 2 for updates (Phase 5, optional) | Required for FDA + helper outside MAS. |
| CI | GitHub Actions `macos-15` runners (APFS, Xcode 16) | Fixtures need APFS; privileged-helper tests run only locally (`.tags(.requiresAdmin)`). |

**Identifiers (literal):**

| Item | Value |
|------|-------|
| App bundle ID | `com.olawale.reclaim` |
| Helper (LaunchDaemon) label / Mach service | `com.olawale.reclaim.helper` |
| CLI executable | `reclaim` (installed at `/usr/local/bin/reclaim` → symlink to `Reclaim.app/Contents/MacOS/reclaim`) |
| Login item / monitor | main app with activation policy switch (no separate agent in v1) |
| App group (for shared SQLite between app and CLI) | not used; both read `~/Library/Application Support/Reclaim/` directly (non-sandboxed) |
| Data dir | `~/Library/Application Support/Reclaim/` (`ledger.sqlite`, `snapshots/`, `rules.user.json`, `settings.json`) |
| Logs | `~/Library/Logs/Reclaim/` (rotated, 10 × 5 MB) |
| Team ID placeholder | `TEAMID` (replace in `Config/Signing.xcconfig`) |

### 2.3 Module map

```
Reclaim.xcworkspace
├── Packages/ReclaimKit (SwiftPM, library targets + CLI executable)
│   ├── Sources/ReclaimCore        — FS primitives, scanner, index, volume topology, sizes, snapshot I/O
│   ├── Sources/ReclaimSafety      — protected paths, path guard, permission probe, git/project activity,
│   │                                 process inspector, deletion engine, app coordinator, freed-space meter
│   ├── Sources/ReclaimPersistence — SQLite wrapper, ledger store, settings store, snapshot catalog
│   ├── Sources/ReclaimRules       — rule protocol, registry, category attribution, all rule modules,
│   │                                 tool adapters (simctl/docker/brew/tmutil/avdmanager/npm/qlmanage)
│   ├── Sources/ReclaimXPC         — @objc HelperProtocol, shared request/response structs, requirement strings
│   ├── Sources/ReclaimCLI         — `reclaim` executable (ArgumentParser)
│   ├── Sources/ReclaimBench       — `reclaim-bench` executable, fixture generator
│   ├── Sources/ReclaimTestSupport — FixtureBuilder, fake tool runners, errno injection
│   └── Tests/…                    — one test target per module (+ Integration)
├── Apps/Reclaim (Xcode app target, SwiftUI)
│   ├── Sources/ReclaimApp         — @main, AppModel, scenes, onboarding
│   ├── Sources/ReclaimUI          — views, AppKit bridges, treemap, Miller columns, menu bar
│   ├── Resources                  — Assets.xcassets, Localizable.xcstrings, Rules/builtin.rules.json (generated)
│   └── Helper/ReclaimHelper       — LaunchDaemon executable (ReclaimXPC + ReclaimSafety subset)
└── Config/                        — *.xcconfig, entitlements, LaunchDaemons/com.olawale.reclaim.helper.plist
```

Dependency direction (strict, enforced by SwiftPM): `ReclaimCore` ← `ReclaimSafety` ← `ReclaimRules` ← {`ReclaimCLI`, `ReclaimUI`}; `ReclaimPersistence` depends only on `ReclaimCore`; `ReclaimXPC` depends on nothing; `ReclaimHelper` depends on `ReclaimXPC` + `ReclaimSafety` (deletion engine) but **not** on `ReclaimRules`. UI never imports `Darwin` FS APIs directly.

### 2.4 Process model

| Process | Runs as | Lifetime | Responsibilities |
|---------|---------|----------|------------------|
| `Reclaim.app` | user | foreground; may switch to `.accessory` policy to live in the menu bar | Scanning, rules, UI, Trash-tier deletions, user-level permanent deletions, monitor timer. |
| `reclaim` CLI | user | per command | Same engine; JSON output; used by tests and power users; can request helper ops through the same XPC service if installed. |
| `com.olawale.reclaim.helper` | root (LaunchDaemon via `SMAppService`) | on-demand (launchd Mach service) | Allowlisted root operations only (§2.9.5). Idle-exits after 60 s. |

IPC: XPC (`NSXPCConnection(machServiceName: "com.olawale.reclaim.helper", options: .privileged)`). The app validates the helper's version on connect; the helper validates the client's code signature (§2.9.4).

### 2.5 Concurrency model

- **Actors:** `ScanEngine` (orchestrates a scan), `FileIndex` (owns the entry arrays), `VolumeTopology` (mount table cache), `LedgerStore`, `SettingsStore`, `RuleRegistry`, `ToolRunner`, `CleanExecutor`, `TreemapLayoutEngine`.
- **Workers:** the scanner uses a `TaskGroup` with `maxConcurrency = min(activeProcessorCount, 12)` tasks pulling directory work items from a `WorkQueue` (actor-backed deque). Each worker owns its own `UnsafeMutableRawBufferPointer` attribute buffer (256 KiB) and emits `EntryBatch` values (Sendable, value type) to the `FileIndex` actor in batches of ≤ 4,096 entries to amortize actor hops.
- **Non-Sendable C handles:** `FTS*` and raw buffers are wrapped in `final class` types marked `@unchecked Sendable` with a documented invariant that each instance is confined to exactly one task; `nonisolated(unsafe)` is forbidden except in those wrappers.
- **Streams:** `ScanEngine.run(_:) -> AsyncThrowingStream<ScanEvent, Error>`; UI consumes on `@MainActor` with coalescing (progress updates throttled to 10 Hz).
- **Cancellation:** cooperative; workers check `Task.isCancelled` per directory; partial snapshot is still usable (`ScanSummary.completeness = .partial(reasons:)`).
- **Main actor:** `AppModel` (`@Observable @MainActor`) holds view state; heavy derived data (sorted children, treemap layout) is computed off-main and delivered as immutable `Sendable` structs.

### 2.6 High-performance APFS scanner

#### 2.6.1 Why not `FileManager`

`FileManager.enumerator(at:includingPropertiesForKeys:)` performs one `getattrlist`/`stat` per URL, allocates `URL`/`NSString` objects per entry and is single-threaded; measured in S5 the equivalent `du` passes took 60–290 s per `~/Library` subtree. `fts(3)` avoids object allocation but still issues one `lstat` per entry. `getattrlistbulk(2)` returns hundreds of entries per syscall with exactly the attributes requested (including allocated/private sizes and BSD flags), which is the only way to approach SSD metadata throughput.

#### 2.6.2 Primary enumerator: `BulkAttrEnumerator`

Requested attribute set (constants from `<sys/attr.h>`):

```swift
var list = attrlist()
list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
list.commonattr  = attrgroup_t(ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_ERROR |
                               ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME |
                               ATTR_CMN_OWNERID | ATTR_CMN_GRPID | ATTR_CMN_ACCESSMASK |
                               ATTR_CMN_FLAGS | ATTR_CMN_FILEID)
list.dirattr     = attrgroup_t(ATTR_DIR_ENTRYCOUNT | ATTR_DIR_MOUNTSTATUS)
list.fileattr    = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE)
list.forkattr    = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_EXT_FLAGS |
                               ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_LINKID)   // valid with FSOPT_ATTR_CMN_EXTENDED
let options: UInt64 = UInt64(FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS | FSOPT_ATTR_CMN_EXTENDED)
```

Loop per directory (pseudocode, exact shape to implement):

```swift
func readDirectory(dirfd: Int32, into batch: inout EntryBatch) throws {
    while true {
        let n = getattrlistbulk(dirfd, &list, buffer.baseAddress, buffer.count, options)
        if n == 0 { return }                               // exhausted
        if n < 0 {
            if errno == EINTR { continue }
            throw FSError.enumerate(errno: errno)            // EACCES / EPERM / ENOTDIR / EIO
        }
        var p = buffer.baseAddress!
        for _ in 0..<Int(n) {
            let length = Int(p.load(as: UInt32.self))
            try parseEntry(at: p, length: length, into: &batch)   // §2.6.3
            p += length
        }
    }
}
```

Directory file descriptors are obtained with `openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)` — never by path string — so traversal cannot be redirected through a symlink and never exceeds `PATH_MAX` limits. Soft `RLIMIT_NOFILE` is raised to 8,192 at startup; the scheduler caps open directory fds at 2,048 (depth-first drain when near the cap).

#### 2.6.3 Entry buffer parsing

Each returned record is: `u_int32_t length`, then `attribute_set_t returned` (because `ATTR_CMN_RETURNED_ATTRS` is requested), then the attributes **in ascending bit order within each group, groups in order common → directory → file → fork/common-extended**. `ATTR_CMN_ERROR`, when present, appears immediately after `ATTR_CMN_RETURNED_ATTRS`. Variable-length `ATTR_CMN_NAME` is an `attrreference_t { attr_dataoffset: Int32, attr_length: UInt32 }` relative to the reference's own address. Fixed sizes: `ATTR_CMN_OBJTYPE` `fsobj_type_t` (UInt32: `VREG, VDIR, VLNK, VSOCK, VFIFO, VBLK, VCHR`), `ATTR_CMN_MODTIME/CHGTIME` `timespec`, `ATTR_CMN_OWNERID` `uid_t`, `ATTR_CMN_GRPID` `gid_t`, `ATTR_CMN_ACCESSMASK` UInt32, `ATTR_CMN_FLAGS` UInt32, `ATTR_CMN_FILEID` UInt64, `ATTR_DIR_ENTRYCOUNT` UInt32, `ATTR_DIR_MOUNTSTATUS` UInt32 (`DIR_MNTSTATUS_MNTPOINT`, `DIR_MNTSTATUS_TRIGGER`), `ATTR_FILE_LINKCOUNT` UInt32, `ATTR_FILE_TOTALSIZE`/`ALLOCSIZE` `off_t`, `ATTR_CMNEXT_PRIVATESIZE` `off_t`, `ATTR_CMNEXT_EXT_FLAGS` UInt64 (`EF_MAY_SHARE_BLOCKS`, `EF_NO_XATTRS`, `EF_IS_SYNC_ROOT`, `EF_IS_PURGEABLE`, `EF_IS_SYNTHETIC`, `EF_IS_SPARSE`, `EF_SHARES_ALL_BLOCKS`), `ATTR_CMNEXT_CLONEID` UInt64, `ATTR_CMNEXT_LINKID` UInt64. The parser consults `returned` before reading each field; directory-only or file-only fields are skipped for the other object type. `ATTR_CMN_FLAGS` bits of interest: `UF_IMMUTABLE`, `SF_IMMUTABLE`, `SF_RESTRICTED`, `UF_HIDDEN`, `UF_COMPRESSED`, `UF_DATAVAULT`, `UF_TRACKED`, `SF_FIRMLINK`.

**Validation test (T1-BULK-PARITY):** for every entry in a fixture tree, compare parsed `(objtype, mtime, uid, mode, flags, fileid, nlink, size, allocsize)` with `fstatat(dirfd, name, AT_SYMLINK_NOFOLLOW)`; zero mismatches required. This test is the contract that protects against field-order mistakes.

#### 2.6.4 Fallback enumerator: `FTSEnumerator`

Used when `getattrlistbulk` fails with `ENOTSUP`/`EINVAL` (non-APFS/HFS+/network/FUSE volumes) or when `ScanOptions.forceFTS` is set for benchmarking. `fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)`; handles `FTS_D/FTS_DP/FTS_F/FTS_SL/FTS_SLNONE/FTS_DNR/FTS_NS/FTS_ERR/FTS_DC`; `st_blocks * 512` for allocated; private size unavailable (set equal to allocated, flag `sizeConfidence = .allocatedOnly`). `fts_set(FTS_SKIP)` on excluded or mount-point directories.

#### 2.6.5 Parallel scheduler

```
roots → canonicalize → for each root: push DirWorkItem(parentEntry, dirfd)
workers (N): pop → readDirectory → for each subdirectory:
    if mountPoint || excluded || deviceChanged(st_dev) → record as leaf "boundary" entry, do not recurse
    else openat(...) → push
    emit EntryBatch to FileIndex every 4096 entries or at dir end
FileIndex: append entries (struct-of-arrays), assign EntryID, link parent/sibling
post-pass (single task, O(n)): roll up sizes from leaves to roots in reverse insertion order;
    hard links: count allocated once per (fsid,fileid) in `linkedIdentities`; attribute the first occurrence;
    clones: sum `privateSize` separately; `allocatedShared = allocated - private`
```

Work ordering: LIFO (depth-first) to keep the open-fd count bounded, with a size hint (`ATTR_DIR_ENTRYCOUNT`) to schedule big directories first across workers.

#### 2.6.6 Memory model: `FileIndex`

Struct-of-arrays, all `ContiguousArray`:

| Array | Type | Notes |
|-------|------|-------|
| `nameOffset` / `nameLength` | `UInt32` / `UInt16` | into one UTF-8 `nameArena: [UInt8]` (NFD preserved as-is from kernel). |
| `parent`, `firstChild`, `nextSibling` | `UInt32` (`EntryID.raw`) | `UInt32.max` = none. Tree is reconstructable without hash maps. |
| `kind` | `UInt8` | `.file, .directory, .symlink, .socket, .fifo, .device, .mountBoundary, .unreadable` |
| `bsdFlags` | `UInt32` | raw `st_flags`. |
| `extFlags` | `UInt8` | packed `EF_*` bits we care about. |
| `mode` | `UInt16` | |
| `uid` | `UInt32` | |
| `mtime` | `Int64` | seconds since epoch (ns discarded). |
| `fileID`, `cloneID` | `UInt64` | `cloneID == 0` when not cloned. |
| `linkCount` | `UInt16` | saturating. |
| `logical`, `allocated`, `privateBytes` | `UInt64` | per entry; for directories = rolled-up totals (own + descendants), excluding boundaries. |
| `errno` | `UInt16` | non-zero for `.unreadable`. |
| `volumeIndex` | `UInt8` | into `VolumeTopology.volumes`. |

≈ 70 bytes/entry → 3 M entries ≈ 210 MB + name arena (~25 bytes avg → 75 MB). Target met (G6). Access APIs are synchronous on the actor and return small `Sendable` DTOs (`EntrySummary`, `ChildrenPage`).

#### 2.6.7 Snapshot persistence and incremental rescans

- `ScanSnapshot` serializes the arrays to `~/Library/Application Support/Reclaim/snapshots/<uuid>.rclsnap` (header: magic `RCL1`, version, roots, volume table, created-at, completeness; body: raw arrays, zstd-free for simplicity, mmap-friendly alignment). Load = `mmap` + bounds validation.
- **Incremental rescan:** for a user-chosen subtree, rescan only that subtree and splice (`FileIndex.replaceSubtree(_:with:)`); full rescans are default because they are fast enough (G1).
- **Change detection for the monitor:** cheap `getattrlist(ATTR_CMN_MODTIME | ATTR_DIR_ENTRYCOUNT)` on watched directories plus `statfs`; FSEvents (`FSEventStreamCreate` with `kFSEventStreamCreateFlagWatchRoot`, directory-level events only) on watched roots to trigger subtree rescans debounced at 30 s.

#### 2.6.8 Exclusions during scan

Default excludes (not descended, recorded as boundaries): `/System` (sealed, SIP; sizes attributed via System volume `statfs`), `/Volumes/*` other than the boot volume unless the user opts in, `/dev`, `/proc`-like synthetic paths (`EF_IS_SYNTHETIC`), `~/Library/Mobile Documents` (iCloud; counted via `du`-equivalent only if FDA is granted — descend but never offer deletion), network mounts (`statfs.f_flags & MNT_LOCAL == 0`), Time Machine backup volumes (`Backups.backupdb`, `.backupbundle`).

### 2.7 APFS-specific accuracy

| Concern | Mechanism | UI/accounting rule |
|---------|-----------|---------------------|
| Logical vs allocated | `ATTR_FILE_TOTALSIZE` vs `ATTR_FILE_ALLOCSIZE` (`NSURLFileSizeKey` vs `NSURLTotalFileAllocatedSizeKey` equivalents) | Sort/size by **allocated**; show logical in inspector; badge "sparse" when `EF_IS_SPARSE` or `allocated < logical/2`. |
| Clones | `ATTR_CMNEXT_CLONEID` + `ATTR_CMNEXT_PRIVATESIZE`; `EF_MAY_SHARE_BLOCKS` | "Reclaimable if deleted alone" = Σ private. Finding totals show both `allocated` and `privateReclaimable`; the plan's estimate uses private. Duplicate finder flags clone pairs as "already deduplicated (0 B savings)". |
| Hard links | `ATTR_FILE_LINKCOUNT > 1` → dedupe by `(fsid, fileid)` in `linkedIdentities` | Counted once in rollups; deleting one link frees 0 B unless `linkCount == 1`; inspector shows "N links". |
| Sparse files | `EF_IS_SPARSE`; `allocated ≪ logical` | Never use logical for savings (Docker.raw case). |
| Firmlinks | Parse `/usr/share/firmlinks` at startup; `SF_FIRMLINK` flag on directories; `realpath` for user-provided roots; `ATTR_CMNEXT_NOFIRMLINKPATH` for display when needed | Canonical path = Data-volume path internally; display path = user-facing (e.g. `/Users/…`). Dedupe by `(fsid, fileid)`; `/private/var/folders` counted once. |
| Mount points | `ATTR_DIR_MOUNTSTATUS & DIR_MNTSTATUS_MNTPOINT`, `st_dev` change, `getmntinfo_r_np` table | Boundaries are leaf entries with the mounted volume's `statfs` usage; deletion across a boundary is refused by `PathGuard` (EC-09). |
| Purgeable | `URLResourceValues.volumeAvailableCapacityForImportantUsageKey` − `volumeAvailableCapacityKey` ≈ purgeable; per-file `NSURLIsPurgeableKey`/`EF_IS_PURGEABLE` | Shown as its own segment; excluded from "reclaimable"; "Purge now" delegates to the OS (no API) with explanation. |
| Local snapshots | `tmutil listlocalsnapshots /` (no root) | Listed in Dashboard with age; deletion via helper excluding `com.apple.os.update-*` (REQ-TM-1). |
| Freed-space truth | `statfs("/System/Volumes/Data").f_bavail * f_bsize` before/after with settle loop (poll every 250 ms up to 3 s until stable) | Ledger stores `estimatedBytes` and `measuredFreedBytes`; UI shows measured. |
| Units | Bytes internally (`UInt64`); display via `ByteCountFormatter` `.file` (decimal, matches Finder/Settings) | Tooltip shows exact bytes and binary (GiB) for engineers. |
| Compressed files | `UF_COMPRESSED` (HFS+/APFS transparent compression) | Allocated already reflects compression; badge in inspector. |
| Data volume capacity | `statfs("/System/Volumes/Data")` `f_blocks*f_bsize` | "Disk" numbers derived from the Data volume; System volume usage from `statfs("/")` (`f_blocks - f_bfree`). |

### 2.8 Volume topology

`actor VolumeTopology` builds at startup and on `NSWorkspace.didMountNotification`/`didUnmountNotification`:

```swift
struct VolumeInfo: Sendable, Hashable {
    let id: UInt8                 // index
    let fsid: fsid_t
    let device: dev_t
    let mountPoint: String        // e.g. "/System/Volumes/Data"
    let fsType: String            // "apfs", "smbfs", ...
    let flags: UInt32             // statfs.f_flags (MNT_LOCAL, MNT_RDONLY, MNT_DONTBROWSE, MNT_ROOTFS)
    let role: VolumeRole          // .system, .data, .preboot, .vm, .recovery, .simulatorRuntime, .diskImage, .external, .network, .other
    let total: UInt64, free: UInt64, availableImportant: UInt64, availableOpportunistic: UInt64
    let diskName: String?         // via DiskArbitration DADiskCopyDescription (kDADiskDescriptionVolumeNameKey)
    let isBootContainer: Bool
}
```

Role inference: mount point prefixes (`/System/Volumes/*`), `MNT_ROOTFS`, DiskArbitration `kDADiskDescriptionMediaContentKey`/`DeviceModel` ("Disk Image"), path prefix `/Library/Developer/CoreSimulator/` → `.simulatorRuntime`. Only `.data` is scanned by default; `.system` is sized via `statfs` only; `.simulatorRuntime` and `.diskImage` inside the Data tree appear as boundaries with their own sizes and are handled exclusively by tool rules.

### 2.9 Permissions and privilege escalation

#### 2.9.1 Full Disk Access (TCC) detection

There is no public API to query TCC state; use a deterministic probe set executed at launch and after returning from System Settings:

```swift
enum FDAStatus: Sendable { case granted, denied, undetermined }
struct PermissionProbe {
    static let probes: [String] = [
        "/Library/Application Support/com.apple.TCC/TCC.db",           // root-owned, readable only with FDA
        NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
        NSHomeDirectory() + "/Library/Safari/Bookmarks.plist",           // TCC-protected app data
        NSHomeDirectory() + "/Library/Mail",                             // directory listing probe
    ]
    func run() -> FDAStatus   // open(O_RDONLY|O_NOFOLLOW) / opendir; EPERM ⇒ denied; success ⇒ granted;
                              // ENOENT ignored; majority of decidable probes wins; all ENOENT ⇒ .undetermined
}
```

Rules: `EPERM` (1) = policy denial (TCC/SIP/data vault); `EACCES` (13) = POSIX permission — the UI distinguishes them (EC-03/EC-04). Onboarding opens `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` via `NSWorkspace.shared.open`, shows a drag-and-drop hint (the app's own URL is exposed as a draggable `NSItemProvider`), polls the probe every 2 s while the sheet is visible, and **requires relaunch** after a grant (TCC decisions are cached per process); the sheet offers "Relaunch now" (`NSWorkspace.openApplication(at:configuration:)` + `NSApp.terminate`). Without FDA, scanning proceeds but directories returning `EPERM` are recorded as `.unreadable(errno: EPERM)` and the dashboard shows an "Unscanned (needs Full Disk Access)" segment.

#### 2.9.2 SIP and BSD flags

- `SF_RESTRICTED` on an entry or any ancestor → immutable, never offered.
- `UF_IMMUTABLE`/`SF_IMMUTABLE` → "locked"; user-tier can clear `UF_IMMUTABLE` via `chflags` **only** after explicit confirmation per item; `SF_IMMUTABLE` requires root and is not offered.
- `UF_DATAVAULT` → EPERM even for root without entitlement; never offered.
- `csrutil status` is not consulted; flags are authoritative.

#### 2.9.3 When root is required

| Operation | Why root | Helper op |
|-----------|----------|-----------|
| Delete Time Machine local snapshots | `tmutil deletelocalsnapshots` requires root | `deleteLocalSnapshots(names:)` |
| Delete `/Library/Caches/*`, `/Library/Logs/DiagnosticReports/*`, `/private/var/log/asl/*.asl` | root-owned | `removeRootOwned(items:)` restricted to allowlisted prefixes |
| Delete `/Users/Deleted Users/<name>` | `root:admin 0770` dir; mixed ownership | `removeDeletedUserHome(name:)` |
| Delete unreferenced Cryptex simulator bundles | root-owned | `removeCryptexBundle(uuid:)` after `simctl runtime list -j` confirms no owner |
| Remove legacy `/usr/local` Homebrew prefix | root-owned subtrees | `removeLegacyHomebrewPrefix(paths:)` with per-path identity |
| `chflags noschg` | root | not offered |

Everything else (all of `~`, `/Applications` user-writable items, Docker.raw, AVDs, simulators via `simctl`) runs in the user process.

#### 2.9.4 Helper implementation (SMAppService + XPC)

- Bundle layout: `Reclaim.app/Contents/Library/LaunchDaemons/com.olawale.reclaim.helper.plist` and `Reclaim.app/Contents/MacOS/ReclaimHelper`.
- Plist keys: `Label = com.olawale.reclaim.helper`, `BundleProgram = Contents/MacOS/ReclaimHelper`, `MachServices = { "com.olawale.reclaim.helper": true }`, `AssociatedBundleIdentifiers = ["com.olawale.reclaim"]`, `ProcessType = Adaptive`.
- Registration: `let svc = SMAppService.daemon(plistName: "com.olawale.reclaim.helper.plist"); try svc.register()`; handle `svc.status`: `.requiresApproval` → `SMAppService.openSystemSettingsLoginItems()` with instructions; `.enabled` → connect; `.notFound` → bundle corrupted (reinstall).
- Connection (app side): `NSXPCConnection(machServiceName: label, options: .privileged)`, `remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)`, `interruptionHandler`/`invalidationHandler` reset state; every call has a 30 s timeout wrapper.
- Client validation (helper side) in `listener(_:shouldAcceptNewConnection:)`: `newConnection.setCodeSigningRequirement("anchor apple generic and identifier \"com.olawale.reclaim\" and certificate leaf[subject.OU] = \"TEAMID\"")` (macOS 13+); additionally the helper checks `newConnection.processIdentifier`'s audit token via `SecCodeCopyGuestWithAttributes(kSecGuestAttributeAudit)` + `SecCodeCheckValidity` against the same requirement (defense in depth), and refuses if `processIdentifier` is not a GUI session process of the console user (`SCDynamicStoreCopyConsoleUser`).
- Helper never receives free-form shell; every op takes typed arguments and re-validates: path canonicalization, allowlist prefix match, `(dev, ino)` identity equality with the client's claim, no symlink components (walk with `openat(O_NOFOLLOW)`), not a mount point, not `SF_RESTRICTED`. Helper writes its own ledger rows via XPC reply (the app persists) **and** appends to `/var/log/reclaim-helper.log` (rotated).
- Versioning: `HelperProtocol.version(reply:)` returns `HelperVersion(semver, protocolVersion)`; app refuses mismatched protocol and re-registers (SMAppService updates the daemon when the bundle changes).
- Uninstall: Settings → "Remove privileged helper" → `svc.unregister()`.

#### 2.9.5 Helper allowlist (compile-time constant, tested)

```swift
enum HelperAllowlist {
    static let rootDeletePrefixes = [
        "/Library/Caches/", "/Library/Logs/DiagnosticReports/", "/private/var/log/asl/",
        "/Users/Deleted Users/", "/Library/Developer/CoreSimulator/Cryptex/Images/bundle/",
        "/usr/local/Cellar/", "/usr/local/opt/", "/usr/local/Homebrew/", "/usr/local/var/homebrew/",
    ]
    static let snapshotNameDenyPrefixes = ["com.apple.os.update-"]
}
```

Any path outside these prefixes is rejected with `HelperError.notAllowlisted` regardless of client claims.

### 2.10 External tool orchestration

`actor ToolRunner` executes `Foundation.Process` with: absolute executable paths resolved by `ToolLocator` from a fixed candidate list (never `$PATH`, never a shell), arguments as arrays, `environment` reduced to `PATH=/usr/bin:/bin:/usr/sbin:/sbin` plus tool-specific vars (`HOME`, `ANDROID_HOME`, `DOCKER_HOST` if configured), stdout/stderr captured to memory with a 32 MiB cap, timeout via `Task` cancellation + `SIGTERM` then `SIGKILL`, and structured parsing.

| Tool | Candidates | Machine-readable mode | Used for |
|------|-----------|-----------------------|----------|
| `xcrun simctl` | `/usr/bin/xcrun` | `simctl list -j`, `simctl runtime list -j` | runtimes, devices, delete |
| `tmutil` | `/usr/bin/tmutil` | `listlocalsnapshots /` (line-oriented, stable), `deletelocalsnapshots <name>` (helper) | snapshots |
| `docker` | `/usr/local/bin/docker`, `/opt/homebrew/bin/docker`, `~/.docker/bin/docker`, `/Applications/Docker.app/Contents/Resources/bin/docker` | `system df --format '{{json .}}'`, `volume ls --format json`, `image ls --format json`, `builder du`? (text) | usage, prune |
| `brew` | `/opt/homebrew/bin/brew`, `/usr/local/bin/brew` | `--cache` (path), `cleanup --prune=all -n` (dry run text) | cache cleanup |
| `avdmanager` | `$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager`, `~/Library/Android/sdk/cmdline-tools/latest/bin/avdmanager` | `list avd -c` (compact) | AVD delete (fallback: direct `.avd`+`.ini` deletion) |
| `qlmanage` | `/usr/bin/qlmanage` | `-r cache` | QuickLook thumbnail cache reset |
| `git` | `/usr/bin/git` (CLT shim), `/opt/homebrew/bin/git` | `status --porcelain=v2 -z`, `log -1 --format=%ct` | project activity |
| `npm`/`yarn`/`pnpm` | `~/.nvm/versions/node/*/bin/*`, `/opt/homebrew/bin/*`, `/usr/local/bin/*`, `~/.bun/bin/bun` | `cache clean --force` / `cache clean` / `store prune` | optional; default is direct store directory deletion |
| `ollama` | `/usr/local/bin/ollama`, `/Applications/Ollama.app/Contents/Resources/ollama` | `list` (table) | model inventory for `~/.ollama/models` |

Each adapter has a protocol (`SimctlAdapting`, `DockerAdapting`, …) with a fake implementation in `ReclaimTestSupport` so rules are tested without the tools.

### 2.11 Persistence

SQLite (`ledger.sqlite`, `PRAGMA journal_mode=WAL; foreign_keys=ON; synchronous=NORMAL`), opened by `actor SQLiteDatabase` (one connection, serialized). Full DDL in Appendix C. Tables: `schema_version`, `scans`, `operations`, `operation_items`, `rule_runs`, `settings_kv`, `watch_baselines`, `duplicate_groups`. Snapshot files are referenced by `scans.snapshot_path`; the catalog keeps the last 5 snapshots (configurable) and prunes older ones.

### 2.12 Performance budgets

| Scenario | Budget | Measured in |
|----------|--------|-------------|
| Fixture 2 M entries / 200 k dirs, warm cache | ≤ 6.0 s scan on the author's M3 Pro (stretch 3.0 s), ≤ 15 s on the macos-15 CI runner, ≤ 300 MB peak RSS; `bulk` ≥ 5× `FileManager` | Phase 1 `T1-BENCH-2M` (ADR-016). Phase 0's 3.0 s / 10× figures are historical. |
| Same, cold (after `purge` run by CI script, requires admin → local only) | ≤ 10 s | local |
| Author's machine full Data volume (~3–5 M entries) | ≤ 25 s cold, ≤ 8 s warm | local |
| Snapshot load (3 M entries) | ≤ 1.0 s | T1-SNAP-LOAD |
| Treemap layout for 10 k nodes | ≤ 16 ms per level change (off-main) | T4-TREEMAP-LAYOUT |
| Children page (sorted by allocated) for a dir with 200 k children | ≤ 50 ms | T1-INDEX-SORT |
| Duplicate prefilter (size + 8 KiB fingerprint) for 100 k candidates | ≤ 20 s | T3-DUP-PREFILTER |
| Trash 100 k items | ≤ 60 s, UI responsive | T2-TRASH-BULK |

### 2.13 Error model and diagnostics

- Errors are typed enums per layer (`FSError`, `GuardError`, `DeletionError`, `ToolError`, `HelperError`, `RuleError`), each carrying `errno`/exit codes and the **canonical path** (redacted in logs unless "verbose diagnostics" is enabled).
- `OperationReport` aggregates results per item and summarizes by `errno` (EC-04/EC-26).
- "Export diagnostics" writes a zip with: `settings.json`, last 3 scan summaries (no paths unless opted in), ledger excerpt, tool versions (`simctl`, `docker`, `brew`), FDA/helper status, `sw_vers`, `system_profiler SPStorageDataType -json`.

### 2.14 Architecture Decision Records (summaries)

| ADR | Decision | Alternatives rejected |
|-----|----------|------------------------|
| ADR-001 | Non-sandboxed Developer ID app | MAS sandbox blocks FDA-wide scanning, helper, `fts` on arbitrary paths. |
| ADR-002 | `getattrlistbulk` primary, `fts` fallback | `FileManager` (10–50× slower), `readdir+lstat` (per-file syscalls). |
| ADR-003 | Raw SQLite over SwiftData/GRDB | CLI access, WAL durability, zero migration surprises; GRDB is excellent but adds a dependency. |
| ADR-004 | Swift Testing + XCTest perf | XCTest-only lacks parameterized tests; Swift Testing lacks `measure`. |
| ADR-005 | Tools via `Process` with absolute paths and JSON | Shell interpolation caused EC-01/EC-11. |
| ADR-006 | Decimal units everywhere | Matches Finder/Settings; avoids EC-24 confusion. |
| ADR-007 | macOS 14 minimum | `@Observable`, modern SMAppService behaviors. |
| ADR-008 | No telemetry | Trust; a disk cleaner must not phone home. |
| ADR-009 | Trash tier default, permanent opt-in | Undo matters more than instant space. |
| ADR-010 | Main app hosts the menu bar monitor (activation policy switch) | Separate LaunchAgent adds a second TCC subject and update complexity; revisit in v2. |

---

## 3. STEP 3 — Cleaning Rules Engine

### 3.1 Concepts

| Concept | Definition |
|---------|------------|
| **Rule** | A `Sendable` value conforming to `CleanRule` with a stable `RuleID` (`"<domain>.<area>.<name>"`, e.g. `dev.xcode.derived-data`), metadata, a *locator* (how candidates are found in the index), *eligibility predicates*, an *action*, a *risk tier*, *owner bundle IDs*, and *regeneration* text. |
| **Candidate** | An `EntryID` (or tool-managed object such as a simulator runtime) produced by the locator. |
| **Finding** | The evaluated result: items that passed eligibility, sizes (`SizeTriple` + `privateReclaimable`), blockers (e.g. app running, git dirty), and explanations. |
| **Plan** | User-selected findings + `DeletionTier` + per-item overrides, persisted before execution. |
| **Action** | `.trash`, `.unlinkInPlace` (for paths Trash cannot handle or when the user picks permanent), `.tool(ToolInvocation)` (e.g. `simctl runtime delete`), `.helper(HelperRequest)`. |
| **Risk tier** | `safe` (regenerable cache; auto-selected in Smart Clean), `low` (regenerable but costs time/bandwidth: simulator runtimes, model weights), `medium` (user content that is probably redundant: archives, old downloads, duplicates), `high` (destructive to state: Docker.raw, named volumes, AVDs, MySQL data). |
| **Category** | Dashboard attribution bucket (§5.2). Each rule declares its category. |

### 3.2 Core protocols and types (ReclaimRules)

```swift
public struct RuleID: RawRepresentable, Hashable, Sendable, Codable { public let rawValue: String }

public enum RiskTier: Int, Sendable, Codable, Comparable { case safe = 0, low, medium, high }

public enum Category: String, Sendable, Codable, CaseIterable {
    case macOS, applications, developer, appData, caches, messagingMedia, documentsMedia,
         otherUsers, trash, snapshots, purgeable, unscanned, free
}

public struct RuleMetadata: Sendable, Codable {
    public let id: RuleID
    public let title: String                 // "Xcode DerivedData"
    public let summary: String               // one sentence
    public let rationale: String             // why it is safe/unsafe (shown in inspector)
    public let regeneration: String          // "Recreated automatically on next build."
    public let risk: RiskTier
    public let category: Category
    public let ownerBundleIDs: [String]      // apps that must not be running for safe deletion
    public let requiresHelper: Bool
    public let defaultEnabledInSmartClean: Bool
    public let documentationURL: URL?
    public let sourceNotes: String           // provenance, e.g. "S4 2026-09-03: 9.7 GB freed"
}

public enum Locator: Sendable, Codable {
    case paths([PathTemplate])                        // e.g. "~/Library/Developer/Xcode/DerivedData"
    case indexQuery(IndexQuery)                       // name == "node_modules" && depthFilter && !insideNodeModules
    case glob(root: PathTemplate, pattern: String)    // bounded glob evaluated against the index, not the shell
    case tool(ToolInventory)                          // simctl runtimes, docker volumes, AVDs
    case composite([Locator])
}

public struct PathTemplate: Sendable, Codable, Hashable {   // "~/", "$ANDROID_HOME/", "$TMPDIR/" expansions only
    public let template: String
    public func resolve(in env: RuleEnvironment) -> [String]
}

public indirect enum Predicate: Sendable, Codable {
    case olderThan(days: Int, clock: TimeBasis)                 // .mtime, .projectActivity
    case largerThan(bytes: UInt64, basis: SizeBasis)            // .allocated, .privateBytes
    case parentContains(fileNamed: String)                      // "Cargo.toml", "package.json"
    case notInsideAncestorNamed(String)                         // "node_modules"
    case projectInactive(days: Int)                             // §4.2
    case gitClean                                               // §4.2
    case appNotRunning                                          // uses metadata.ownerBundleIDs
    case notMountPoint
    case kind(EntryKind)
    case nameMatches(Regex)                                     // Swift Regex literal, anchored
    case custom(id: String)                                     // implemented in Swift, registered by name
    case all([Predicate]), any([Predicate]), not(Predicate)
}

public enum RuleAction: Sendable, Codable {
    case trash
    case unlinkInPlace
    case tool(ToolInvocation)
    case helper(HelperRequest)
    case reportOnly
}

public protocol CleanRule: Sendable {
    var metadata: RuleMetadata { get }
    var locator: Locator { get }
    var eligibility: Predicate { get }
    var action: RuleAction { get }
    /// Optional hook for rules needing extra I/O (SQLite name resolution, tool inventory, hashing).
    func enrich(_ finding: inout Finding, context: RuleContext) async throws
}

public struct FindingItem: Sendable, Codable, Identifiable {
    public let id: UUID
    public let entry: EntryID?                 // nil for tool-managed objects
    public let displayPath: String
    public let canonicalPath: String
    public let identity: FileIdentity?         // (dev, ino) captured at scan
    public let sizes: SizeTriple               // logical, allocated, privateBytes
    public let kind: EntryKind
    public let label: String?                  // e.g. resolved WhatsApp chat name, simulator name
    public let detail: String?                 // e.g. "last used 2025-11-17", "10 GB sdcard"
    public let action: RuleAction
    public let blockers: [Blocker]
}

public enum Blocker: Sendable, Codable, Hashable {
    case appRunning(bundleID: String, name: String)
    case openByProcesses([ProcessRef])
    case gitDirty(repo: String)
    case recentlyActive(days: Int)
    case protectedPath(reason: String)
    case needsFullDiskAccess
    case needsHelper
    case mountPoint
    case immutable(flags: UInt32)
}

public struct Finding: Sendable, Codable, Identifiable {
    public let id: UUID
    public let rule: RuleMetadata
    public var items: [FindingItem]
    public var totalAllocated: UInt64
    public var totalPrivateReclaimable: UInt64
    public var notes: [String]
    public var isEmpty: Bool { items.isEmpty }
}

public struct RuleContext: Sendable {
    public let index: FileIndexReader          // Sendable read-only view (snapshot) of FileIndex
    public let env: RuleEnvironment            // home, ANDROID_HOME, TMPDIR, DARWIN_USER_CACHE_DIR, installed apps
    public let tools: ToolAdapters             // simctl, docker, brew, tmutil, avdmanager, git, qlmanage, ollama
    public let activity: ProjectActivityOracle
    public let apps: AppRegistryReader
    public let processes: ProcessInspecting
    public let now: Date
}

public actor RuleRegistry {
    public func register(_ rule: any CleanRule) throws        // duplicate IDs rejected
    public func rules(in category: Category?) -> [any CleanRule]
    public func evaluateAll(context: RuleContext, progress: @Sendable (RuleProgress) -> Void) async -> [Finding]
    public func evaluate(_ id: RuleID, context: RuleContext) async throws -> Finding
    public func loadUserRules(from url: URL) throws            // JSON (§3.3), validated against schema
}
```

`RuleRegistry.evaluateAll` runs rules concurrently (`TaskGroup`, max 6 concurrent; tool-backed rules serialized per tool) and returns findings sorted by `totalPrivateReclaimable` descending. A rule's `locator` executes against the `FileIndexReader` (pure in-memory, microseconds to milliseconds); `enrich` is the only place for additional I/O and runs with a per-rule 20 s timeout.

### 3.3 Declarative DSL and user rules (JSON)

Built-in rules are Swift values (type-checked). The same shape is exposed as JSON so users can add simple rules (`~/Library/Application Support/Reclaim/rules.user.json`, schema in Appendix D). Example:

```json
{
  "id": "user.cache.my-app",
  "title": "MyApp render cache",
  "summary": "Thumbnails cached by MyApp",
  "rationale": "MyApp regenerates thumbnails lazily.",
  "regeneration": "Rebuilt when images are opened again.",
  "risk": "safe",
  "category": "caches",
  "ownerBundleIDs": ["com.example.myapp"],
  "locator": { "paths": ["~/Library/Caches/com.example.myapp/thumbs"] },
  "eligibility": { "all": [ { "appNotRunning": {} }, { "olderThan": { "days": 7, "clock": "mtime" } } ] },
  "action": "trash"
}
```

User rules cannot: target protected prefixes (§4.1), use `unlinkInPlace`/`helper`/`tool` actions, or set `risk` below `low`. Validation errors are shown in Settings → Rules.

### 3.4 Rule catalog

Columns: **Locator** (path templates or index query), **Eligibility** (predicates beyond the universal guards of §4), **Action**, **Risk**, **Smart Clean default** (✓ = auto-selected), **Owner apps**, **Provenance** (session evidence).

#### 3.4.1 System & app junk

| Rule ID | Locator | Eligibility | Action | Risk | SC | Owner apps | Provenance |
|---------|---------|-------------|--------|------|----|------------|------------|
| `sys.caches.user` | `~/Library/Caches/*` children, excluding `ProtectedCacheNames` (`com.apple.*` system caches are **listed but off by default**: `SiriTTS`, `GeoServices`, `com.apple.helpd`, `com.apple.e5rt.*`, `com.apple.ap.adprivacyd`, `CloudKit`, `com.apple.nsurlsessiond`, `com.apple.Safari*`) | `appNotRunning` where the folder name maps to an installed bundle ID; otherwise unconditional | trash | safe | ✓ (third-party only) | folder→bundle via `AppRegistry` | S2/S4/S5: 4–15 GB |
| `sys.caches.system` | `/Library/Caches/*` | — | helper `removeRootOwned` | safe | ✗ | — | S1 recommendation |
| `sys.caches.tmp-user` | `$DARWIN_USER_CACHE_DIR/*`, `$TMPDIR/*` (`/private/var/folders/…/C`, `…/T`) | `olderThan(3d, .mtime)`, excludes `com.apple.*`, sockets, `.lock` | unlinkInPlace (Trash unsupported here) | low | ✗ | — | S2: 3.5 GB observed |
| `sys.logs.user` | `~/Library/Logs/**` files | `olderThan(14d)`, `nameMatches(\.(log|gz|bz2|\d+)$)` | trash | safe | ✓ | — | S5: 1.0 GB |
| `sys.logs.diagnostic-reports` | `~/Library/Logs/DiagnosticReports/*`, `/Library/Logs/DiagnosticReports/*` (helper) | `olderThan(7d)` | trash / helper | safe | ✓ (user part) | — | — |
| `sys.logs.asl` | `/private/var/log/asl/*.asl` | `olderThan(7d)` | helper | safe | ✗ | — | S1 |
| `sys.quicklook.thumbnails` | tool: `qlmanage -r cache` | — | tool | safe | ✓ | — | S1 |
| `sys.trash.user` | `~/.Trash/*`, `/Volumes/*/.Trashes/<uid>/*` | — | unlinkInPlace | safe | ✓ | — | S1: 673 MB |
| `sys.snapshots.timemachine-local` | tool: `tmutil listlocalsnapshots /` minus `com.apple.os.update-*` | — | helper `deleteLocalSnapshots` | low | ✗ | — | S1–S5 listing |
| `sys.purgeable.report` | volume stats | — | reportOnly | — | — | — | EC-07 |
| `sys.ios-backups` | `~/Library/Application Support/MobileSync/Backup/*` | `olderThan(180d)` | trash | high | ✗ | `com.apple.FinderSync`? n/a | S1 check |
| `sys.mail-downloads` | `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/*` | `olderThan(30d)` | trash | low | ✗ | `com.apple.mail` | — |
| `sys.font-caches`/`sys.icon-services` | **not included** (system-managed, regenerate expensively) | | | | | | |
| `sys.deleted-users` | `/Users/Deleted Users/*` | directory | helper `removeDeletedUserHome` | medium | ✗ | — | S5: 31 GB |
| `sys.swap.report` | `/private/var/vm` | — | reportOnly | — | — | — | EC: never touch |

**Browser caches (scoped, EC/B8):**

| Rule ID | Locator (relative to profile dirs) | Owner |
|---------|-------------------------------------|-------|
| `app.browser.chrome` | `~/Library/Caches/Google/Chrome/*/{Cache,Code Cache,GPUCache}`, `~/Library/Application Support/Google/Chrome/*/{Cache,Code Cache,GPUCache,DawnCache,GrShaderCache,Service Worker/CacheStorage,Service Worker/ScriptCache}` | `com.google.Chrome` |
| `app.browser.brave` | same layout under `BraveSoftware/Brave-Browser` | `com.brave.Browser` |
| `app.browser.arc` | `~/Library/Caches/company.thebrowser.Browser`, `Application Support/Arc/User Data/*/{Cache,Code Cache,GPUCache}` | `company.thebrowser.Browser` |
| `app.browser.firefox` | `~/Library/Caches/Firefox/Profiles/*/cache2`, `~/Library/Caches/Mozilla/*` | `org.mozilla.firefox` |
| `app.browser.safari` | **report only** (`~/Library/Caches/com.apple.Safari` is TCC-protected and Safari manages it) | — |

Protected inside browser dirs (never offered): `Login Data*`, `Cookies*`, `History*`, `Bookmarks*`, `Web Data*`, `Preferences`, `Local State`, `Extensions`, `Sessions`, `places.sqlite`, `key4.db`, `logins.json`, `cert9.db`.

**Electron/Squirrel/Sparkle updater staging:**

| Rule ID | Locator | Eligibility | Risk |
|---------|---------|-------------|------|
| `app.updater.shipit` | `~/Library/Caches/*.ShipIt` (`com.todesktop.230313mzl4w4u92.ShipIt`, `com.anthropic.claudefordesktop.ShipIt`, `com.postmanlabs.*.ShipIt`, `com.hnc.Discord.ShipIt`, `com.figma.Desktop.ShipIt`, `com.electron.kontena-lens.ShipIt`, `com.google.antigravity.ShipIt`, …) and `~/Library/Caches/lens-desktop-updater` | `appNotRunning` (bundle = name minus `.ShipIt`), `olderThan(1d)` (an update may be mid-download) | safe ✓ |
| `app.updater.sparkle` | `~/Library/Caches/<bundle>/org.sparkle-project.Sparkle/Installation/*` | `appNotRunning`, `olderThan(1d)`; retry policy REQ-DEL-2 for read-only dirs | safe ✓ |
| `app.updater.self-exclusion` | Reclaim's own Sparkle cache is excluded (`com.olawale.reclaim`) | | |

**Electron app caches (generic):**

| Rule ID | Locator | Risk |
|---------|---------|------|
| `app.electron.caches` | `~/Library/Application Support/<App>/{Cache,Code Cache,GPUCache,DawnCache,GraphiteDawnCache,DawnGraphiteCache,DawnWebGPUCache,ShaderCache,CachedData,CachedProfilesData,CachedExtensionVSIXs,logs,blob_storage}` and `Partitions/*/{Cache,Code Cache,GPUCache}` for apps detected by presence of `Local State` or `Preferences` + `Network Persistent State`; apps observed: Cursor, Code, Claude, discord, Postman, Insomnia, Slack, Figma, Lens, Asana, zoom.us, Warp, TikTok LIVE Studio, stremio-server, Arc | safe ✓ (`appNotRunning` required) |

**Editors (Cursor / VS Code / forks):**

| Rule ID | Locator | Eligibility | Action | Risk |
|---------|---------|-------------|--------|------|
| `app.editor.state-backup` | `~/Library/Application Support/{Cursor,Code,Code - Insiders,VSCodium,Windsurf}/User/globalStorage/state.vscdb.backup` | — | trash | safe ✓ |
| `app.editor.orphan-workspaces` | `…/User/workspaceStorage/<hash>` where `workspace.json` has `folder`/`workspace` URI whose path does not exist (`access(F_OK)`), or no `workspace.json` and `olderThan(90d)` | `appNotRunning` | trash | safe ✓ |
| `app.editor.live-state-report` | `…/User/globalStorage/state.vscdb` (+`-wal`) | — | reportOnly with guidance ("Cursor › Settings › Clear chat history") | — |
| `app.editor.history` | `…/User/History/*` | `olderThan(90d)` | trash | low ✗ |
| `app.editor.cached-vsix` | `…/CachedExtensionVSIXs/*` | `appNotRunning` | trash | safe ✓ |

**AI desktop apps:**

| Rule ID | Locator | Eligibility | Risk |
|---------|---------|-------------|------|
| `app.claude.vm-bundle` | `~/Library/Application Support/Claude/vm_bundles/claudevm.bundle`, `vm_bundles/warm/*` | `appNotRunning(com.anthropic.claudefordesktop)` | low ✓ (shown with "re-downloaded/rebuilt on next sandboxed run", 9–11 GB) |
| `app.claude.caches` | covered by `app.electron.caches` (`Cache`, `Code Cache`, `claude-code-vm` excluded) | | |
| `app.ollama.models` | `~/.ollama/models/**` via `ollama list` inventory | `olderThan(60d, .atime|.mtime)` per model manifest | low ✗ |
| `ai.huggingface.hub` | `~/.cache/huggingface/hub/models--*` | `olderThan(60d)` | low ✗ |
| `ai.torch.cache` | `~/.cache/torch/hub/checkpoints/*` | `olderThan(60d)` | low ✗ |

#### 3.4.2 Orphan detection (uninstalled apps)

`AppRegistry` (actor) builds the set of installed bundle IDs from: `/Applications/**` (depth ≤ 3), `~/Applications`, `/System/Applications`, `/Library/Apple/System/Library/CoreServices`, plus `LSCopyApplicationURLsForBundleIdentifier` for each candidate, plus running apps, plus `~/Library/Containers/*/Container.plist` → `MCMMetadataIdentifier`. Orphan rules:

| Rule ID | Locator | Orphan test | Risk |
|---------|---------|-------------|------|
| `app.orphan.containers` | `~/Library/Containers/<bundle or UUID>` | `Container.plist` identifier not installed **and** `olderThan(30d)`; UUID-named containers resolved via plist | medium ✗ |
| `app.orphan.group-containers` | `~/Library/Group Containers/<team.group>` | no installed app declares the group (from `embedded.provisionprofile`/`Info.plist` not reliable → heuristic: no installed bundle shares the group suffix) **and** `olderThan(60d)` | medium ✗ |
| `app.orphan.application-support` | `~/Library/Application Support/<name>` | name maps to a bundle ID (via `CFBundleName` index or reverse-DNS name) not installed; `olderThan(60d)` | medium ✗ |
| `app.orphan.preferences` | `~/Library/Preferences/<bundle>.plist` | bundle not installed; `olderThan(60d)`; never `com.apple.*`, `.GlobalPreferences`, `loginwindow` | low ✗ |
| `app.orphan.saved-state` | `~/Library/Saved Application State/<bundle>.savedState` | bundle not installed | safe ✓ |
| `app.orphan.caches` | `~/Library/Caches/<bundle>` | bundle not installed | safe ✓ |
| `app.orphan.launch-agents` | `~/Library/LaunchAgents/<bundle>.plist` | program path missing | low ✗ (report; never auto) |

#### 3.4.3 Developer & AI bloat

**Xcode / Apple platforms**

| Rule ID | Locator | Eligibility | Action | Risk | SC |
|---------|---------|-------------|--------|------|----|
| `dev.xcode.derived-data` | `~/Library/Developer/Xcode/DerivedData/*` (per project dir) | `appNotRunning(com.apple.dt.Xcode)` or per-project `olderThan(7d)` while Xcode runs | trash | safe | ✓ |
| `dev.xcode.device-support` | `~/Library/Developer/Xcode/{iOS,watchOS,tvOS,visionOS} DeviceSupport/*` | keep newest version per major by default; others eligible | trash | safe | ✓ (keep-latest) |
| `dev.xcode.archives` | `~/Library/Developer/Xcode/Archives/*/*.xcarchive` | `olderThan(180d)` | trash | medium | ✗ |
| `dev.xcode.previews` | `~/Library/Developer/Xcode/UserData/Previews/Simulator Devices/*` | `appNotRunning` | trash | safe | ✓ |
| `dev.xcode.simulator-caches` | `~/Library/Developer/CoreSimulator/Caches/*` | — | trash | safe | ✓ |
| `dev.xcode.simulator-unavailable` | tool: `simctl list devices unavailable -j` | — | tool `simctl delete unavailable` | safe | ✓ |
| `dev.xcode.simulator-device-data` | `~/Library/Developer/CoreSimulator/Devices/<UDID>/data` with `device.plist` `lastBootedAt` | `olderThan(60d, lastBooted)` | tool `simctl erase <UDID>` | low | ✗ |
| `dev.xcode.simulator-runtimes` | tool: `simctl runtime list -j` → runtimes; sizes from `/Library/Developer/CoreSimulator/Volumes/*` and `Images/*.dmg` | keep newest runtime per platform; older eligible; never the one used by any device booted in 30 d | tool `simctl runtime delete <build>` | low | ✗ (user picks) |
| `dev.xcode.cryptex-orphans` | `/Library/Developer/CoreSimulator/Cryptex/Images/bundle/*` not referenced by `simctl runtime list -j` and not a mount point | — | helper `removeCryptexBundle` | low | ✗ |
| `dev.xcode.ios-device-logs` | `~/Library/Logs/CoreSimulator/*` | `olderThan(14d)` | trash | safe | ✓ |

**Node / JavaScript**

| Rule ID | Locator | Eligibility | Action | Risk | SC |
|---------|---------|-------------|--------|------|----|
| `dev.node.node-modules` | index query: `name == "node_modules" && kind == .directory && !insideAncestorNamed("node_modules")` under scan roots (`~/work`, `~/projects`, `~/Developer`, `~/Sites`, `~/Documents`, custom) | `parentContains("package.json")`, `projectInactive(90d)`, `gitClean` or no git | trash | safe | ✓ |
| `dev.node.framework-outputs` | names `.next`, `.nuxt`, `.turbo`, `.parcel-cache`, `.cache` (only when sibling `package.json`), `.vite`, `.svelte-kit`, `.angular`, `.expo`, `storybook-static`, `.docusaurus` | `projectInactive(30d)` | trash | safe | ✓ |
| `dev.node.dist` | `dist`, `build`, `out` with sibling `package.json` | `projectInactive(90d)`; **off by default** (may be source for some repos) | trash | low | ✗ |
| `dev.node.stores` | `~/.npm/_cacache`, `~/.npm/_logs`, `~/Library/Caches/Yarn`, `~/.yarn/berry/cache`, `~/.cache/yarn`, `~/Library/pnpm/store`, `~/.pnpm-store`, `~/.local/share/pnpm/store`, `~/.bun/install/cache`, `~/Library/Caches/node-gyp`, `~/Library/Caches/typescript`, `~/Library/Caches/deno`, `~/Library/Caches/hardhat-nodejs` | — | trash (or tool `npm cache clean --force` when user prefers) | safe | ✓ |
| `dev.node.playwright` | `~/Library/Caches/ms-playwright/*` | `olderThan(30d)` | trash | safe | ✓ |
| `dev.node.electron-builder` | `~/Library/Caches/electron`, `~/Library/Caches/electron-builder` | — | trash | safe | ✓ |

**Python / AI**

| Rule ID | Locator | Eligibility | Risk | SC |
|---------|---------|-------------|------|----|
| `dev.python.pip-cache` | `~/Library/Caches/pip`, `~/.cache/pip`, `~/.cache/uv`, `~/Library/Caches/pypoetry`, `~/.cache/pypoetry` | — | safe | ✓ |
| `dev.python.pycache` | `**/__pycache__` within project roots | `projectInactive(30d)` | safe | ✓ |
| `dev.python.venvs` | `.venv`, `venv`, `env` dirs containing `pyvenv.cfg` | `projectInactive(90d)` | low | ✗ |
| `dev.python.conda-pkgs` | `~/miniconda3/pkgs`, `~/anaconda3/pkgs`, `~/.conda/pkgs`, `~/mambaforge/pkgs` | — (`conda clean --all` equivalent) | safe | ✓ |
| `dev.python.jupyter-checkpoints` | `**/.ipynb_checkpoints` | — | safe | ✓ |

**Rust / Go / Java / Android / Flutter / PHP / Swift PM**

| Rule ID | Locator | Eligibility | Action | Risk | SC |
|---------|---------|-------------|--------|------|----|
| `dev.rust.target` | `target` dirs with sibling `Cargo.toml` (or `src-tauri/Cargo.toml` one level up) | `projectInactive(30d)` **or** `largerThan(5 GB)` (always surfaced) | trash | safe | ✓ |
| `dev.rust.cargo-cache` | `~/.cargo/registry/cache`, `~/.cargo/registry/src`, `~/.cargo/git/checkouts` | — | trash | safe | ✓ |
| `dev.go.caches` | `~/Library/Caches/go-build`, `~/go/pkg/mod/cache/download` | — | trash | safe | ✓ |
| `dev.go.mod-cache` | `~/go/pkg/mod` (excluding `cache`) | `olderThan(90d)` | trash (dirs are read-only: REQ-DEL-2 chmod retry) | low | ✗ |
| `dev.java.gradle` | `~/.gradle/caches/*`, `~/.gradle/wrapper/dists/*` (keep newest), `~/.gradle/daemon/*` logs | `appNotRunning(com.google.android.studio, com.jetbrains.intellij)` | trash | safe | ✓ |
| `dev.java.maven` | `~/.m2/repository` | `olderThan(180d)` per artifact dir | trash | low | ✗ |
| `dev.java.build-dirs` | `build`, `.gradle` with sibling `build.gradle(.kts)` or `settings.gradle(.kts)` | `projectInactive(30d)` | trash | safe | ✓ |
| `dev.android.avds` | tool: `avdmanager list avd -c` + `~/.android/avd/*.avd` (`config.ini`, `*.lock` absence) | `olderThan(60d, mtime of .avd dir)`; never when emulator process runs (`qemu-system-*`, `emulator`) | tool `avdmanager delete avd -n` (fallback: trash `.avd` + `.ini`) | high | ✗ |
| `dev.android.system-images` | `$ANDROID_HOME/system-images/<api>/<tag>/<abi>` | no AVD references it (`config.ini` `image.sysdir.1`) | trash | low | ✗ |
| `dev.android.sdk-temp` | `$ANDROID_HOME/.temp`, `~/.android/cache` | — | trash | safe | ✓ |
| `dev.flutter.caches` | `~/flutter/bin/cache/*` (keep `dart-sdk`), `~/sdk/flutter/bin/cache/*`, `~/.pub-cache/hosted/*/*` old versions, project `build/`, `.dart_tool/` | `projectInactive(30d)` for project dirs | trash | low | ✗ |
| `dev.php.composer-cache` | `~/Library/Caches/composer`, `~/.composer/cache`, `~/.cache/composer` | — | trash | safe | ✓ |
| `dev.php.vendor` | `vendor` with sibling `composer.json` | `projectInactive(90d)`, `gitClean` | trash | low | ✗ |
| `dev.php.laravel-storage-logs` | `storage/logs/*.log` with sibling `artisan` | `olderThan(30d)` | trash | safe | ✓ |
| `dev.swiftpm.caches` | `~/Library/Caches/org.swift.swiftpm`, `~/Library/org.swift.swiftpm`, project `.build` | `projectInactive(30d)` for `.build` | trash | safe | ✓ |
| `dev.homebrew.cache` | tool `brew --cache` → dir; `~/Library/Caches/Homebrew/*` | — | tool `brew cleanup --prune=all` (dry-run first with `-n`) | safe | ✓ |
| `dev.homebrew.legacy-prefix` | `/usr/local/{Cellar,opt,Homebrew}` when `/opt/homebrew` exists and `/usr/local/bin/brew` is absent or stale | report with per-formula sizes | helper | high | ✗ |
| `dev.cloud.aws-cache` | `~/Library/Caches/aws`, `~/.aws/cli/cache` | — | trash | safe | ✓ |
| `dev.misc.sdk-vendored` | directories matching `qt-*`, `*.xcframework` ≥ 1 GB outside `/Applications` | report | reportOnly | — | — |

**Docker / OrbStack / Colima**

| Rule ID | Locator | Eligibility | Action | Risk | SC |
|---------|---------|-------------|--------|------|----|
| `dev.docker.dangling` | tool: `docker system df`, `docker image ls -f dangling=true` | daemon running | tool `docker image prune -f` + `docker builder prune -f` | safe | ✓ (only if daemon running) |
| `dev.docker.unused-images` | `docker image ls` minus images used by containers | daemon running | tool `docker image prune -a -f` | low | ✗ |
| `dev.docker.volumes` | `docker volume ls -f dangling=true --format json` | daemon running; shows volume names (e.g. `mango-backend_sail-mysql 219.6 MB`) | tool `docker volume rm <names>` (never `prune -a` blindly) | high | ✗ |
| `dev.docker.raw-reset` | `~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw` (+ `~/Library/Containers/com.docker.docker/Data/vms/0/data/*.img`) | daemon **not** running; shows allocated vs logical; requires that the last known `docker system df` (cached ≤ 30 d) reported 0 images/containers/volumes **or** explicit "I understand this destroys all images/volumes" confirmation | unlinkInPlace | high | ✗ |
| `dev.docker.logs` | `~/Library/Containers/com.docker.docker/Data/log/**` | `olderThan(7d)` | trash | safe | ✓ |
| `dev.orbstack.data` | `~/.orbstack/data` report; `~/OrbStack` caches | report | reportOnly | — | — |
| `dev.colima.vm` | `~/.colima/*/colima.qcow2` report | report | reportOnly | — | — |

#### 3.4.4 Messaging media

| Rule ID | Locator | Enrichment | Eligibility | Action | Risk | SC |
|---------|---------|------------|-------------|--------|------|----|
| `msg.whatsapp.chat-media` | `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media/<JID>` where JID matches `^[0-9]+@(g\.us|lid|s\.whatsapp\.net)$` | `NameResolver`: copy `ChatStorage.sqlite{,-wal,-shm}` to temp (only when app not running), open `SQLITE_OPEN_READONLY`, `SELECT ZCONTACTJID, ZPARTNERNAME, ZLASTMESSAGEDATE FROM ZWACHATSESSION`; map `@lid` via `ZWAPROFILEPUSHNAME`/`LID.sqlite` best-effort | `appNotRunning(net.whatsapp.WhatsApp)`; user selects chats (sorted by allocated); default suggestion: chats ≥ 1 GB | trash | low | ✗ (suggested, not auto) |
| `msg.whatsapp.status-cache` | `…/Message/Media/*@lid.status`, `*@status` | count + total | `appNotRunning` | trash | safe | ✓ |
| `msg.whatsapp.db-report` | `ChatStorage.sqlite*`, `*.sqlite*` | — | reportOnly (protected) | — | — |
| `msg.telegram.media` | `~/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/appstore/account-*/postbox/media`, `~/Library/Containers/ru.keepcoder.Telegram/Data/Library/Caches/*` | — | `appNotRunning(ru.keepcoder.Telegram)` | trash | safe | ✓ |
| `msg.slack.cache` | `~/Library/Application Support/Slack/{Cache,Code Cache,Service Worker}` (also via electron rule) | — | `appNotRunning(com.tinyspeck.slackmacgap)` | trash | safe | ✓ |
| `msg.discord.cache` | `~/Library/Application Support/discord/{Cache,Code Cache,GPUCache}` | — | `appNotRunning(com.hnc.Discord)` | trash | safe | ✓ |
| `msg.messages.attachments` | `~/Library/Messages/Attachments` | — | reportOnly (TCC + iCloud sync) | — | — |
| `msg.zoom.recordings` | `~/Documents/Zoom/*` | `olderThan(90d)` | trash | medium | ✗ |

#### 3.4.5 Large, old and duplicate files

| Rule ID | Locator | Eligibility | Action | Risk | SC |
|---------|---------|-------------|--------|------|----|
| `files.large` | index query `kind == .file && allocated ≥ 500 MB` (threshold in Settings) | — | reportOnly → user selects | medium | ✗ |
| `files.downloads.old` | `~/Downloads/*` | `olderThan(90d, .mtime)` and `.addedTime` (`ATTR_CMN_ADDEDTIME`) | trash | medium | ✗ |
| `files.installers` | `~/Downloads/**`, `~/Desktop/**` with ext `dmg,pkg,iso,xip,mpkg,zip` (zip only when an app/folder with same stem exists) | `olderThan(14d)` | trash | low | ✗ (suggested) |
| `files.screen-recordings` | `~/Desktop/Screen Recording *.mov`, `~/Movies/*.mov` created by QuickTime/Screenshot (`kMDItemCreator` via `MDItemCreate` where available) | `olderThan(30d)` | trash | medium | ✗ |
| `files.disk-images` | `*.dmg,*.img,*.raw,*.vmdk,*.qcow2` ≥ 500 MB outside app containers | — | reportOnly | — | — |
| `files.archive-extracted-duplicate` | archive `X.zip/X.tar.gz/X.rar` with sibling dir `X` (normalized stem) | heuristic: archive entry count/size vs dir (via `libarchive`-free check: `unzip -Z1` not used; read zip central directory in Swift for `.zip`; others by size parity ±5%) | trash (archive) | medium | ✗ |
| `files.duplicates` | `DuplicateFinder`: group by (`allocated` ≥ 1 MB, same `volume`), exclude groups where all members share `cloneID` or are hard links; fingerprint = SipHash64(size ‖ first 4 KiB ‖ last 4 KiB); confirm = SHA256 streaming | user chooses which copies to keep (default: keep oldest path in `~/Documents`/`~/Pictures`, trash others) | trash | medium | ✗ |
| `files.duplicates.clone-convert` (stretch) | for confirmed duplicates on APFS, replace copies with `clonefile(2)` of the keeper (same content, 0 extra bytes) | — | custom | low | ✗ |
| `files.empty-dirs` | directories with `entryCount == 0` under user roots, excluding dot-dirs and app containers | `olderThan(30d)` | trash | safe | ✗ |
| `files.ds-store` | `.DS_Store` on external/network volumes only | — | unlinkInPlace | safe | ✗ |

### 3.5 Category attribution (`CategoryAttribution`)

Every scanned byte is attributed to exactly one `Category` by longest-prefix match over canonical paths, then overridden by rule hits:

| Prefix / source | Category |
|-----------------|----------|
| System volume `statfs` usage | `macOS` |
| `/Library/Apple`, `/private/var/db`, `/private/var/vm`, `/System/Volumes/{Preboot,VM,Recovery}` | `macOS` |
| `/Applications/**`, `~/Applications/**`, `/Library/Application Support/**` (non-dev) | `applications` |
| Hits of `dev.*` rules, `/Library/Developer/**`, `~/Library/Developer/**`, `~/.android`, `~/.gradle`, `~/.cargo`, `~/.npm`, `~/go`, `~/sdk`, `~/flutter`, `/usr/local`, `/opt/**`, Docker container | `developer` |
| `~/Library/Caches/**`, `/Library/Caches/**`, `$DARWIN_USER_CACHE_DIR`, Electron cache hits | `caches` |
| `msg.*` rule hits | `messagingMedia` |
| rest of `~/Library/**`, `~/.config`, `~/.local`, `~/.cache` | `appData` |
| `~/Documents`, `~/Downloads`, `~/Desktop`, `~/Movies`, `~/Music`, `~/Pictures`, other home dirs | `documentsMedia` |
| `/Users/<other>`, `/Users/Deleted Users` | `otherUsers` |
| `~/.Trash`, `.Trashes` | `trash` |
| `EPERM` unreadable entries (estimated via `ATTR_DIR_ENTRYCOUNT` unavailable → shown as "unknown") | `unscanned` |
| volume stats | `snapshots` (local TM), `purgeable`, `free` |

Test `T3-CATEGORY-EXACTLY-ONCE`: Σ category bytes (excluding `free`, `purgeable`) == Data volume used ± 2% on the fixture; no entry attributed twice.

### 3.6 Smart Clean composition

Smart Clean = all rules with `defaultEnabledInSmartClean == true` **and** `risk == .safe`, minus any rule the user disabled, evaluated with universal guards (§4). Items with blockers are shown but unchecked (e.g. "Quit WhatsApp to include 5.7 GB"). The Smart Clean sheet shows: total private-reclaimable, per-rule breakdown with rationale, tier selector (Trash default), "Quit blocking apps" button, and a "Review items" expander per rule. Low/medium/high rules are surfaced in the Deep Inspector's "Suggestions" pane, never auto-selected.

### 3.7 Rule testing contract

Every rule MUST ship with a test in `Tests/ReclaimRulesTests/Rules/<RuleID>Tests.swift` that:

1. Builds a fixture home via `FixtureBuilder.home()` reproducing the rule's locator layout (positive and negative cases, including names from §1.2.5 with `@`, spaces, NFD).
2. Runs a scan with `ScanEngine` on the fixture (real APFS temp dir) and evaluates the single rule.
3. Asserts: exact set of expected paths, `totalPrivateReclaimable` equals the fixture's known private bytes (sparse/clone fixtures included where relevant), blockers for running-app and git-dirty cases (using fakes), `reportOnly` rules produce zero `trash` actions.
4. For tool-backed rules, uses `FakeToolAdapters` with recorded JSON (`Fixtures/Tools/simctl-list.json`, `docker-system-df.json`, `avdmanager-list.txt`) and asserts the exact `ToolInvocation` arguments.
5. Executes the finding through `CleanExecutor` in `.dryRun` and `.trash` tiers on the fixture and asserts the ledger rows and that protected siblings are untouched.

---

## 4. STEP 4 — Safety & Non-Destructive Guardrails

All deletions — user tier or helper — pass through `PathGuard` and `DeletionEngine`. There is no code path that calls `unlink`/`rmdir`/`FileManager.removeItem`/`NSWorkspace.recycle` outside `DeletionEngine` (enforced by a SwiftLint custom rule `no_direct_unlink` and a grep test `T2-NO-DIRECT-UNLINK` over the source tree).

### 4.1 Hardcoded protected paths and conditions

`ProtectedPaths` is an immutable `enum` with static arrays; user settings can **add** protections, never remove these.

**Absolute prefixes (never traversed for deletion, never offered):**

```
/System                         /usr (except /usr/local)         /bin   /sbin   /etc → /private/etc
/private/var/db                 /private/var/vm                  /private/var/run   /private/var/folders/*/*/0 (system)
/Library/Apple                  /Library/Keychains               /Library/Security   /Library/Preferences/com.apple.*
/Library/Application Support/com.apple.TCC   /Library/StagedExtensions   /Library/SystemExtensions
/Volumes/<any>/Backups.backupdb  /Volumes/<any>/*.backupbundle   /.Spotlight-V100  /.fseventsd  /.DocumentRevisions-V100
/Library/Developer/CoreSimulator/Volumes      (mount points; tool-managed)
/Library/Developer/CoreSimulator/Cryptex/Images/bundle/<mounted>   (mounted bundles)
```

**Home-relative prefixes:**

```
~/Library/Keychains           ~/.ssh            ~/.gnupg          ~/.aws/credentials   ~/.aws/config
~/.config/gh                  ~/.docker/config.json   ~/.kube/config   ~/.netrc   ~/.npmrc  ~/.pypirc  ~/.cargo/credentials*
~/Library/Application Support/com.apple.TCC
~/Library/Mail                ~/Library/Messages (except Attachments report)   ~/Library/Safari (except Caches)
~/Library/Mobile Documents    ~/Library/CloudStorage     ~/Library/Photos    ~/Pictures/*.photoslibrary
~/Library/Application Support/MobileSync/Backup (only via rule sys.ios-backups with high risk)
~/Library/Preferences/com.apple.*   ~/Library/Preferences/.GlobalPreferences*   ~/Library/Preferences/loginwindow*
~/Library/Accounts   ~/Library/Cookies   ~/Library/Group Containers/group.com.apple.*
~/Library/Application Support/Reclaim (ourselves)
```

**App-state files inside otherwise-cleanable trees (exact names/globs):**

```
WhatsApp: ChatStorage.sqlite*, LocalKeyValue.sqlite*, BackedUpKeyValue.sqlite*, Axolotl.sqlite*, LID.sqlite*, ContactsV2.sqlite*,
          Sticker.sqlite*, emoji.sqlite*, BotPKICRL.sqlite*, fts/, Library/, AppState/, Biz/, ExtChatDB/, channels-fts/
Telegram: postbox/db/**, accounts-metadata/**, account-*/network-stats*, *.plist
Editors:  User/globalStorage/state.vscdb, state.vscdb-wal, state.vscdb-shm, User/settings.json, User/keybindings.json,
          User/snippets/**, User/globalStorage/storage.json, extensions/**
Browsers: Login Data*, Cookies*, History*, Bookmarks*, Web Data*, Preferences, Local State, Extensions/**, Sessions/**,
          places.sqlite*, key4.db, logins.json, cert9.db, favicons.sqlite
Docker:   ~/.docker/config.json, contexts/**  (Docker.raw only via dev.docker.raw-reset)
MySQL:    ~/Library/Application Support/MySQL/** (report only)
Git:      any path with a `.git` component (the directory itself and contents)
```

**Conditions (checked per item at plan and at delete time):**

| Condition | Source | Effect |
|-----------|--------|--------|
| `SF_RESTRICTED` on item or ancestor | `bsdFlags` | deny `protectedPath("SIP")` |
| `SF_IMMUTABLE`, `UF_DATAVAULT` | flags | deny |
| `UF_IMMUTABLE` | flags | blocker `immutable`; user tier may clear with explicit per-item confirmation |
| Mount point or `st_dev` differs from root | `VolumeTopology` | deny `mountPoint` |
| Symlink anywhere in the path components (except final component when the rule targets the link itself) | `openat(O_NOFOLLOW)` walk | deny |
| Socket/FIFO/device | kind | deny (never delete live sockets; e.g. `~/.docker/run/*.sock`) |
| Path inside a `.git` directory | component check | deny |
| Path is a scan root or `~` or `/` | exact | deny |
| Uncommitted changes in enclosing repo (for dev.* rules) | `GitInspector` | blocker `gitDirty` |
| Project active within `protectWindowDays` (default 7) | `ProjectActivity` | blocker `recentlyActive` |
| Owner app running | `AppCoordinator` | blocker `appRunning` |
| Open file descriptors (permanent tier) | `ProcessInspector` | blocker `openByProcesses` |

### 4.2 Git and active-project awareness

```swift
public struct ProjectActivity: Sendable {
    public let root: String                  // nearest ancestor containing .git, package.json, Cargo.toml, build.gradle, composer.json, pubspec.yaml, pyproject.toml, Package.swift
    public let lastCommit: Date?             // git log -1 --format=%ct
    public let indexMTime: Date?             // .git/index mtime (staging activity)
    public let newestSourceMTime: Date       // max mtime over a bounded sample (≤ 2,000 entries, excluding artifact dirs)
    public let rootMTime: Date
    public var lastActivity: Date { max(lastCommit, indexMTime, newestSourceMTime, rootMTime) }
    public let isGitRepo: Bool
    public let isDirty: Bool?                // nil when git unavailable or timed out → treated as dirty (conservative)
}

public actor GitInspector {
    public func status(repoRoot: String) async -> GitStatus   // runs /usr/bin/git -C root status --porcelain=v2 -z --untracked-files=normal, 5 s timeout
}
```

Rules: `projectInactive(days:)` ⇔ `now - lastActivity ≥ days`. Default thresholds: **protect** if active within 7 days (hard blocker for dev.* rules), **recommend** when inactive ≥ 90 days (`node_modules`, `vendor`, `.venv`), ≥ 30 days for pure build outputs (`target`, `.next`, `build`). `gitClean` false or unknown ⇒ blocker (the artifact may be needed to reproduce uncommitted work). Submodules/worktrees: `.git` file with `gitdir:` is resolved. Monorepos: nearest `package.json` wins over repo root for `node_modules` staleness, but dirtiness is checked at repo root.

### 4.3 Symlink-trap and TOCTOU-safe deletion

`DeletionEngine` never operates on path strings after planning. Algorithm for an item:

1. Open the scan root with `open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)`; verify `fstat` identity equals the recorded root identity.
2. Walk each relative component with `openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)`; any `ELOOP`/`ENOTDIR` ⇒ abort item with `DeletionError.symlinkInPath`.
3. For the final component: `fstatat(parentFD, name, AT_SYMLINK_NOFOLLOW)`; require `(st_dev, st_ino) == item.identity` and `st_flags` free of `SF_RESTRICTED|SF_IMMUTABLE|UF_DATAVAULT`; mode/kind must match the scan record. Mismatch ⇒ `DeletionError.identityChanged` (TOCTOU defense; EC-14).
4. Tier `trash`: `NSWorkspace.shared.recycle([url])` on the **verified** path reconstructed from the fd walk (`fcntl(F_GETPATH)` on the parent fd + name) immediately after verification; result URL recorded.
5. Tier `permanent`: recursive delete using fds only: for directories `openat(..., O_NOFOLLOW)`, `getattrlistbulk` to list, recurse, `unlinkat(dirfd, name, 0)` for non-dirs, `unlinkat(dirfd, name, AT_REMOVEDIR)` after children; never cross `st_dev`; `EACCES` on a user-owned directory triggers one `fchmodat(dirfd, name, mode|S_IRWXU, AT_SYMLINK_NOFOLLOW)` retry (REQ-DEL-2); `UF_IMMUTABLE` only cleared when the user approved it for that item (`fchflags` on an fd opened with `O_NOFOLLOW`).
6. Each entry result (`ok`, `errno`) is accumulated in `OperationReport`; the parent directory is removed only if all children succeeded.

Bulk Trash: items batched per 500 into one `recycle` call to keep Finder's undo stack usable; `recycle` returns `[URL: URL]` which feeds the ledger. If `recycle` fails with `NSFileWriteNoPermissionError`/EPERM, the item is marked `needsHelper` or `needsFullDiskAccess` by errno classification.

### 4.4 Deletion tiers

| Tier | Mechanics | Confirmation | Pre-flight |
|------|-----------|--------------|------------|
| `dryRun` | Executes the full pipeline (guards, identity verification, tool `--dry-run`/inventory) but skips mutation; emits a manifest (`OperationReport` with `wouldDelete` items, bytes allocated/private, errors that would occur) | none | all guards |
| `trash` (default) | `NSWorkspace.recycle`; helper ops are unavailable in this tier except `deleteLocalSnapshots` (no Trash concept → treated as `permanent` with its own confirmation) | one confirmation per plan; high-risk items require an extra per-item checkbox with typed acknowledgment of the exact byte count | guards + app-running check |
| `permanent` | `unlinkat` recursion in-process; helper for allowlisted root paths | per-plan confirmation **and** per-item confirmation for `medium`/`high`; sheet shows the manifest and a "Why not Trash?" explanation | guards + `ProcessInspector.openFiles(under:)` must be empty (or user quits the processes from the sheet) |

`CleanExecutor` persists the plan (`operations` row, status `planned`) before mutating, updates per-item rows as it goes (`in_progress` → `done`/`failed`), and writes `measuredFreedBytes` after the settle loop. A crash mid-operation leaves a resumable `in_progress` operation shown in History.

### 4.5 Running-app coordination

`AppCoordinator` maps `ownerBundleIDs` → `NSRunningApplication` instances (including helper processes via `proc_listpids` + `proc_pidpath` prefix match on the app bundle path, which covers `Cursor Helper`, `com.docker.backend`, `Telegram Helper`). Quit flow: `terminate()` → wait ≤ 10 s observing `isTerminated` → optional `forceTerminate()` only after explicit user click ("Force Quit") → re-check. Docker is special-cased: "Quit Docker Desktop" via `NSRunningApplication` for `com.docker.docker`, then poll `~/.docker/run/docker.sock` connect failure and `com.docker.backend` absence (≤ 30 s). The sheet mirrors what we did manually (osascript quit → pkill), but without `SIGKILL` unless the user asks.

### 4.6 Audit log and rollback ledger

Schema (Appendix C) records every operation and item with `original_path`, `trash_path`, `dev`, `ino`, `logical`, `allocated`, `private_bytes`, `rule_id`, `tier`, `result`, `errno`, `reason` (rule rationale snapshot), `freed_measured`. Restore algorithm (`LedgerStore.restore(operationID:)`): for each item with `trash_path` still existing and identity matching (`dev`,`ino` of the trashed item), `FileManager.moveItem` back to `original_path` if the destination does not exist (else to `original_path + " (restored)"`); tool/helper items are not restorable and are labeled so at plan time. History view offers "Restore all", "Restore selected", "Export CSV". Retention: ledger rows forever (small); Trash contents are the user's responsibility (we show "Items in Trash: N / X GB").

### 4.7 Failure handling

- Partial failures never abort the whole plan; the report groups by errno with counts and example paths (EC-04/26).
- `EPERM` → suggests FDA (if probe says denied) or helper; `EACCES` → suggests "Retry with permission fix" (chmod) or helper; `EBUSY`/`ETXTBSY` → shows processes via `ProcessInspector`; `ENOTEMPTY` on parent → informational.
- Tool failures surface stderr (truncated to 2 KB) with the exact command line for copy/paste.
- Helper unavailable → items marked `needsHelper`, plan still executes the rest.

### 4.8 Safety test matrix (must pass before Phase 3)

| Test | Fixture | Assertion |
|------|---------|-----------|
| T2-SYMLINK-TRAP | `cache/` contains symlink `link → ~/Documents-fixture` | deleting `cache/` removes the link only; target untouched (`inode` unchanged, child count unchanged) |
| T2-SYMLINK-IN-PATH | plan item path `a/b/c` where `b` is replaced by a symlink after planning | `DeletionError.symlinkInPath`; nothing deleted |
| T2-TOCTOU-SWAP | after planning, swap target dir with another dir (rename) | `identityChanged`; nothing deleted |
| T2-MOUNT-GUARD | DMG mounted inside fixture tree | deletion refuses at mount point; parent cleanup stops |
| T2-FLAGS | `chflags uchg` file; `schg` simulated via fake flags | `uchg` → blocker; approval clears and deletes; `schg` → deny |
| T2-PROTECTED-PREFIX | items under each protected prefix (temp HOME override) | all denied with reasons |
| T2-GIT-DIRTY | repo with uncommitted change + `node_modules` | blocker `gitDirty`; clean repo → eligible |
| T2-RECENT-ACTIVITY | project touched 1 day ago | blocker `recentlyActive(7)` |
| T2-DEL-PARTIAL | tree with one `chmod 000` subdir | report shows 1 EACCES group, other siblings deleted, parent kept |
| T2-DEL-CHMOD-RETRY | user-owned dir with mode 0555 containing files | retry policy succeeds; mode restoration not required |
| T2-TRASH-UNDO | trash 1,000 files | ledger rows have `trash_path`; `restore` returns all; identities preserved |
| T2-OPENFILES | hold an fd open on a file | permanent tier blocked with pid list; after close, proceeds |
| T2-HIGH-RISK-CONFIRM | plan with `dev.docker.raw-reset` | executor refuses without explicit acknowledgment token |
| T2-FREED-DELTA | delete 100 MB sparse (10 MB allocated) + 50 MB clone | `measuredFreedBytes` ≈ 10 MB + private bytes (±2%) |
| T2-NO-DIRECT-UNLINK | source grep | only `DeletionEngine.swift` and `ReclaimHelper/Deleter.swift` reference `unlinkat|rmdir|removeItem|recycle(` |

---

## 5. STEP 5 — UI/UX & Visualization Design

### 5.1 Information architecture

`NavigationSplitView` with a sidebar (⌘1…⌘8) and a detail area; a persistent bottom status bar (scan state, free space, selected bytes); a right-hand Inspector (⌥⌘I) in Deep Inspector and Duplicates.

| Sidebar item | Purpose |
|--------------|---------|
| **Dashboard** | Storage bar, categories, top hogs, growth since last scan, Smart Clean CTA, alerts (FDA missing, helper missing, snapshots). |
| **Smart Clean** | Safe rules with sizes, blockers, one-click plan. |
| **Deep Inspector** | Treemap/Sunburst + Miller columns + dense table; any path; manual selection to Trash. |
| **Developer** | Dev rules grouped by toolchain (Xcode, Node, Python/AI, Rust/Go/Java, Android/Flutter, Docker, Homebrew) with per-project activity badges. |
| **Apps** | Per-app footprint (bundle + Application Support + Containers + Caches + Group Containers), orphans. |
| **Large & Duplicates** | Large files, old downloads, installers, duplicate groups, archive/folder pairs. |
| **History** | Ledger, restore, export. |
| **Settings** | Scan roots/exclusions, thresholds, rules on/off, user rules, FDA/helper status, monitor, units, diagnostics. |

### 5.2 Dashboard

- **Storage bar**: segmented, proportional to the Data volume capacity: `macOS` (System volume used + system paths), `Applications`, `Developer`, `App Data`, `Caches`, `Messaging Media`, `Documents & Media`, `Other Users`, `Trash`, `Snapshots`, `Unscanned`, `Purgeable` (hatched), `Free`. Hover shows bytes (decimal) + exact bytes + what's inside; click filters the hog list.
- **Live during scan**: segments grow as directories complete (progress coalesced at 10 Hz); a "scanning … 1.2 M items, 4.1 s" caption.
- **Top hogs**: top 10 entries by allocated with sparkline of growth vs previous snapshot (e.g. "WhatsApp media +30.2 GB since Jul 27").
- **Alerts**: Full Disk Access not granted (N unreadable dirs), helper not installed (N GB require admin), local snapshots present, disk < threshold.
- **Smart Clean card**: "Reclaim 23.4 GB safely" with rule chips; secondary "Review 61 GB of suggestions".

### 5.3 Smart Clean vs Deep Inspector

**Smart Clean sheet** (left: rules list with checkboxes, sizes, risk badges; right: preview of the selected rule) shows for each item: path, size (allocated / private when different), rationale, regeneration note ("Xcode build cache — automatically regenerated on next build"), blockers with fix buttons ("Quit Cursor", "Grant Full Disk Access", "Install helper"). Footer: tier picker (Trash default; Permanent requires toggling a switch that reveals the pre-flight panel), "Dry run" button producing a manifest sheet, "Clean" primary button.

**Deep Inspector**: three-pane — Visual Map (top), Miller Columns (bottom-left), Table (bottom-right) — plus Inspector panel. Selecting in any pane syncs the others. Multi-select → "Move to Trash" (⌘⌫) passes through the same guards (protected items are disabled with tooltip reason). "Suggestions" badge on a folder lists rule findings inside it.

### 5.4 Visual map and columns

- **Treemap**: squarified layout computed by `TreemapLayoutEngine` actor for the current node's children by `allocated` (toggle: private/logical); cull rects < 3×3 pt; label rects ≥ 48×16 pt; LOD: children of children rendered only when parent rect ≥ 120×80 pt; color by `Category` with lightness by age (newer = brighter) or by risk when a rule matched; hover via `onContinuousHover` with a spatial grid (64×64 cells) for O(1) hit-testing; zoom-in on click with matched-geometry animation (200 ms); breadcrumb bar. Rendering with SwiftUI `Canvas` (one pass, ≤ 5k rects) — if profiling shows > 8 ms/frame, switch to `CALayer`-backed `NSView` (same layout engine).
- **Sunburst**: same layout engine producing arcs (depth ≤ 6), used when the user prefers radial; shares hit-testing via angle/radius lookup.
- **Miller columns**: custom SwiftUI `ScrollView(.horizontal)` of `List` columns backed by `ChildrenPage` DTOs (lazy, 200 rows/page, sorted by allocated); keyboard: ←/→ change column, ↑/↓ move, ⏎ open in Finder, space Quick Look.
- **Table**: `NSTableView` via `NSViewRepresentable` (`FileTableView`) with columns Name, Allocated, Private, Logical, Items, Modified, Kind, Flags (sparse/clone/links/locked/mount), Category; sorts on the actor; virtualized; supports 1 M rows.

### 5.5 Inspector panel

Shows for the selection: display path + canonical path (copy), kind, logical/allocated/private bytes, "if deleted alone frees X", sparse/clone/links/compressed/immutable/SIP badges, owner/mode, mtime/ctime/added, volume, mount status, matching rule(s) with rationale/regeneration, blockers (running apps with Quit buttons; open-file processes), git status for project artifacts (repo, dirty, last commit), actions (Reveal in Finder, Quick Look, Move to Trash, Add exclusion, Copy path). For WhatsApp JIDs: resolved chat name, message count/last message date (when DB readable). For simulators/AVDs/Docker objects: tool-provided metadata.

### 5.6 History, Settings, Onboarding

- **History**: operations list (date, rules, tier, estimated vs measured freed, status), item drill-down, Restore / Restore selected, Export CSV/JSON, "Open Trash".
- **Settings**: Scan roots (default `/System/Volumes/Data` canonical root with excludes), additional volumes toggle, thresholds (large file 500 MB, stale 90 d, protect 7 d, status cache always), rule toggles grouped, user rules editor (JSON with validation), units, appearance (treemap palette), Monitor (enable, interval, free-space threshold 20 GB default, growth threshold 5 GB/7 d, watched roots), Permissions (FDA status + button, helper install/remove/version), Diagnostics export, Reset.
- **Onboarding** (first launch): 1) What Reclaim does / safety promises; 2) Full Disk Access step with live probe and relaunch; 3) optional helper install (explains root scope with the allowlist shown verbatim); 4) first scan.

### 5.7 Menu bar companion and background monitor

- `MenuBarExtra("Reclaim", systemImage: "internaldrive")` with `.menuBarExtraStyle(.window)`: free-space gauge (decimal), 7-day sparkline of free space, top 3 growth hogs since baseline, buttons: "Scan now", "Smart Clean…", "Open Reclaim", "Quit".
- Background: when windows close and "Keep in menu bar" is on, `NSApp.setActivationPolicy(.accessory)`; a `Task` loop with `ContinuousClock` sleeps `monitorInterval` (default 15 min): `statfs` Data volume; cheap size probes of watched roots (`getattrlist` mtime/entry count; if changed → bounded subtree rescan with `ScanOptions(maxEntries: 500k, timeBudget: 5 s)`); compare to `watch_baselines`.
- Alerts via `UNUserNotificationCenter` (authorization requested in onboarding): "Free space below 20 GB (14.2 GB)", "WhatsApp media grew 12.4 GB in 3 days", "Docker.raw grew to 20 GB while Docker is stopped". Notification actions: "Smart Clean", "Show".
- Login launch: `SMAppService.mainApp.register()` toggle in Settings.
- Budget: ≤ 30 MB RSS idle, ≤ 0.1 % CPU average (verified by `T4-MONITOR-BUDGET` using `proc_pid_rusage` over 10 minutes in CI-local run).

### 5.8 State management

```swift
@MainActor @Observable final class AppModel {
    var scan: ScanState                 // .idle, .running(progress), .complete(summary), .failed(error)
    var snapshot: SnapshotHandle?       // Sendable handle to FileIndexReader
    var categories: [CategorySlice]
    var findings: [Finding]
    var smartCleanPlan: PlanDraft
    var selection: InspectorSelection
    var permissions: PermissionState    // fda, helper, notifications
    var monitor: MonitorState
    var history: [OperationSummary]
    let services: Services              // ScanEngine, RuleRegistry, CleanExecutor, LedgerStore, SettingsStore (actors)
}
```

Views are pure functions of `AppModel` slices; long-running work is launched via `Task { await services… }` with results assigned on the main actor; progress streams are coalesced with `AsyncStream` + `Task.sleep` throttling; the treemap view receives an immutable `TreemapFrame` (rects + labels) per level.

### 5.9 Keyboard-first and accessibility

Shortcuts: ⌘R scan, ⌘⇧C Smart Clean, ⌘⌫ Trash selection, ⌥⌘⌫ Permanent (opens pre-flight), ⌘F filter, `/` search path, ⌘↑ parent, ⌘↓/⏎ open, ⌘Y / space Quick Look, ⌘I inspector, ⌘Z undo last operation (restore), ⌘⇧R Reveal in Finder, ⌘, Settings. All custom views expose `accessibilityLabel/Value` (e.g. "node_modules, 1.6 GB, stale 120 days, safe to trash"); treemap rects are accessibility elements with the same text; VoiceOver rotor by category; respects Reduce Motion (no zoom animations) and Increase Contrast (palette switch).

### 5.10 Visual design tokens

System colors for categories (`Color(nsColor:)` from a fixed asset palette with light/dark variants), SF Symbols per category (`internaldrive`, `app.badge`, `hammer`, `folder.badge.gearshape`, `tray.full`, `message`, `doc.richtext`, `person.2`, `trash`, `clock.arrow.circlepath`), monospaced digits for sizes (`.monospacedDigit()`), 8-pt grid, native materials for sheets, no custom window chrome.

---

## 6. STEP 6 — Phased Implementation Roadmap

Phases are sequential; a phase is **done** only when every listed test passes on CI (or locally for `.requiresAdmin`/`.requiresAPFSMount` tags) and the exit criteria are met. Each phase lists the exact files to create. Paths are relative to the workspace root (`/Users/olawale/projects/space-management`).

### Phase 0 — Project setup, fixtures and benchmarks (1 week)

**Goal:** Build skeleton, CI, fixture generator, and measured baselines for the three enumeration strategies so Phase 1 decisions are data-driven.

**Directory structure to create**

```
Reclaim.xcworkspace/contents.xcworkspacedata
Packages/ReclaimKit/Package.swift
Packages/ReclaimKit/Sources/ReclaimCore/Placeholder.swift
Packages/ReclaimKit/Sources/ReclaimSafety/Placeholder.swift
Packages/ReclaimKit/Sources/ReclaimPersistence/Placeholder.swift
Packages/ReclaimKit/Sources/ReclaimRules/Placeholder.swift
Packages/ReclaimKit/Sources/ReclaimXPC/Placeholder.swift
Packages/ReclaimKit/Sources/ReclaimCLI/main.swift
Packages/ReclaimKit/Sources/ReclaimBench/main.swift
Packages/ReclaimKit/Sources/ReclaimBench/Enumerators/FileManagerWalk.swift
Packages/ReclaimKit/Sources/ReclaimBench/Enumerators/FTSWalk.swift
Packages/ReclaimKit/Sources/ReclaimBench/Enumerators/BulkAttrWalk.swift
Packages/ReclaimKit/Sources/ReclaimTestSupport/FixtureBuilder.swift
Packages/ReclaimKit/Sources/ReclaimTestSupport/FixtureSpec.swift
Packages/ReclaimKit/Sources/ReclaimTestSupport/Tags.swift
Packages/ReclaimKit/Tests/ReclaimTestSupportTests/FixtureBuilderTests.swift
Apps/Reclaim/Reclaim.xcodeproj
Apps/Reclaim/Sources/ReclaimApp/ReclaimApp.swift            (empty window)
Apps/Reclaim/Helper/ReclaimHelper/main.swift                 (exits 0)
Config/Base.xcconfig  Config/Debug.xcconfig  Config/Release.xcconfig  Config/Signing.xcconfig
Config/Reclaim.entitlements  Config/ReclaimHelper.entitlements
Config/LaunchDaemons/com.olawale.reclaim.helper.plist
.github/workflows/ci.yml
.swiftlint.yml  .swiftformat
Scripts/bench.sh  Scripts/make-fixture.sh  Scripts/purge-cache.sh (admin; local only)
docs/ADR/ADR-001…ADR-010.md
PLAN.md (this file)
```

**Package.swift essentials**

```swift
// swift-tools-version: 6.0
let package = Package(
  name: "ReclaimKit",
  platforms: [.macOS(.v14)],
  products: [ .library(name: "ReclaimCore", targets: ["ReclaimCore"]), /* … */ .executable(name: "reclaim", targets: ["ReclaimCLI"]), .executable(name: "reclaim-bench", targets: ["ReclaimBench"]) ],
  dependencies: [ .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0") ],
  targets: [ /* as in §2.3 */ ],
  swiftLanguageModes: [.v6]
)
// Every target: swiftSettings: [.enableUpcomingFeature("StrictConcurrency"), .unsafeFlags(["-warnings-as-errors"]) (Debug only via xcconfig)]
```

**Core types introduced**

```swift
// ReclaimTestSupport/FixtureSpec.swift
public struct FixtureSpec: Sendable {
    public enum Node: Sendable {
        case file(name: String, logicalBytes: Int, allocatedBytes: Int? = nil, mtimeDaysAgo: Int = 0, mode: mode_t = 0o644, flags: UInt32 = 0)
        case sparse(name: String, logicalBytes: Int, writtenBytes: Int)        // ftruncate + write head
        case clone(name: String, of: String)                                    // clonefile(2)
        case hardlink(name: String, of: String)                                 // link(2)
        case symlink(name: String, to: String)                                  // symlink(2); may create loops
        case dir(name: String, mode: mode_t = 0o755, children: [Node])
        case socket(name: String)                                               // bind(AF_UNIX)
        case gitRepo(name: String, dirty: Bool, children: [Node])               // `git init`, commit, optional uncommitted file
        case nodeModules(name: String = "node_modules", packages: Int, bytesEach: Int)
    }
    public let root: [Node]
}

public struct FixtureBuilder {
    public static func make(_ spec: FixtureSpec, at base: URL? = nil) throws -> Fixture   // mkdtemp under /private/tmp (APFS)
    public static func home(_ layout: HomeLayout) throws -> Fixture                        // builds ~/Library-like tree
    public static func largeTree(dirs: Int, filesPerDir: Int, bytesPerFile: Int) throws -> Fixture  // benchmark fixture
}
public struct Fixture: Sendable { public let root: URL; public let expected: ExpectedSizes; public func cleanup() }  // cleanup clears uchg flags first
public struct ExpectedSizes: Sendable { public let logical: UInt64; public let allocated: UInt64; public let privateBytes: UInt64; public let entryCount: Int }
```

**Benchmark harness (`reclaim-bench`)**

Commands: `reclaim-bench fixture --dirs 200000 --files 2000000 --out /private/tmp/rcl-fixture`, `reclaim-bench walk --strategy filemanager|fts|bulk --root <path> --workers N --repeat 3 --json`. Output: wall time, entries/s, peak RSS (`proc_pid_rusage`), syscalls (optional via `dtrace` script when run as admin).

**Tests / exit criteria**

| Test | Assertion |
|------|-----------|
| T0-FIXTURE-SIZES | `FixtureBuilder.make` produces trees whose `du`-equivalent (`fts` + `st_blocks`) equals `ExpectedSizes.allocated` ± 1 block; sparse fixture has `allocated ≤ written + 1 block`; clone fixture has second file `privateBytes == 0` (verified via `getattrlist ATTR_CMNEXT_PRIVATESIZE`). |
| T0-FIXTURE-CLEANUP | cleanup removes `uchg` files and leaves no temp dirs. |
| T0-BENCH-2M | On the 2 M-entry fixture (warm): `bulk` ≥ 3× faster than `fts` and ≥ 10× faster than `filemanager`; `bulk` ≤ 3.0 s on the CI runner class (recorded as baseline JSON in `docs/benchmarks/phase0.json`; thresholds tightened in Phase 1). |
| T0-CI-GREEN | `swift build`, `swift test`, `xcodebuild -scheme Reclaim build` succeed on `macos-15`. |

### Phase 1 — Core POSIX/APFS scanner engine (2–3 weeks)

**Goal:** `ReclaimCore` scans a root into `FileIndex` with accurate sizes, flags, identities and mount boundaries; snapshot save/load; volume topology.

**Files**

```
Sources/ReclaimCore/
  FS/Errno.swift                      // ErrnoError, classification (isPolicyDenial: EPERM, isPosixDenial: EACCES)
  FS/FileDescriptor.swift             // RAII wrapper: openat/O_NOFOLLOW helpers, fcntl(F_GETPATH)
  FS/AttrList.swift                   // attrlist construction + constants; returned-attrs parser
  FS/BulkAttrEnumerator.swift         // getattrlistbulk loop (§2.6.2–2.6.3)
  FS/FTSEnumerator.swift              // fallback
  FS/DirectoryEnumerator.swift        // protocol + factory choosing by volume fsType
  FS/PathCanonicalizer.swift          // realpath, firmlink table (/usr/share/firmlinks), display path mapping
  FS/Firmlinks.swift
  Volume/VolumeTopology.swift         // actor; getmntinfo_r_np, statfs, DiskArbitration names
  Volume/VolumeStats.swift            // free/used/purgeable via statfs + URLResourceValues
  Index/EntryID.swift  Index/EntryKind.swift  Index/EntryRecord.swift
  Index/FileIndex.swift               // actor: SoA arrays, append, link, rollup
  Index/FileIndexReader.swift         // Sendable immutable view (copy-on-finalize)
  Index/IndexQuery.swift              // predicates compiled to closures over SoA
  Index/SizeTriple.swift  Index/FileIdentity.swift
  Scan/ScanOptions.swift  Scan/ScanEvent.swift  Scan/ScanSummary.swift
  Scan/WorkQueue.swift                // actor-backed LIFO with size hints
  Scan/ScanEngine.swift               // actor; TaskGroup workers; batching; cancellation
  Scan/Rollup.swift                   // post-pass sizes, hardlink dedupe, clone accounting
  Snapshot/SnapshotFormat.swift       // RCL1 header, versioning
  Snapshot/SnapshotWriter.swift  Snapshot/SnapshotReader.swift   // mmap
  Util/ByteFormatting.swift           // decimal + exact
  Util/Logging.swift                  // os.Logger subsystems
Tests/ReclaimCoreTests/
  BulkAttrEnumeratorTests.swift  FTSEnumeratorTests.swift  ParityTests.swift
  SizeAccountingTests.swift  FirmlinkTests.swift  MountBoundaryTests.swift
  ScanEngineTests.swift  CancellationTests.swift  SnapshotRoundTripTests.swift
  IndexQueryTests.swift  VolumeStatsTests.swift  NamesTests.swift
```

**Key signatures**

```swift
public struct ScanOptions: Sendable {
    public var roots: [String]
    public var excludes: [String]                   // canonical prefixes
    public var crossMountPoints: Bool = false
    public var includeOtherVolumes: Bool = false
    public var maxConcurrency: Int = min(ProcessInfo.processInfo.activeProcessorCount, 12)
    public var bufferBytes: Int = 256 * 1024
    public var forceFTS: Bool = false
    public var timeBudget: Duration? = nil
    public var maxEntries: Int? = nil
}

public enum ScanEvent: Sendable {
    case started(roots: [String])
    case progress(ScanProgress)                     // entries, bytesAllocated, directoriesDone, elapsed
    case unreadable(path: String, errno: Int32)
    case boundary(path: String, volume: VolumeInfo)
    case finished(ScanSummary)
}

public actor ScanEngine {
    public init(topology: VolumeTopology, logger: Logger = .scan)
    public func run(_ options: ScanOptions) -> AsyncThrowingStream<ScanEvent, Error>
    public func result() async throws -> FileIndexReader        // after .finished
    public func cancel()
}

public actor FileIndex {
    public func append(_ batch: EntryBatch) -> Range<EntryID>
    public func finalize() -> FileIndexReader                    // rollup + freeze
}

public struct FileIndexReader: Sendable {
    public var count: Int
    public func root(_ i: Int) -> EntryID
    public func parent(of: EntryID) -> EntryID?
    public func children(of: EntryID, sortedBy: SizeBasis, page: Range<Int>) -> [EntrySummary]
    public func summary(_ id: EntryID) -> EntrySummary          // name, kind, sizes, flags, mtime, identity, volume
    public func path(of: EntryID) -> String                     // canonical
    public func displayPath(of: EntryID) -> String              // firmlink-mapped
    public func find(path: String) -> EntryID?
    public func query(_ q: IndexQuery) -> [EntryID]
    public func largest(kind: EntryKind, basis: SizeBasis, limit: Int) -> [EntryID]
}

public enum SizeBasis: Sendable { case logical, allocated, privateBytes }

public struct VolumeStats: Sendable {
    public static func dataVolume() throws -> VolumeStats       // statfs("/System/Volumes/Data")
    public let total: UInt64, used: UInt64, available: UInt64, availableImportant: UInt64, availableOpportunistic: UInt64
    public var purgeableEstimate: UInt64 { availableImportant &- available }
}
```

**Tests / exit criteria**

| Test | Fixture | Assertion |
|------|---------|-----------|
| T1-BULK-PARITY | 50 k mixed entries | every parsed field equals `fstatat` (see §2.6.3). |
| T1-ENUM-NAMES | names: `120363076093068126@g.us`, `a b.lid.status`, `line\nbreak`, NFD `é`, 255-byte name, emoji | all enumerated byte-exact; `find(path:)` round-trips. |
| T1-SIZE-SPARSE | 1 GB logical / 8 MB written | `logical == 1 GB`, `allocated ≤ 9 MB`, `extFlags.isSparse`. |
| T1-SIZE-CLONE | A (100 MB) + clone B | `allocated(A)+allocated(B) == 200 MB`, `private(B) == 0` (or `private(A)==0` depending on kernel attribution) and `private(A)+private(B) ≤ 100 MB`; rollup `privateReclaimable(dir) == 100 MB`. |
| T1-SIZE-HARDLINK | file + 3 links | dir rollup counts bytes once; `linkCount == 4`. |
| T1-SYMLINK-LOOP | `a→b`, `b→a`, link to parent | scan terminates; links recorded as `.symlink` with 0 allocated beyond their own blocks. |
| T1-UNREADABLE | `chmod 000` dir | entry `.unreadable(EACCES)`; event emitted; scan continues. |
| T1-VOL-MOUNTPOINT (`.requiresAPFSMount`) | `hdiutil create -size 20m -fs APFS` attached inside fixture | boundary entry with the image's `statfs` used bytes; no descent. |
| T1-FIRMLINK-DEDUPE | scan `/private/var/folders/<user>` and `/System/Volumes/Data/private/var/folders/<user>` (real paths, read-only) | identical `(fsid,fileid)` → same `EntryID`; total counted once. |
| T1-VOL-DATAVOLUME | real system | `VolumeStats.dataVolume().total` within 1% of `statfs("/")`'s `f_blocks*f_bsize`; `available` equals `df -k /System/Volumes/Data` (parsed only in test). |
| T1-STATFS | — | `purgeableEstimate` ≥ 0 and `available ≤ availableImportant`. |
| T1-SCAN-CANCEL | 2 M fixture | cancel after 500 ms → `.finished(summary.completeness == .partial)` within 200 ms; no leaked fds (`proc_pidinfo PROC_PIDLISTFDS` count returns to baseline). |
| T1-SNAP-ROUNDTRIP | 2 M fixture | write + mmap read → identical arrays; load ≤ 1.0 s. |
| T1-INDEX-SORT | dir with 200 k children | `children(sortedBy: .allocated, page: 0..<200)` ≤ 50 ms. |
| T1-BENCH-2M | 2 M fixture | ≤ 6.0 s warm on the author's M3 Pro, ≤ 15 s on the macos-15 CI runner (stretch 3 s), ≤ 300 MB peak RSS; `bulk` ≥ 5× `FileManager` (ADR-016). |
| T1-FDLIMIT | 50 k nested dirs depth 300 | no `EMFILE`; open fd count ≤ 2,048 at any time. |

### Phase 2 — Safety layer, deletion engine, ledger, dry-run CLI (2–3 weeks)

**Goal:** Deletions are safe, tiered, logged, undoable; `reclaim` CLI can scan, report, plan (dry-run), clean and undo with JSON output.

**Files**

```
Sources/ReclaimSafety/
  Guard/ProtectedPaths.swift          // static lists §4.1
  Guard/PathGuard.swift               // decision engine (prefix, flags, kind, mount, symlink, git component)
  Guard/PermissionProbe.swift         // FDA probes §2.9.1
  Activity/ProjectActivity.swift      // §4.2
  Activity/GitInspector.swift
  Process/ProcessInspector.swift      // proc_listpidspath, proc_pidpath, NSRunningApplication mapping
  Process/AppCoordinator.swift        // quit/force-quit flows, Docker special-case
  Delete/DeletionEngine.swift         // §4.3 fd-based; tiers
  Delete/TrashService.swift           // NSWorkspace.recycle batching
  Delete/FreedSpaceMeter.swift        // settle loop
  Delete/OperationReport.swift
  Plan/CleanPlan.swift  Plan/CleanExecutor.swift  Plan/ConfirmationPolicy.swift
Sources/ReclaimPersistence/
  SQLite/SQLiteDatabase.swift  SQLite/Statement.swift  SQLite/Migrations.swift (Appendix C DDL)
  Ledger/LedgerStore.swift  Ledger/Restore.swift
  Settings/SettingsStore.swift  Settings/Settings.swift (Codable, versioned)
  Catalog/SnapshotCatalog.swift
Sources/ReclaimCLI/
  Reclaim.swift (root command)  Commands/Scan.swift  Commands/Top.swift  Commands/Report.swift
  Commands/Plan.swift  Commands/Clean.swift  Commands/Undo.swift  Commands/Doctor.swift  Commands/Rules.swift (Phase 3)
  Output/JSONOutput.swift  Output/TableOutput.swift
Tests/ReclaimSafetyTests/  (matrix §4.8)  Tests/ReclaimPersistenceTests/  Tests/ReclaimCLITests/
```

**Key signatures**

```swift
public enum GuardDecision: Sendable, Equatable { case allow; case deny(DenyReason); case blocked([Blocker]) }
public struct PathGuard: Sendable {
    public init(protected: ProtectedPaths = .default, topology: VolumeTopologySnapshot, extraProtected: [String])
    public func evaluate(_ entry: EntrySummary, path: String, action: RuleAction) -> GuardDecision
}

public enum DeletionTier: String, Sendable, Codable { case dryRun, trash, permanent }

public actor DeletionEngine {
    public init(guard: PathGuard, trash: TrashService, meter: FreedSpaceMeter, logger: Logger)
    public func delete(_ items: [PlannedItem], tier: DeletionTier,
                       approvals: ApprovalSet,                    // per-item tokens for uchg clearing / high-risk
                       progress: @Sendable (DeletionProgress) -> Void) async -> OperationReport
}

public struct PlannedItem: Sendable, Codable, Identifiable {
    public let id: UUID; public let rootPath: String; public let relativeComponents: [String]
    public let identity: FileIdentity; public let kind: EntryKind; public let sizes: SizeTriple; public let ruleID: RuleID?
}

public actor ProcessInspector {
    public func processes(withOpenFilesUnder path: String) async -> [ProcessRef]       // proc_listpidspath
    public func runningApps(bundleIDs: [String]) -> [RunningAppRef]
}

public actor LedgerStore {
    public init(databaseURL: URL) throws
    public func begin(_ plan: CleanPlan) throws -> OperationID
    public func record(_ result: ItemResult, in op: OperationID) throws
    public func finish(_ op: OperationID, measuredFreed: UInt64?, status: OperationStatus) throws
    public func operations(limit: Int, offset: Int) throws -> [OperationSummary]
    public func items(of op: OperationID) throws -> [LedgerItem]
    public func restore(_ op: OperationID, items: [UUID]? = nil) async throws -> RestoreReport
}
```

**CLI surface (stable JSON for tests)**

```
reclaim scan [--root PATH]... [--save] [--json]
reclaim top [--basis allocated|private|logical] [--kind file|dir] [-n 50] [--json]
reclaim report [--categories] [--json]                      # dashboard numbers
reclaim plan --rules <id,...|smart> [--tier trash|permanent] [--json]   # dry run manifest
reclaim clean --rules <id,...|smart> --tier trash|permanent [--yes] [--approve-high-risk TOKEN] [--json]
reclaim undo <operation-id> [--items UUID,...]
reclaim doctor [--json]                                     # FDA, helper, tools, volumes
reclaim rules list|show <id>|validate <file>                # Phase 3
```

**Tests / exit criteria:** all of §4.8 plus:

| Test | Assertion |
|------|-----------|
| T2-TCC-CLASSIFY | injected errno EPERM/EACCES/ENOENT → `FDAStatus` and blocker mapping correct. |
| T2-LEDGER-UNDO | 1,000 trashed items restored; rows updated to `restored`. |
| T2-LEDGER-CRASH | kill process mid-operation (child process test) → reopened DB shows `in_progress` op; CLI `doctor` reports it. |
| T2-CLI-JSON-SCHEMA | every `--json` output validates against `docs/schemas/cli-*.json`. |
| T2-TRASH-BULK | 100 k small files trashed ≤ 60 s; memory ≤ 150 MB. |
| T2-DOCKER-QUIT (`.requiresDocker`, local) | `AppCoordinator.quitDocker()` observes socket closure. |

### Phase 3 — Rule modules from the audit (3 weeks)

**Goal:** Every rule in §3.4 implemented, documented, tested; Smart Clean plan via CLI; category attribution.

**Files**

```
Sources/ReclaimRules/
  Engine/RuleID.swift  Engine/RuleMetadata.swift  Engine/Locator.swift  Engine/Predicate.swift
  Engine/CleanRule.swift  Engine/Finding.swift  Engine/RuleContext.swift  Engine/RuleRegistry.swift
  Engine/PredicateEvaluator.swift  Engine/LocatorResolver.swift  Engine/UserRulesLoader.swift (+ JSON schema)
  Engine/CategoryAttribution.swift
  Environment/RuleEnvironment.swift   // HOME, ANDROID_HOME, TMPDIR, DARWIN_USER_CACHE_DIR (confstr), installed apps
  Apps/AppRegistry.swift              // installed bundle IDs, name↔bundle index
  Tools/ToolLocator.swift  Tools/ToolRunner.swift  Tools/ToolInvocation.swift
  Tools/SimctlAdapter.swift  Tools/DockerAdapter.swift  Tools/BrewAdapter.swift  Tools/TMUtilAdapter.swift
  Tools/AvdManagerAdapter.swift  Tools/QLManageAdapter.swift  Tools/OllamaAdapter.swift  Tools/NodeToolsAdapter.swift
  Rules/System/{UserCachesRule, SystemCachesRule, TmpUserRule, UserLogsRule, DiagnosticReportsRule, ASLRule,
                QuickLookRule, TrashRule, TimeMachineSnapshotsRule, PurgeableReportRule, IOSBackupsRule,
                MailDownloadsRule, DeletedUsersRule, SwapReportRule}.swift
  Rules/Apps/{BrowserCacheRules, UpdaterStagingRules, ElectronCachesRule, EditorRules, ClaudeRules, OllamaModelsRule,
              HuggingFaceRule, TorchCacheRule, OrphanRules}.swift
  Rules/Developer/{XcodeRules, NodeRules, PythonRules, RustRules, GoRules, JavaRules, AndroidRules, FlutterRules,
                   PHPRules, SwiftPMRules, HomebrewRules, CloudCLIRules, VendoredSDKReportRule, DockerRules,
                   OrbStackColimaReportRules}.swift
  Rules/Messaging/{WhatsAppChatMediaRule, WhatsAppStatusCacheRule, WhatsAppNameResolver, WhatsAppDBReportRule,
                   TelegramMediaRule, SlackDiscordCacheRules, MessagesAttachmentsReportRule, ZoomRecordingsRule}.swift
  Rules/Files/{LargeFilesRule, OldDownloadsRule, InstallersRule, ScreenRecordingsRule, DiskImagesReportRule,
               ArchiveExtractedDuplicateRule, DuplicateFinder, Fingerprint (SipHash), ZipCentralDirectoryReader,
               EmptyDirsRule, DSStoreRule}.swift
  Rules/SmartClean.swift
Resources/Rules/builtin.rules.json        // generated from Swift metadata at build time (script) for docs/UI
Tests/ReclaimRulesTests/Rules/<RuleID>Tests.swift (one per rule)  Tests/ReclaimRulesTests/Fixtures/Tools/*.json
Tests/ReclaimRulesTests/CategoryAttributionTests.swift  Tests/ReclaimRulesTests/SmartCleanIntegrationTests.swift
```

**Key signatures** (in addition to §3.2)

```swift
public protocol SimctlAdapting: Sendable {
    func listRuntimes() async throws -> [SimRuntime]            // identifier, build, version, platform, sizeBytes?, path
    func listDevices() async throws -> [SimDevice]              // udid, name, runtimeID, state, lastBootedAt, dataPath, isAvailable
    func runtimeImages() async throws -> [SimRuntimeImage]      // from `runtime list -j`: id, build, state, sizeBytes, mountPath
    func deleteRuntime(build: String) async throws
    func deleteUnavailable() async throws
    func erase(udid: String) async throws
}
public protocol DockerAdapting: Sendable {
    func isDaemonReachable() async -> Bool                       // connect to ~/.docker/run/docker.sock
    func systemDF() async throws -> DockerUsage                  // images/containers/volumes/buildCache (bytes, reclaimable)
    func danglingVolumes() async throws -> [DockerVolume]
    func removeVolumes(_ names: [String]) async throws
    func pruneImages(all: Bool) async throws -> UInt64
    func pruneBuilder() async throws -> UInt64
}
public protocol AvdManaging: Sendable { func listAVDs() async throws -> [AVD]; func delete(name: String) async throws }
public protocol TMUtilAdapting: Sendable { func listLocalSnapshots() async throws -> [LocalSnapshot] }

public actor DuplicateFinder {
    public init(index: FileIndexReader, minBytes: UInt64 = 1_048_576)
    public func groupsBySize() -> [[EntryID]]
    public func fingerprint(_ ids: [EntryID]) async throws -> [DuplicateCandidateGroup]   // SipHash64(size‖head4K‖tail4K)
    public func confirm(_ groups: [DuplicateCandidateGroup]) async throws -> [DuplicateGroup]  // SHA256 streaming, excludes clone/hardlink sets
}
```

**Tests / exit criteria**

| Test | Assertion |
|------|-----------|
| T3-RULE-<id> (one per rule, ≥ 60 tests) | per §3.7 contract. |
| T3-WA-NAMES | fixture `ChatStorage.sqlite` with `ZWACHATSESSION` rows → JIDs labeled; running-app fake → resolver skipped, items blocked. |
| T3-WA-STATUS | 196 status dirs incl. tiny ones → single finding with count and total; names with `@` preserved. |
| T3-NODE-STALE | monorepo fixture: stale `node_modules` eligible, nested `node_modules/*/node_modules` excluded, dirty repo blocked, active project blocked. |
| T3-RUST-TARGET | `src-tauri/Cargo.toml` layout detected; 20 GB sparse-simulated size reported by allocated. |
| T3-SIMCTL-MAP | recorded `simctl runtime list -j` + bundles dir → only unreferenced, unmounted bundles offered; mounted bundle never offered. |
| T3-DOCKER-VOLUMES | fake adapter returns 19 named volumes → finding lists names/sizes; action is `volume rm <names>`; `raw-reset` blocked while daemon reachable. |
| T3-AVD | recorded `avdmanager list avd -c` + `.avd` dirs with `config.ini` → sizes include sdcard; running emulator fake → blocked. |
| T3-EDITOR-ORPHANS | 191 workspace dirs, 40 with existing folders → 151 offered; `state.vscdb` never offered; `.backup` offered. |
| T3-BROWSER-SCOPED | Chrome profile fixture → only cache subdirs offered; `Login Data`, `History` never. |
| T3-DUP-ARCHIVE | `S01/` + `S01….zip` fixture (zip built in test) → pair detected with parity check. |
| T3-DUP-CLONES | clone pair → excluded from duplicates with "already shares blocks" note. |
| T3-CATEGORY-EXACTLY-ONCE | fixture home → Σ categories == used ± 2%, no double attribution. |
| T3-SMARTCLEAN-DRYRUN | full fixture home → `reclaim plan --rules smart --json` manifest equals golden file (paths relative), zero medium/high items. |
| T3-USER-RULES | invalid JSON (protected prefix, `unlinkInPlace`) rejected with messages; valid rule evaluates. |

### Phase 4 — SwiftUI application (3–4 weeks)

**Goal:** Full UI per §5, wired to the actors; menu bar monitor; onboarding; Quick Look; AppKit bridges.

**Files**

```
Apps/Reclaim/Sources/ReclaimApp/
  ReclaimApp.swift (App, Scenes: WindowGroup "Reclaim", Settings, MenuBarExtra)
  AppModel.swift  Services.swift  AppDelegate.swift (activation policy, notifications, mount notifications)
  Onboarding/{OnboardingFlow, FullDiskAccessStep, HelperStep, FirstScanStep}.swift
Apps/Reclaim/Sources/ReclaimUI/
  Dashboard/{DashboardView, StorageBarView, CategoryLegend, TopHogsList, AlertsStack, SmartCleanCard}.swift
  SmartClean/{SmartCleanSheet, RuleRow, FindingPreview, TierPicker, PreflightPanel, ManifestSheet}.swift
  Inspector/{DeepInspectorView, BreadcrumbBar, TreemapView, TreemapLayoutEngine (actor), SunburstView,
             MillerColumnsView, ColumnList, FileTableView (NSViewRepresentable), FileTableController (NSTableViewDataSource/Delegate),
             InspectorPanel, FlagsBadges, QuickLookCoordinator (QLPreviewPanelDataSource)}.swift
  Developer/{DeveloperView, ToolchainSection, ProjectActivityBadge}.swift
  Apps/{AppsView, AppFootprintRow, OrphansSection}.swift
  Files/{LargeFilesView, DuplicatesView, DuplicateGroupRow, ArchivePairsView}.swift
  History/{HistoryView, OperationRow, OperationDetail, RestoreSheet}.swift
  Settings/{SettingsView, ScanSettings, RulesSettings, UserRulesEditor, MonitorSettings, PermissionsSettings, DiagnosticsSettings}.swift
  MenuBar/{MenuBarView, FreeSpaceGauge, Sparkline, GrowthTracker (actor), MonitorLoop}.swift
  Shared/{ByteText, RiskBadge, CategoryColor, Shortcuts, Accessibility}.swift
Apps/Reclaim/Resources/{Assets.xcassets, Localizable.xcstrings}
Apps/ReclaimUITests/{SmokeTests.swift, SmartCleanFlowTests.swift}
```

**Key signatures**

```swift
public actor TreemapLayoutEngine {
    public func layout(children: [EntrySummary], in rect: CGRect, basis: SizeBasis, minCell: CGFloat) -> TreemapFrame   // squarified
    public func sunburst(root: EntryID, reader: FileIndexReader, depth: Int, basis: SizeBasis) -> SunburstFrame
}
public struct TreemapFrame: Sendable { public let cells: [TreemapCell]; public let grid: SpatialGrid }
public struct TreemapCell: Sendable, Identifiable { public let id: EntryID; public let rect: CGRect; public let label: String?; public let category: Category; public let shade: Double }

@MainActor final class MonitorLoop {
    func start(settings: MonitorSettings)        // Task loop with ContinuousClock
    func stop()
}
actor GrowthTracker {
    func baseline(for roots: [String]) async throws
    func check() async throws -> [GrowthAlert]   // compares current cheap probes with watch_baselines
}
```

**Tests / exit criteria**

| Test | Assertion |
|------|-----------|
| T4-TREEMAP-LAYOUT | 10 k children → layout ≤ 16 ms (release), total area == rect area ± 1 pt², no overlaps (sweep test), culled cells < 3×3 pt. |
| T4-TREEMAP-HIT | random points → `grid.hit(point)` equals brute-force search. |
| T4-TABLE-1M | `FileTableController` with 1 M rows scrolls (XCUITest swipe) without > 100 ms main-thread stalls (measured via `os_signpost` + `xctrace` in local run; CI asserts no crash and ≤ 2 s to first paint). |
| T4-SMARTCLEAN-FLOW (XCUITest) | fixture home via `RECLAIM_HOME_OVERRIDE` env → open Smart Clean → counts match CLI manifest → Dry run sheet → Clean (Trash) → History shows operation → Restore. |
| T4-FDA-ONBOARDING | with `RECLAIM_FAKE_FDA=denied` the step shows guidance; with `granted` it advances. |
| T4-MONITOR-THRESHOLD | fake `VolumeStats` below threshold → notification request issued (mock center); growth fixture → alert text includes delta bytes. |
| T4-MONITOR-BUDGET (local) | 10-minute idle run: RSS ≤ 30 MB, CPU ≤ 0.1%. |
| T4-A11Y | every interactive element has a label (XCUITest audit `performAccessibilityAudit()`). |
| T4-KEYBOARD | shortcuts in §5.9 trigger their actions (unit tests on `Shortcuts` mapping + UI smoke). |

### Phase 5 — Privileged helper, packaging, notarization, release (2 weeks)

**Goal:** Root-only operations via SMAppService helper; signed, notarized DMG; update channel; release checklist.

**Files**

```
Packages/ReclaimKit/Sources/ReclaimXPC/{HelperProtocol.swift, HelperRequests.swift, HelperAllowlist.swift, CodeRequirement.swift}
Apps/Reclaim/Helper/ReclaimHelper/{main.swift, HelperService.swift, ListenerDelegate.swift, Deleter.swift (fd-based, reuses ReclaimSafety.DeletionEngine core), SnapshotDeleter.swift (tmutil), HelperLog.swift}
Apps/Reclaim/Sources/ReclaimApp/Helper/{HelperClient.swift (NSXPCConnection, timeouts, version check), HelperInstaller.swift (SMAppService)}
Config/LaunchDaemons/com.olawale.reclaim.helper.plist
Scripts/{sign.sh, notarize.sh, make-dmg.sh, verify-signing.sh}
.github/workflows/release.yml
docs/RELEASE_CHECKLIST.md  docs/SECURITY.md
```

**HelperProtocol (`@objc`, XPC-safe types only)**

```swift
@objc public protocol HelperProtocol {
    func version(reply: @escaping (String, Int) -> Void)                                      // semver, protocolVersion
    func deleteLocalSnapshots(_ names: [String], reply: @escaping (NSNumber /*count*/, NSError?) -> Void)   // names filtered again by deny-prefix
    func removeRootOwned(_ requests: [NSDictionary], reply: @escaping (NSArray /*[ItemResultDict]*/, NSError?) -> Void)
        // each: path, dev, ino, kind; prefix must match HelperAllowlist.rootDeletePrefixes
    func removeDeletedUserHome(_ name: String, dev: NSNumber, ino: NSNumber, reply: @escaping (NSArray, NSError?) -> Void)
    func removeCryptexBundle(_ uuid: String, reply: @escaping (NSNumber, NSError?) -> Void)   // verifies not mounted via getmntinfo and not referenced (client passes simctl JSON; helper re-checks mount only)
    func removeLegacyHomebrewPrefix(_ requests: [NSDictionary], reply: @escaping (NSArray, NSError?) -> Void)
}
```

**Signing/notarization steps (Scripts/sign.sh → notarize.sh → make-dmg.sh)**

1. `xcodebuild -workspace Reclaim.xcworkspace -scheme Reclaim -configuration Release archive -archivePath build/Reclaim.xcarchive` with `CODE_SIGN_IDENTITY="Developer ID Application: <Name> (TEAMID)"`, `OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime"`, helper and CLI signed with the same identity (embedded products are signed inside-out by Xcode; `verify-signing.sh` runs `codesign --verify --deep --strict` and `spctl -a -vv -t exec`).
2. Export with `exportOptions.plist` (`method: developer-id`).
3. `hdiutil create -volname Reclaim -srcfolder build/export/Reclaim.app -ov -format UDZO build/Reclaim-<version>.dmg`; sign the DMG.
4. `xcrun notarytool submit build/Reclaim-<version>.dmg --keychain-profile "AC_NOTARY" --wait`; `xcrun stapler staple` both the `.app` (before DMG creation) and the `.dmg`.
5. Sparkle appcast generation (if enabled) with EdDSA signature; our own Sparkle cache excluded from `app.updater.sparkle`.

**Entitlements:** `Reclaim.entitlements`: hardened runtime only (no sandbox). No `com.apple.security.automation.apple-events` (we use `NSRunningApplication`, not AppleScript). Helper: hardened runtime; no extra entitlements. Info.plist: `LSMinimumSystemVersion 14.0`, `NSUserNotificationsUsageDescription`, `SMPrivilegedExecutables` **not** used (legacy), `LSUIElement` false.

**Tests / exit criteria**

| Test | Assertion |
|------|-----------|
| T5-HELPER-ALLOWLIST (`.requiresAdmin`) | requests outside prefixes rejected with `notAllowlisted`; symlinked component rejected; identity mismatch rejected; mount point rejected. |
| T5-HELPER-SNAPSHOTS (`.requiresAdmin`) | `com.apple.os.update-*` names refused even if passed; TM snapshot names accepted (dry-run flag in helper for tests: `RECLAIM_HELPER_DRYRUN=1`). |
| T5-XPC-REQUIREMENT | unsigned/ad-hoc test client connection refused (`shouldAcceptNewConnection == false`). |
| T5-HELPER-VERSION | protocol mismatch → app shows reinstall prompt; `register()` path exercised with `SMAppService` status fake. |
| T5-TM-FILTER | adapter parsing of `tmutil listlocalsnapshots` output lines (`com.apple.TimeMachine.2026-10-30-120000.local`) and deny filter. |
| T5-SIGNING | `verify-signing.sh` passes; `spctl` accepts; `stapler validate` OK (release workflow). |
| T5-INSTALL-SMOKE (local) | fresh user account: onboarding → FDA → helper approval → Smart Clean dry run → clean 1 fixture → History restore. |

### Post-v1 backlog (Informative)

Clone-convert duplicates (`clonefile`), OrbStack/Colima adapters, iCloud "evict local copy" (`brctl evict`), per-app uninstaller, scheduled Smart Clean, Spotlight-based large-file prefilter, Shortcuts app actions, localization.

---

## 7. Appendices

### Appendix A — Path registry constants (ReclaimRules/Environment/KnownPaths.swift)

```swift
enum KnownPaths {
    static let home = NSHomeDirectory()
    static let library = home + "/Library"
    static let caches = library + "/Caches"
    static let appSupport = library + "/Application Support"
    static let containers = library + "/Containers"
    static let groupContainers = library + "/Group Containers"
    static let developer = library + "/Developer"
    static let xcode = developer + "/Xcode"
    static let derivedData = xcode + "/DerivedData"
    static let deviceSupport = [xcode + "/iOS DeviceSupport", xcode + "/watchOS DeviceSupport", xcode + "/tvOS DeviceSupport", xcode + "/visionOS DeviceSupport"]
    static let archives = xcode + "/Archives"
    static let previews = xcode + "/UserData/Previews/Simulator Devices"
    static let coreSimulatorUser = developer + "/CoreSimulator"
    static let coreSimulatorSystem = "/Library/Developer/CoreSimulator"
    static let simRuntimeVolumes = coreSimulatorSystem + "/Volumes"
    static let simCryptexBundles = coreSimulatorSystem + "/Cryptex/Images/bundle"
    static let dockerContainer = containers + "/com.docker.docker"
    static let dockerRaw = dockerContainer + "/Data/vms/0/data/Docker.raw"
    static let dockerSocket = home + "/.docker/run/docker.sock"
    static let whatsAppShared = groupContainers + "/group.net.whatsapp.WhatsApp.shared"
    static let whatsAppMedia = whatsAppShared + "/Message/Media"
    static let whatsAppChatDB = whatsAppShared + "/ChatStorage.sqlite"
    static let telegramGroup = groupContainers + "/6N38VWS5BX.ru.keepcoder.Telegram"
    static let telegramMediaGlob = telegramGroup + "/appstore/account-*/postbox/media"
    static let claudeSupport = appSupport + "/Claude"
    static let claudeVMBundle = claudeSupport + "/vm_bundles/claudevm.bundle"
    static let cursorSupport = appSupport + "/Cursor"
    static let vscodeSupport = appSupport + "/Code"
    static let chromeSupport = appSupport + "/Google/Chrome"
    static let androidAVD = home + "/.android/avd"
    static let gradleHome = home + "/.gradle"
    static let npmCache = home + "/.npm/_cacache"
    static let yarnCache = caches + "/Yarn"
    static let cargoHome = home + "/.cargo"
    static let goPath = home + "/go"
    static let ollamaModels = home + "/.ollama/models"
    static let hfHub = home + "/.cache/huggingface/hub"
    static let deletedUsers = "/Users/Deleted Users"
    static let legacyBrewPrefix = "/usr/local"
    static let firmlinksTable = "/usr/share/firmlinks"
    static let dataVolume = "/System/Volumes/Data"
}
```

### Appendix B — Bundle identifiers referenced by rules

| App | Bundle ID |
|-----|-----------|
| WhatsApp | `net.whatsapp.WhatsApp` |
| Telegram (App Store) | `ru.keepcoder.Telegram` |
| Claude Desktop | `com.anthropic.claudefordesktop` |
| Cursor | `com.todesktop.230313mzl4w4u92` |
| Visual Studio Code | `com.microsoft.VSCode` |
| Docker Desktop | `com.docker.docker` |
| Xcode | `com.apple.dt.Xcode` |
| Android Studio | `com.google.android.studio` |
| IntelliJ IDEA | `com.jetbrains.intellij` |
| Google Chrome | `com.google.Chrome` |
| Brave | `com.brave.Browser` |
| Arc | `company.thebrowser.Browser` |
| Firefox | `org.mozilla.firefox` |
| Slack | `com.tinyspeck.slackmacgap` |
| Discord | `com.hnc.Discord` |
| Postman | `com.postmanlabs.mac` |
| Figma | `com.figma.Desktop` |
| Lens | `com.electron.kontena-lens` |
| Spotify | `com.spotify.client` |
| OBS Studio | `com.obsproject.obs-studio` |
| Ollama | `com.electron.ollama` |
| Reclaim (self) | `com.olawale.reclaim` |

### Appendix C — SQLite schema (ReclaimPersistence/SQLite/Migrations.swift, version 1)

```sql
CREATE TABLE schema_version (version INTEGER NOT NULL);
INSERT INTO schema_version VALUES (1);

CREATE TABLE scans (
  id TEXT PRIMARY KEY, started_at REAL NOT NULL, finished_at REAL, roots TEXT NOT NULL,
  entry_count INTEGER, bytes_allocated INTEGER, bytes_private INTEGER, completeness TEXT NOT NULL,
  snapshot_path TEXT, app_version TEXT NOT NULL
);

CREATE TABLE operations (
  id TEXT PRIMARY KEY, scan_id TEXT REFERENCES scans(id), created_at REAL NOT NULL, started_at REAL, finished_at REAL,
  tier TEXT NOT NULL CHECK (tier IN ('dryRun','trash','permanent')),
  status TEXT NOT NULL CHECK (status IN ('planned','in_progress','done','partial','failed','restored')),
  rule_ids TEXT NOT NULL, estimated_allocated INTEGER NOT NULL, estimated_private INTEGER NOT NULL,
  measured_freed INTEGER, approval_token TEXT, initiated_by TEXT NOT NULL CHECK (initiated_by IN ('app','cli','monitor'))
);

CREATE TABLE operation_items (
  id TEXT PRIMARY KEY, operation_id TEXT NOT NULL REFERENCES operations(id) ON DELETE CASCADE,
  rule_id TEXT, original_path TEXT NOT NULL, canonical_path TEXT NOT NULL, trash_path TEXT,
  dev INTEGER NOT NULL, ino INTEGER NOT NULL, kind TEXT NOT NULL,
  logical INTEGER NOT NULL, allocated INTEGER NOT NULL, private_bytes INTEGER NOT NULL,
  action TEXT NOT NULL, result TEXT NOT NULL CHECK (result IN ('pending','ok','skipped','failed','restored')),
  errno INTEGER, error_message TEXT, reason TEXT NOT NULL, executed_at REAL, restored_at REAL
);
CREATE INDEX idx_items_op ON operation_items(operation_id);
CREATE INDEX idx_items_path ON operation_items(canonical_path);

CREATE TABLE rule_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT, scan_id TEXT REFERENCES scans(id), rule_id TEXT NOT NULL,
  evaluated_at REAL NOT NULL, item_count INTEGER NOT NULL, total_allocated INTEGER NOT NULL, total_private INTEGER NOT NULL,
  blocked_count INTEGER NOT NULL, duration_ms INTEGER NOT NULL, error TEXT
);

CREATE TABLE watch_baselines (
  root TEXT PRIMARY KEY, measured_at REAL NOT NULL, allocated INTEGER NOT NULL, entry_count INTEGER, mtime REAL
);

CREATE TABLE duplicate_groups (
  id TEXT PRIMARY KEY, scan_id TEXT REFERENCES scans(id), sha256 TEXT NOT NULL, size INTEGER NOT NULL, paths TEXT NOT NULL, confirmed INTEGER NOT NULL
);

CREATE TABLE settings_kv (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at REAL NOT NULL);
```

### Appendix D — User rule JSON schema (docs/schemas/user-rule.schema.json, abbreviated)

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["id","title","summary","rationale","regeneration","risk","category","locator","action"],
  "properties": {
    "id": { "type": "string", "pattern": "^user\\.[a-z0-9-]+(\\.[a-z0-9-]+)+$" },
    "title": { "type": "string", "maxLength": 80 },
    "summary": { "type": "string", "maxLength": 200 },
    "rationale": { "type": "string" },
    "regeneration": { "type": "string" },
    "risk": { "enum": ["low","medium","high"] },
    "category": { "enum": ["caches","appData","developer","documentsMedia","messagingMedia"] },
    "ownerBundleIDs": { "type": "array", "items": { "type": "string" } },
    "locator": {
      "oneOf": [
        { "type": "object", "required": ["paths"], "properties": { "paths": { "type": "array", "items": { "type": "string", "pattern": "^(~/|\\$ANDROID_HOME/|\\$TMPDIR/)" } } } },
        { "type": "object", "required": ["glob"], "properties": { "glob": { "type": "object", "required": ["root","pattern"] } } }
      ]
    },
    "eligibility": { "$ref": "#/$defs/predicate" },
    "action": { "enum": ["trash","reportOnly"] }
  },
  "$defs": {
    "predicate": {
      "oneOf": [
        { "type": "object", "required": ["olderThan"], "properties": { "olderThan": { "type": "object", "required": ["days"], "properties": { "days": { "type": "integer", "minimum": 1 }, "clock": { "enum": ["mtime","projectActivity"] } } } } },
        { "type": "object", "required": ["largerThan"], "properties": { "largerThan": { "type": "object", "required": ["bytes"], "properties": { "bytes": { "type": "integer" }, "basis": { "enum": ["allocated","privateBytes"] } } } } },
        { "type": "object", "required": ["appNotRunning"] },
        { "type": "object", "required": ["nameMatches"], "properties": { "nameMatches": { "type": "string" } } },
        { "type": "object", "required": ["all"], "properties": { "all": { "type": "array", "items": { "$ref": "#/$defs/predicate" } } } },
        { "type": "object", "required": ["any"], "properties": { "any": { "type": "array", "items": { "$ref": "#/$defs/predicate" } } } },
        { "type": "object", "required": ["not"], "properties": { "not": { "$ref": "#/$defs/predicate" } } }
      ]
    }
  }
}
```

### Appendix E — Manual command cookbook (what the app replaces; Informative)

```bash
# Free space truth
statfs-equivalent: df -k /System/Volumes/Data ; diskutil info / | grep "Container Free Space"
# Biggest children (allocated)
du -sh ~/Library/* 2>/dev/null | sort -rh | head -20
# Sparse check
ls -lh FILE ; du -sh FILE
# Simulators
xcrun simctl list runtimes ; xcrun simctl runtime list -j ; xcrun simctl runtime delete <build> ; xcrun simctl delete unavailable
# Docker
docker system df -v ; docker image prune -f ; docker builder prune -f ; docker volume ls -f dangling=true ; docker volume rm <name>
# Android
avdmanager list avd -c ; avdmanager delete avd -n <name>
# Snapshots (root)
tmutil listlocalsnapshots / ; sudo tmutil deletelocalsnapshots <name>
# Homebrew
brew cleanup --prune=all -n ; brew cleanup --prune=all
# Open files under a path
lsof +D <path>   # app uses proc_listpidspath instead
```

### Appendix F — Risk register

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| `getattrlistbulk` field-order bug silently corrupts sizes | Medium | High | T1-BULK-PARITY against `fstatat` on every CI run; fuzz with random attribute subsets. |
| TCC behavior changes in a macOS update (probe paths) | Medium | Medium | Probe set is data-driven; `doctor` reports `undetermined`; fallback to EPERM counting during scan. |
| Helper attributed as separate TCC subject (EC-03) | High | Medium | Helper scope avoids TCC-protected user data; UI explains residuals; document in SECURITY.md. |
| User deletes WhatsApp media still needed offline | Medium | Medium | Low-risk tier, per-chat selection, names resolved, "re-downloadable while on server" note, Trash tier default. |
| Docker.raw reset destroys needed images | Low | High | High tier, requires daemon stopped + last `system df` empty or typed acknowledgment; suggests `prune` first. |
| Treemap performance on 100k-child directories | Medium | Low | LOD + culling; fallback to CALayer; children paging. |
| SQLite ledger corruption | Low | Medium | WAL + `synchronous=NORMAL`, integrity check on open, auto-backup before migrations. |
| Simulator runtime deletion while Xcode uses it | Low | Medium | Block when Xcode running or any device on that runtime booted; `simctl` itself refuses in-use runtimes. |
| Sparkle/ShipIt rule deletes an in-progress update | Low | Low | `olderThan(1d)` + app-not-running. |

### Appendix G — Open questions (to resolve during Phase 0/1)

1. Exact kernel attribution of `ATTR_CMNEXT_PRIVATESIZE` between original and clone (which side reports the shared blocks as private) — decide rollup semantics from T1-SIZE-CLONE measurements and document in `docs/ADR/ADR-011-clone-accounting.md`.
2. Whether `getattrlistbulk` returns `ATTR_DIR_MOUNTSTATUS` reliably for firmlink targets and synthetic mounts; if not, rely on `st_dev` change + `getmntinfo`.
3. Whether `NSWorkspace.recycle` of 100 k items in 500-item batches keeps Finder responsive; else use `FileManager.trashItem(at:)` per item on a background queue.
4. Sparkle inclusion in v1 vs manual download updates (affects `app.updater.*` self-exclusion and notarization steps).
5. Default scan roots: full Data volume (recommended, ~25 s) vs home + `/Library/Developer` + `/Applications` (faster) — ship full by default with a "quick scan" option.

---

*End of PLAN.md.*
