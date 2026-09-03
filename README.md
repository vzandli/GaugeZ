<div align="center">

<img src="GaugeZ/Assets.xcassets/AppIcon.appiconset/GaugeZ-AppIcon-256.png" width="128" alt="GaugeZ icon">

# GaugeZ

**Your AI subscription limits, one glance away.**

A native macOS edge rail that shows how much of your Claude, Codex, Cursor, and Antigravity
quota is left, right at the side of your screen.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI%20%2B%20AppKit-F05138?logo=swift&logoColor=white)](#building-from-source)
[![Updates](https://img.shields.io/badge/updates-Sparkle-4A90E2)](#updates)
[![Release](https://img.shields.io/github/v/release/vzandli/GaugeZ?display_name=tag&color=6C5CE7)](https://github.com/vzandli/GaugeZ/releases/latest)

</div>

---

## Why

Every AI tool keeps its usage meter somewhere different: a settings pane, a web dashboard,
a CLI command. When you juggle several subscriptions, you end up guessing how close you
are to a limit until the moment you hit it.

GaugeZ puts all of those meters in one quiet rail at the edge of your screen. Hover to
expand it, glance at the rings, and get back to work.

## Features

- **Edge rail, not a window.** A slim tab lives on the left or right edge of your screen
  and expands on hover. It never steals focus and follows you across Spaces.
- **Remaining, never used.** The compact number is always what you have *left*. When a
  provider has several windows, the rail shows the most constrained one and the detail
  card lists them all with absolute and relative reset times.
- **Honest states.** Live, stale, signed out, permission needed, and unavailable are
  visually distinct. GaugeZ never turns missing data into `0%`.
- **Liquid Glass.** On macOS 26 the rail uses native glass with a 0 to 100 percent
  transparency slider. Older systems get a clean solid surface.
- **Menu bar companion.** Toggle the rail, refresh, open settings, or check for updates
  from the status item.
- **Diagnostics.** See exactly where every value came from and when it was last observed.
- **Automatic updates.** Signed and verified with Sparkle. See [Updates](#updates).

## Providers

| Provider | Where the numbers come from |
| --- | --- |
| **Claude** | The usage log kept by the Claude desktop app, or the Claude Code sign-in stored in your Keychain. |
| **Codex** | The Codex app-server bundled with the ChatGPT app, over a local process. |
| **Cursor** | Cursor's local sign-in, used to ask cursor.com for your plan usage. |
| **Antigravity** | The language server of a running Antigravity app or IDE, asked for its model quotas. |

Each provider can be switched off independently in Settings, and a failure in one never
affects the others.

## Privacy

GaugeZ is a local companion app.

- It talks only to the providers you enable, using the sign-in those apps already have.
- Tokens stay in memory for the duration of a request. They are never written to disk
  or logged.
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
**Settings → Updates**. Every update is signed with an EdDSA key and verified before it
is installed, and the feed is served straight from GitHub Releases.

## Building from source

```bash
git clone https://github.com/vzandli/GaugeZ.git
cd GaugeZ
open GaugeZ.xcodeproj
```

Select the **GaugeZ** scheme and run. Xcode resolves the single dependency,
[Sparkle](https://github.com/sparkle-project/Sparkle), through Swift Package Manager.
The project opens in Xcode 26.6 or later.

Or from the terminal:

```bash
xcodebuild -project GaugeZ.xcodeproj -scheme GaugeZ -configuration Release build
```

## Project layout

```
GaugeZ/
├── GaugeZApp.swift             App delegate, menu bar item, settings window
├── EdgePanelController.swift   Borderless edge panel, hover ownership, placement
├── EdgeViews.swift             Rail, provider rings, detail cards, glass surfaces
├── ContentView.swift           Settings: Providers, Appearance, Diagnostics, Updates
├── UsageStore.swift            Refresh scheduling, cache policy, normalized snapshots
├── UsageModels.swift           Provider IDs, windows, health states
├── *UsageProvider.swift        One adapter per provider
└── UpdateManager.swift         Sparkle integration
```

## Contributing

Issues and pull requests are welcome. If you are adding a provider, keep the adapter
self-contained, decode defensively, and surface an explicit health state instead of a
guessed number when the upstream format changes.
