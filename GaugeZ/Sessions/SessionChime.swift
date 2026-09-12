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

    /// Plays one of `systemSounds`; an unknown name falls back to the finished-work default.
    static func play(named name: String) {
        let chosen = systemSounds.contains(name) ? name : defaultFinished
        guard let sound = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: "/System/Library/Sounds/\(chosen).aiff")) else { return }
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
        if var pid = session.pid {
            // Refuse a PID recycled since the activity reader saw it.
            if let start = session.processStartedAt, ActivityReader.processStart(pid) != start { return false }
            let agentPID = pid
            var seen: Set<pid_t> = []
            for _ in 0..<16 {
                guard pid > 1, seen.insert(pid).inserted else { break }
                if let app = NSRunningApplication(processIdentifier: pid), let bundleID = app.bundleIdentifier {
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
                var info = kinfo_proc()
                var size = MemoryLayout<kinfo_proc>.stride
                var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
                guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { break }
                pid = info.kp_eproc.e_ppid
            }
        }
        guard let url = session.provider.applicationURL,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL == url }) else { return false }
        return app.activate()
    }
}
