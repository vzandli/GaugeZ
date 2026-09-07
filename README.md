<div align="center">

<img src="GaugeZ/Assets.xcassets/AppIcon.appiconset/GaugeZ-AppIcon-256.png" width="128" alt="GaugeZ icon">

# GaugeZ

**Your AI subscription limits, one glance away.**

A native macOS edge rail that shows how much of your Claude, Codex, Cursor, Antigravity, GLM,
Grok Build, and OpenCode quota is left, on any screen edge.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI%20%2B%20AppKit-F05138?logo=swift&logoColor=white)](#building-from-source)
[![Updates](https://img.shields.io/badge/updates-Sparkle-4A90E2)](#updates)
[![Release](https://img.shields.io/github/v/release/vzandli/GaugeZ?display_name=tag&color=6C5CE7)](https://github.com/vzandli/GaugeZ/releases/latest)

<br>

<img src="docs/screenshot.png" width="720" alt="GaugeZ edge rail on the right edge with Claude, Cursor, Codex, Antigravity, Grok Build, and GLM rings, and the Antigravity detail card showing Claude/GPT and Gemini 5-hour and weekly limits">

</div>

---

## Why

Every AI tool keeps its usage meter somewhere different: a settings pane, a web dashboard,
a CLI command. When you juggle several subscriptions, you end up guessing how close you
are to a limit until the moment you hit it.

GaugeZ puts all of those meters in one quiet rail at the edge of your screen. Hover to
expand it, glance at the rings, and get back to work.

## Features

- **Edge rail, not a window.** A slim tab lives on any edge of your chosen display
  and expands on hover. It never steals focus and follows you across Spaces.
- **Remaining, never used.** The compact number is always what you have *left*. When a
  provider has several windows, the rail shows the most constrained one by default. Pick a
  particular window or model in its detail card, which names the headline window and lists
  all windows with absolute and relative reset times.
- **Honest states.** Live, stale, signed out, permission needed, and unavailable are
  visually distinct. GaugeZ never turns missing data into `0%`.
- **Liquid Glass.** On macOS 26 the rail uses native glass with a 0 to 100 percent
  transparency slider. Older systems get a clean solid surface.
- **Menu bar companion.** Toggle the rail, refresh, open settings, or check for updates
  from the status item. An update found while GaugeZ is in the background is announced
  there instead of in an alert you might not see.
- **Multiple Claude Code accounts.** Used `~/.claude-*` profiles are discovered at launch,
  with separate rings, session lists, settings, cached readings, and retry deadlines.
  The default Claude ring keeps its Desktop/CLI source choice. Extra profiles always read
  their own Claude Code sign-in. Enable newly added profiles in Settings after upgrading.
- **Session activity.** Opt in to Claude Code, Cursor, Grok Build, Codex, and Antigravity
  activity from local metadata. Cards show session names, projects, waiting reasons, and how
  long each session has been in its state. Claude and Grok Build records require a verifiable
  running process, and a Grok Build session reads as working only while its update log was
  written within the last 45 seconds; Cursor working states require a running editor and a
  write within 15 minutes, after its current launch when the launch time is available. Codex
  and Antigravity publish no status, so their working state is inferred from a write to their
  local logs within the last few seconds and labeled as inferred. Long session lists are capped
  to what the display can hold, with "and N more" for the rest.
- **Accounts that fit.** When enabled accounts exceed the display's available space,
  a page control in the drag handle lets you cycle through them on any edge.
- **Make it yours.** Reorder providers, choose a persistent display, position the rail on
  any of its four edges, and enable launch at login. All edges share the same curved rail,
  settings orb, colored collapsed tab, and drag handle; horizontal text stays upright. Choose
  whether GaugeZ shows a Dock icon, a menu bar icon, or neither; relaunching it from
  Applications always brings Settings back.
- **Joins a MacBook's notch.** On the top edge of a display with a hardware notch, the rail
  centers under the notch and shows nothing at rest. Reaching the notch with the pointer opens
  it, and the rail hangs beneath the menu bar rather than covering it.
- **What's new.** The first launch after an update shows what changed in that version.
- **Keyboard access.** Choose **Usage…** in the menu bar for a regular, focusable usage
  window. Surfaces respect Reduce Transparency and Increase Contrast.
- **Diagnostics.** See each reading’s source, observation time, and next retry. Retry a
  provider (which also re-asks for a previously denied Keychain read), open its app, or
  forget its cached reading.
- **Automatic updates.** Signed and verified with Sparkle. See [Updates](#updates).

## Providers

| Provider | Where the numbers come from |
| --- | --- |
| **Claude** | The usage log kept by the Claude desktop app, or the Claude Code sign-in stored in your Keychain. |
| **Codex** | The app-server bundled with Codex, ChatGPT, or an installed `codex` CLI, over a local process. Without one, the CLI's ChatGPT sign-in in `~/.codex/auth.json` is used to read the same usage endpoint Codex calls. |
| **Cursor** | Cursor's local sign-in, used to ask cursor.com for your plan usage. |
| **Antigravity** | The language server of a running Antigravity app or IDE, asked for its model quotas. |
| **GLM** | Z.ai Coding Plan usage, using a readable key held by Claude Code, ZCode, or OpenCode; supports global and China consoles. |
| **Grok Build** | The xAI account sign-in in `~/.grok/auth.json`, asked via its billing service for allowance and on-demand spend. |
| **OpenCode** | The Go plan's official usage endpoint, with the `opencode-go` key OpenCode stores in `~/.local/share/opencode/auth.json` on sign-in. |

Each provider and Claude profile can be switched off independently in Settings, and a
failure in one never affects the others. New providers and profiles start disabled for
existing installations, preserving your enabled-provider choices.

GLM reads the default Claude Code `settings.json`, ZCode's plan configuration or readable
credential file, then OpenCode's auth file. Encrypted ZCode credentials are skipped.
Custom Claude directories are discovered through the `~/.claude-<name>` convention;
arbitrary `CLAUDE_CONFIG_DIR` paths outside that convention are not discovered.

## Privacy

GaugeZ is a local companion app.

- It talks only to the providers you enable, using the sign-in those apps already have.
- Tokens are never written to disk or logged. Claude Code credentials are cached in
  memory until their Keychain item changes or you explicitly retry/forget the reading.
  Duplicate Keychain entries are resolved by modification time, within the selected profile.
  A denied secret read is not repeated by automatic polling while that item is unchanged.
- Optional activity monitoring reads Claude Code session metadata, Cursor composer
  headers, Grok Build's active-session list and session titles, Codex's thread catalogue
  and rollout timestamps, and Antigravity transcript timestamps locally without persisting
  them. It does not read conversation transcripts or rollout contents. The Grok Build card also
  reads the token and cost totals from the latest session's local update log.
- Open Grok Build starts the installed `grok` CLI in Terminal, which asks for Automation
  permission the first time. Nothing else launches or scripts other apps.
- No analytics, no telemetry, no accounts. The only outbound connection GaugeZ makes on
  its own is the update check against this repository's releases.

## Requirements

- macOS 14 Sonoma or later. Liquid Glass surfaces need macOS 26.
- The provider apps you want to track installed and signed in.

## Install

1. Download the latest `GaugeZ-x.y.zip` from the
   [Releases page](https://github.com/vzandli/GaugeZ/releases/latest).
2. Unzip and move **GaugeZ.app** to your Applications folder.
3. Launch it. GaugeZ appears in the menu bar and as a small tab on the screen edge.

The app is signed with a Developer ID certificate and notarized by Apple, so it opens
without Gatekeeper warnings.

## Updates

GaugeZ checks for updates automatically and can be checked manually from the menu bar or
**Settings → Updates**. Because GaugeZ has no Dock presence, a scheduled check that finds
an update shows an alert only when GaugeZ already has focus; otherwise the menu bar item
changes to **Update to x.y.z Available…** until you choose it. Every update is signed with
an EdDSA key and verified before it is installed, and the feed is served straight from
GitHub Releases.

## Building from source

```bash
git clone https://github.com/vzandli/GaugeZ.git
cd GaugeZ
open GaugeZ.xcodeproj
```

Select the **GaugeZ** scheme and run. Xcode resolves the single dependency,
[Sparkle](https://github.com/sparkle-project/Sparkle), through Swift Package Manager.
The project opens in Xcode 26.6 or later.

Run the fixture-based provider regression checks without accessing real credentials:

```sh
./scripts/test-providers.sh
```

Or from the terminal:

```bash
xcodebuild -project GaugeZ.xcodeproj -scheme GaugeZ -configuration Release build
```

## Project layout

```
GaugeZ/
├── GaugeZApp.swift             App delegate, menu bar item, settings window
├── EdgePanelController.swift   Borderless edge panel, hover ownership, placement
├── EdgeViews.swift             Side rail, shared geometry, shapes, and hover attachments
├── HorizontalRailView.swift    Top and bottom placement
├── ProviderMeterView.swift     Quota ring and activity badge
├── UsageDetailCard.swift       Window selection, quota details, and session activity
├── AttachedSettingsView.swift  Compact rail settings
├── RailSurfaces.swift          Glass and accessible surface rendering
├── UsageOverviewView.swift     Keyboard-accessible usage window
├── WhatsNewView.swift          Once-per-version release notes window
├── ReleaseNotes.swift          The notes it shows, checked against MARKETING_VERSION by the tests
├── AppPresence.swift           Dock, menu bar, or neither
├── ActivityReader.swift        Opt-in Claude Code, Cursor, and Grok Build session metadata
├── ProviderRetryPolicy.swift   Persistent per-provider rate-limit backoff
├── ContentView.swift           Settings: Providers, Appearance, Diagnostics, Updates
├── UsageStore.swift            Refresh scheduling, cache policy, normalized snapshots
├── UsageModels.swift           Provider IDs (including Claude profiles), windows, health states
├── ClaudeProfile.swift         ~/.claude-* discovery and per-profile Keychain service names
├── ClaudeKeychain.swift        Metadata-first Keychain reads and the in-memory credential cache
├── GLMCredentials.swift        Z.ai key discovery across Claude Code, ZCode, and OpenCode
├── *UsageProvider.swift        One adapter per provider
├── UpdateManager.swift         Sparkle integration with gentle background reminders
└── GaugeZ.entitlements         Apple Events automation for Open Grok Build
Tests/                          Fixture-based provider regression checks
scripts/test-providers.sh       Compiles the adapters with the checks and runs them
```

## Contributing

Issues and pull requests are welcome. If you are adding a provider, keep the adapter
self-contained, decode defensively, and surface an explicit health state instead of a
guessed number when the upstream format changes.

## Thanks

GLM credential discovery and the OpenCode adapter include code adapted from Codenotch (MIT);
see [Third-party notices](GaugeZ/ThirdPartyNotices.txt).

Design inspiration for the edge rail came from [@hivinz_](https://x.com/hivinz_). Thank you.

## Refresh behavior

GaugeZ coalesces refreshes per provider. Automatic reads run roughly every minute while
its rail is expanded or a monitored session is working/waiting, and every five minutes
otherwise. Claude and Grok Build are polled at most every five minutes because their usage
endpoints rate-limit faster polling. With the desktop app as Claude source, its local usage
log is used while it is under five minutes old and the endpoint otherwise, since the desktop
app only samples about every 15 minutes and does not see Claude Code or web usage until its
next sample. GaugeZ also refreshes after wake and network recovery. Claude, Cursor, Codex, GLM, and
Grok Build retry penalties survive relaunches, increase after repeated throttling, and honor
server retry deadlines up to 15 minutes. The last good reading stays
on screen during a backoff, during a Keychain refusal, and through the brief window after waking
from sleep when the Keychain cannot answer yet. Forgetting a reading, disabling a provider, or switching the Claude source clears
its penalty. Passing a reset time marks an old reading stale until the provider confirms its
new value.

For a local visual preview without provider reads or update checks (add
`GAUGEZ_PREVIEW_PROFILES=4` to preview several Claude profiles and rail paging):

```sh
GAUGEZ_PREVIEW_DATA=1 GAUGEZ_DEBUG_DEMO=1 GAUGEZ_DEBUG_EDGE=top /path/to/GaugeZ.app/Contents/MacOS/GaugeZ
```
