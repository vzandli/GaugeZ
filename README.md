<div align="center">

<img src="GaugeZ/Resources/Assets.xcassets/AppIcon.appiconset/GaugeZ-AppIcon-256.png" width="128" alt="GaugeZ icon">

# GaugeZ

**Your AI subscription limits, one glance away.**

A native macOS edge rail showing remaining quota for Claude, Codex, Cursor, Antigravity,
GLM, Grok Build, OpenCode, GitHub Copilot, Kimi, Command Code, Devin, Kiro, Ollama, MiniMax,
and the Gemini API.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI%20%2B%20AppKit-F05138?logo=swift&logoColor=white)](#building)
[![Updates](https://img.shields.io/badge/updates-Sparkle-4A90E2)](#updates)
[![Release](https://img.shields.io/github/v/release/vzandli/GaugeZ?display_name=tag&color=6C5CE7)](https://github.com/vzandli/GaugeZ/releases/latest)

<br>

<img src="docs/screenshot.png" width="720" alt="GaugeZ edge rail with provider rings and a detail card">

</div>

---

## Overview

Every AI tool keeps its usage meter somewhere different. GaugeZ collects them into one
rail on the edge of your screen. Hover to expand it, read the rings, get back to work.

- **Edge rail, not a window.** A slim tab on any edge of any display. It expands on hover,
  never steals focus, and follows you across Spaces. Drag its handle and it follows you
  along any edge and flows round the corners. On a MacBook it joins the hardware notch, with
  small rings either side of the camera while it rests.
- **Remaining, never used.** Each ring shows what is left in the most constrained window.
  The detail card lists every window with its reset time, and whether you are spending
  faster or slower than the window is passing. Claude can lead with a daily budget: a
  seventh of the weekly limit per day.
- **Honest states.** Live, stale, signed out, permission needed, and unavailable are
  distinct. Missing data is never shown as `0%`.
- **Limit events.** The rail opens a card when a window reaches 0% remaining and again when
  it rolls over, with optional chimes; system notifications fire at warning and critical
  levels you choose (20% and 0% remaining by default).
  All of it is tuned in **Settings → Notifications** and mutable per provider.
- **Session activity.** Optional. See which Claude Code, Cursor, Grok Build, Codex, and
  Antigravity sessions are working, waiting, or idle. The rail can peek and chime when a
  session finishes or needs input, and clicking it lands on the session's own terminal tab
  in Terminal.app, iTerm2, Ghostty, and cmux.
- **Multiple Claude Code accounts.** Each `~/.claude-*` profile gets its own ring.
- **Make it yours.** Reorder and rename accounts, resize the notch, pick an edge and display
  or carry the rail to another edge, hide it over full-screen apps, choose glass or solid and
  stepped or ramped ring colors, show chosen readings in the menu bar, and decide whether
  GaugeZ shows in the Dock, the menu bar, or neither.
- **Automatic updates.** Signed with EdDSA and delivered through Sparkle. A new version is
  offered on the rail with Update and Later.
- **In your language.** English and 21 other languages, switchable in
  **Settings → General** without a restart.

## Providers

| Provider | Source of the reading |
| --- | --- |
| **Claude** | Claude desktop usage log, or the Claude Code sign-in in the Keychain |
| **Codex** | The bundled app-server or `codex` CLI; falls back to the CLI's ChatGPT sign-in |
| **Cursor** | Editor sign-in or the `cursor-agent` token; individual, team, and enterprise plans |
| **Antigravity** | Local language server, then the Google quota endpoint with the saved sign-in |
| **GLM** | Z.ai Coding Plan usage via a key held by Claude Code, ZCode, or OpenCode |
| **Grok Build** | The xAI sign-in in `~/.grok/auth.json`, via its billing service |
| **GitHub Copilot** | `GH_TOKEN`, the `gh` host token, or `gh auth token` |
| **OpenCode** | The Go plan usage endpoint with the key OpenCode stores on sign-in |
| **Kimi** | The Kimi Code usage endpoint with the sign-in the `kimi` CLI keeps in `~/.kimi-code` |
| **Command Code** | The billing endpoints with the sign-in in `~/.commandcode` |
| **Devin** | Devin / Windsurf plan status with the editor's local sign-in, or the `devin` CLI's |
| **Kiro** | Monthly credits as `kiro-cli` reports them |
| **Ollama** | Ollama cloud usage with an API key you paste in Settings, or `OLLAMA_API_KEY` |
| **MiniMax** | Coding Plan usage with a key you paste in Settings |
| **Gemini API** | Tokens counted from local Gemini CLI, OpenCode, and Hermes logs against a monthly budget you set |

Providers are independent. A failure in one never affects another, and each can be
switched off in Settings. New providers start disabled on existing installations.

## Languages

GaugeZ follows your macOS language by default. **Settings → General → Language** picks
one for the app alone, and it applies at once.

Arabic, Bengali, Bosnian, Chinese (Simplified), Chinese (Hong Kong), English, Filipino,
French, German, Hindi, Italian, Japanese, Korean, Marathi, Portuguese (Brazil), Russian,
Spanish, Tamil, Telugu, Turkish, Urdu, and Vietnamese.

## Privacy

GaugeZ is a local companion. It talks only to the providers you enable, using the sign-ins
their apps already hold.

- Borrowed tokens are never written to disk or logged. The only secrets GaugeZ stores are
  API keys you paste yourself (Ollama, MiniMax), kept in your login Keychain and deleted
  when you remove them.
- Keychain items are cached in memory and
  re-read only when they change or you retry.
- Session activity reads local metadata. When Claude supplies no status, GaugeZ reads up to
  64 KB from the end of its local transcript to infer activity. Transcript text is never stored
  by GaugeZ or sent over the network.
- Near expiry, GaugeZ can launch standalone Claude Code with empty input to renew its sign-in;
  no prompt is supplied. Renewal is attempted once per expiry, with a ten-minute cooldown.
- No analytics, telemetry, or accounts. The only outbound call GaugeZ makes on its own is
  the update check against this repository's releases.

## Refresh policy

Reads coalesce per provider: about every minute while the rail is open or a session is
active, every five minutes otherwise, and again after wake or network recovery. Providers
that rate-limit are polled at most every five minutes. Retry backoff persists across
relaunches and honors server deadlines. The last good reading stays on screen during a
backoff and turns stale once its reset time passes.

## Requirements

- macOS 14 Sonoma or later. Liquid Glass surfaces need macOS 26.
- A supported provider signed in on this Mac.

## Install

1. Download `GaugeZ-x.y.z.dmg` from the [latest release](https://github.com/vzandli/GaugeZ/releases/latest).
2. Open it, drag **GaugeZ** to Applications, and launch it.

The app is signed with a Developer ID certificate and notarized by Apple.

## Updates

GaugeZ checks for updates in the background and on demand from the menu bar or
**Settings → Updates**. Every update is verified with an EdDSA signature before it is
installed. The feed is served from GitHub Releases.

## Building

```bash
git clone https://github.com/vzandli/GaugeZ.git
cd GaugeZ
open GaugeZ.xcodeproj
```

Requires Xcode 26.6 or later. Sparkle is the only dependency and resolves through Swift
Package Manager.

Run the fixture-based provider checks without touching real credentials:

```bash
./scripts/test-providers.sh
```

Preview the rail with demo data and no provider reads:

```bash
GAUGEZ_PREVIEW_DATA=1 GAUGEZ_DEBUG_DEMO=1 /path/to/GaugeZ.app/Contents/MacOS/GaugeZ
```

## Layout

```
GaugeZ/
├── App/           App delegate, menu bar, windows, Sparkle, release notes
├── Model/         Usage models, refresh scheduling, retry policy, alerts
├── Providers/     One adapter per provider
├── Credentials/   Keychain and config-file discovery, in-memory secret cache
├── Sessions/      Session activity readers, completion watcher, chimes
├── Rail/          Edge panel, rail geometry, meters, detail and settings cards
├── Windows/       Settings, usage overview, What's New
├── Design/        Brand font and styling
└── Resources/     Assets and third-party notices
Tests/             Provider regression checks
scripts/           Test runner and release publishing
```

## Contributing

Issues and pull requests are welcome. When adding a provider, keep the adapter
self-contained, decode defensively, and report an explicit health state instead of a
guessed number when the upstream format changes.

## Thanks

Claude transcript activity handling, Codex turn detection, usage pace, the full-screen check,
the GitHub Copilot, GLM, Kimi, Command Code, Devin, Kiro, Ollama, MiniMax, and Gemini API rings,
several provider logos, and terminal tab focus on session click are adapted from Codenotch
(MIT); see [Third-party notices](GaugeZ/Resources/ThirdPartyNotices.txt).
Edge rail design inspiration: [@hivinz_](https://x.com/hivinz_).
