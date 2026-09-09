import Foundation

/// What one release changed, in the app's own words. Shipped in the binary rather than fetched
/// from the appcast: it has to be there on a first launch with no network, and it belongs to
/// the build it describes.
struct ReleaseNote: Equatable {
    /// Must equal `CFBundleShortVersionString` exactly; the regression checks fail a version
    /// bump that has no note.
    let version: String
    let headline: String
    let changes: [Change]

    struct Change: Equatable {
        let title: String
        let detail: String

        init(_ title: String, _ detail: String = "") {
            self.title = title
            self.detail = detail
        }
    }
}

enum ReleaseNotes {
    static let all: [ReleaseNote] = [
        ReleaseNote(
            version: "1.0.9",
            headline: "GaugeZ speaks your language.",
            changes: [
                .init("21 languages besides English",
                      "Arabic, Bengali, Bosnian, Chinese (Simplified and Hong Kong), Filipino, French, German, Hindi, Italian, Japanese, Korean, Marathi, Portuguese (Brazil), Russian, Spanish, Tamil, Telugu, Turkish, Urdu, and Vietnamese."),
                .init("Pick one in Settings → General",
                      "The Language menu applies at once, no restart. System (Default) follows macOS."),
                .init("Claude sessions no longer get stuck",
                      "Desktop-app sessions are found again, and a local slash command such as /cost no longer shows as Working."),
                .init("Token renewal for the default Claude Code sign-in",
                      "Renewal now works for the default profile and waits out rate-limit backoff before launching the CLI.")
            ]
        ),
        ReleaseNote(
            version: "1.0.8",
            headline: "Settings, sorted.",
            changes: [
                .init("A General page",
                      "Launch at login, app presence, and session options have their own page. Appearance now covers only the rail."),
                .init("A leaner quick settings card",
                      "The rail's card keeps providers, visibility, edge, and color. Everything set once lives in Preferences."),
                .init("Pick your session sounds",
                      "Choose a sound for finished work and another for needs input, and preview each before it fires."),
                .init("Diagnostics as a list",
                      "Providers are rows instead of uneven cards, and usage alerts sit inside each provider row.")
            ]
        ),
        ReleaseNote(
            version: "1.0.7",
            headline: "The notch is yours to size.",
            changes: [
                .init("Resize the notch by dragging its inner edge",
                      "Grab the strip along the notch's inner edge and pull. It snaps to the default size with a tap, and a double-click resets it."),
                .init("Or set it in Settings",
                      "A Notch Size slider in Settings → Appearance and in the rail's own settings card, from 70% to 140%."),
                .init("Everything scales together",
                      "Rings, labels, the settings button, and how many rings fit a page all follow the size, on every edge.")
            ]
        ),
        ReleaseNote(
            version: "1.0.6",
            headline: "GitHub Copilot joins the rail, limits can tell you before they bite, and sessions say when they finish.",
            changes: [
                .init("GitHub Copilot is a new ring",
                      "Reads GitHub's Copilot quota endpoint with GH_TOKEN or the GitHub CLI sign-in. Premium requests headline it. Enable it in Settings."),
                .init("Usage alerts at 20% and 0% remaining",
                      "A system notification once per crossing, never repeated while a limit stays crossed. Mute any provider from its row in Settings → Providers."),
                .init("The rail peeks when a session finishes or needs you",
                      "With session activity on, the rail opens for five seconds and shows which session it was. Click it to raise the owning app. Optional sounds tell finished from waiting; they start off."),
                .init("Cursor without the editor, and team plans",
                      "A cursor-agent login gets a ring on its own, and enterprise and team accounts read their included usage and shared on-demand budget instead of reporting nothing."),
                .init("Antigravity when it is closed",
                      "Google's quota endpoint is asked with the saved sign-in, and when it will not answer for the account, the card shows a clearly labeled count of today's model turns instead of a guessed percentage."),
                .init("Sub-1% readings stop rounding to 0% or 100%",
                      "Fractions survive from the endpoint to the ring. Below 1% left shows a tenth, or <0.1%, and only a real zero turns the ring red."),
                .init("Rails on every display",
                      "Choose All displays in Settings → Appearance to get a rail on each connected screen."),
                .init("Refresh one provider from the menu bar",
                      "Refresh Provider lists each enabled ring."),
                .init("Erase all data and quit",
                      "Diagnostics can remove GaugeZ's settings, cached readings, and login registration so a reinstall starts clean. Provider sign-ins stay with their own apps.")
            ]
        ),
        ReleaseNote(
            version: "1.0.5",
            headline: "OpenCode joins the rail, sessions tell you how long, and a few things stop going wrong.",
            changes: [
                .init("OpenCode Go is a new ring",
                      "Reads the Go plan's official usage endpoint with the key OpenCode stores on sign-in. Enable it in Settings."),
                .init("Codex and Antigravity show activity",
                      "Inferred from recent writes to their local logs, and labeled as inferred. Every session row now says how long it has been in its state."),
                .init("A card that fits the screen",
                      "Long session lists are capped to what the display can hold, with \"and N more\" for the rest."),
                .init("Dock, menu bar, or neither",
                      "Choose where GaugeZ shows itself in Settings → Appearance. Relaunching from Applications always brings Settings back."),
                .init("The rail joins a MacBook's notch",
                      "On the top edge of a display with a notch, the rail centers under it and hides at rest; reaching the notch opens it."),
                .init("Waking from sleep no longer blanks Claude",
                      "A Keychain that cannot answer yet right after wake was mistaken for a refusal, which erased the reading until you retried."),
                .init("Codex without the desktop app",
                      "A codex CLI on your PATH is found, and without one the CLI's ChatGPT sign-in is used to read the same usage endpoint."),
                .init("Grok Build sessions stop reading as working forever",
                      "A session counts as working only while its log was written in the last 45 seconds."),
                .init("Distant resets show a date",
                      "A monthly window resetting in four weeks said \"Mon\", which read as this Monday.")
            ]
        ),
        ReleaseNote(
            version: "1.0.4",
            headline: "GLM, Grok Build, multiple Claude Code accounts, and rail paging.",
            changes: [
                .init("GLM ring for the Z.ai Coding Plan", "Using a key already held by Claude Code, ZCode, or OpenCode."),
                .init("Grok Build ring", "The xAI account allowance, on-demand spend, and latest session cost."),
                .init("Multiple Claude Code accounts", "~/.claude-* profiles get their own rings, sessions, and settings."),
                .init("Rail paging", "When enabled accounts no longer fit the screen, a page control in the drag handle cycles through them."),
                .init("Session activity covers Cursor and Grok Build", "Alongside Claude Code."),
                .init("Fewer Keychain prompts", "Claude Code credentials are cached in memory and re-read only when the item changes or you retry."),
                .init("Updates announced in the menu bar", "An update found while GaugeZ is in the background no longer shows an alert you might not see.")
            ]
        ),
        ReleaseNote(
            version: "1.0.3",
            headline: "Any edge, any window, and honest retries.",
            changes: [
                .init("Top and bottom edges", "The rail sits on any of the four screen edges."),
                .init("Pick the rail's window", "Choose which quota window or model the ring reports."),
                .init("Claude Code session activity", "Opt in to see working, waiting, and idle sessions from local metadata."),
                .init("Retry backoff that survives relaunch", "Rate-limit penalties persist and honor server deadlines up to 15 minutes.")
            ]
        ),
        ReleaseNote(
            version: "1.0.2",
            headline: "Move the rail where you want it.",
            changes: [
                .init("Drag the rail along the screen edge", "With a snap to center."),
                .init("Polished drag handle and settings button")
            ]
        ),
        ReleaseNote(
            version: "1.0.1",
            headline: "A new face.",
            changes: [
                .init("New wordmark font")
            ]
        ),
        ReleaseNote(
            version: "1.0.0",
            headline: "The first release.",
            changes: [
                .init("Claude, Codex, Cursor, and Antigravity", "Each read from the tool already signed in on this Mac."),
                .init("An edge rail, not a window", "A slim tab that expands on hover and never steals focus."),
                .init("Automatic updates", "Signed and verified with Sparkle.")
            ]
        )
    ]

    static func note(for version: String) -> ReleaseNote? {
        all.first { $0.version == version }
    }

    /// The note worth showing on this launch, if any. `notes` is a parameter so the rule can be
    /// checked against a fixed history.
    static func unseen(in version: String, lastSeen: String?, notes: [ReleaseNote] = all) -> ReleaseNote? {
        guard lastSeen != version else { return nil }
        return notes.first { $0.version == version }
    }
}
