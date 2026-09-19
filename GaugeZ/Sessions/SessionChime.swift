import AppKit
import AVFoundation
import Darwin

@MainActor
enum SessionChime {
    /// The macOS alert sounds, offered by name in Settings.
    static let systemSounds = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"
    ]
    static let defaultFinished = "Glass"
    static let defaultWaiting = "Funk"

    private static var player: AVAudioPlayer?
    private static let soundExtensions: Set<String> = ["aiff", "aif", "wav", "caf", "m4a", "mp3"]

    /// Sounds the user has installed in `~/Library/Sounds` or `/Library/Sounds`, by name.
    /// A name the system list already carries stays the system's.
    static func customSounds() -> [String: URL] {
        let folders = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds"),
                       URL(fileURLWithPath: "/Library/Sounds")]
        var found: [String: URL] = [:]
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            for file in files.prefix(200) where soundExtensions.contains(file.pathExtension.lowercased()) {
                let name = file.deletingPathExtension().lastPathComponent
                if !systemSounds.contains(name), found[name] == nil { found[name] = file }
            }
        }
        return found
    }

    /// Every name the pickers offer: the system sounds, then the user's own.
    static var availableSounds: [String] { systemSounds + customSounds().keys.sorted() }

    /// Plays a sound by name; an unknown name falls back to the finished-work default.
    /// `AVAudioPlayer`, not `NSSound`: the latter is silenced by "Play user interface sound effects".
    static func play(named name: String) {
        let url = systemSounds.contains(name)
            ? URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
            : customSounds()[name] ?? URL(fileURLWithPath: "/System/Library/Sounds/\(defaultFinished).aiff")
        guard let sound = try? AVAudioPlayer(contentsOf: url) else { return }
        player = sound
        sound.prepareToPlay()
        sound.play()
    }
}

@MainActor
enum SessionFocus {
    /// Raises the session's app inside the click, then selects its terminal tab where the
    /// terminal offers a way to name it (Terminal.app, iTerm2, and cmux answer through
    /// their scripting interfaces). The tab selection runs afterwards on its own thread:
    /// it scripts a subprocess that can sit on an Automation consent prompt, and the
    /// activation must stay tied to the user's gesture rather than wait behind it.
    @discardableResult
    static func activate(_ session: ActivitySession) -> Bool {
        if let agentPID = session.pid {
            // Refuse a PID recycled since the activity reader saw it.
            if let start = session.processStartedAt, ActivityReader.processStart(agentPID) != start { return false }
            if let app = owningApplication(of: agentPID), let bundleID = app.bundleIdentifier {
                let raised = app.activate()
                if TerminalTabFocus.supports(bundleID) {
                    // The facts the script needs are cheap sysctl reads, taken here.
                    let tty = TerminalTabFocus.tty(of: agentPID)
                    let cwd = TerminalTabFocus.currentDirectory(of: agentPID)
                    DispatchQueue.global(qos: .userInitiated).async {
                        _ = TerminalTabFocus.selectTab(bundleID: bundleID, pid: agentPID, tty: tty, cwd: cwd)
                    }
                }
                return raised
            }
        }
        guard let url = session.provider.applicationURL,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL == url }) else { return false }
        return app.activate()
    }

    /// The app a session runs inside, found by walking up its process ancestry (bounded).
    static func owningApplication(of pid: pid_t) -> NSRunningApplication? {
        var pid = pid
        var seen: Set<pid_t> = []
        for _ in 0..<16 {
            guard pid > 1, seen.insert(pid).inserted else { break }
            if let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier != nil { return app }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { break }
            pid = info.kp_eproc.e_ppid
        }
        return nil
    }

    /// Where a session lives, as the user knows it: "iTerm2", "Ghostty", "Claude", "Code".
    static func surfaceName(of session: ActivitySession) -> String? {
        guard let pid = session.pid,
              session.processStartedAt == nil || ActivityReader.processStart(pid) == session.processStartedAt
        else { return nil }
        return owningApplication(of: pid)?.localizedName
    }
}
