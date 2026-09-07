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
