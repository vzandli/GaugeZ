import AppKit
import Foundation

/// Selects the exact tab a session is running in, where the terminal offers a way to name it.
///
/// There is no general mechanism — every terminal is its own answer, and each costs a
/// one-time Automation consent for AppleScript:
///
/// * **Terminal.app** and **iTerm2** match a tab by tty.
/// * **cmux** matches a terminal panel by the surface id its own process tree carries in
///   its environment, falling back to the session's working directory.
/// * Everything else (Warp, Ghostty) publishes nothing, so the caller falls back to
///   raising the app — the honest answer rather than a silent no-op.
///
/// Adapted from Codenotch (MIT); see Resources/ThirdPartyNotices.txt.
enum TerminalTabFocus {
    /// The terminals whose scripting interface can name a tab. Everything else is not
    /// worth a process read or a subprocess.
    static let supportedBundleIDs: Set<String> = ["com.cmuxterm.app", "com.apple.Terminal", "com.googlecode.iterm2"]

    static func supports(_ bundleID: String?) -> Bool {
        bundleID.map(supportedBundleIDs.contains) ?? false
    }

    /// Best effort: true when a tab was selected. Anything going wrong — no tty, no cwd,
    /// no match, a refused prompt — is false, and the caller has already raised the app.
    static func selectTab(bundleID: String?, pid: pid_t, tty: String?, cwd: String?) -> Bool {
        switch bundleID {
        case "com.cmuxterm.app":
            // The exact surface, named by the id the session's own process tree carries
            // in its environment; cwd matching is the fallback for a tree that publishes
            // nothing readable.
            if let surface = cmuxSurfaceID(of: pid) {
                return selectCmuxTerminal(matching: "id of term is \"\(appleScriptEscaped(surface))\"")
            }
            guard let cwd else { return false }
            let condition = cmuxPathCandidates(cwd)
                .map { "working directory of term is \"\(appleScriptEscaped($0))\"" }
                .joined(separator: " or ")
            return selectCmuxTerminal(matching: condition)
        case "com.apple.Terminal":
            guard let tty else { return false }
            return runOsascript("""
                tell application "Terminal"
                  repeat with w in windows
                    repeat with t in tabs of w
                      if tty of t is "/dev/\(appleScriptEscaped(tty))" then
                        set selected of t to true
                        set index of w to 1
                        return "found"
                      end if
                    end repeat
                  end repeat
                end tell
                """)
        case "com.googlecode.iterm2":
            guard let tty else { return false }
            return runOsascript("""
                tell application "iTerm2"
                  repeat with w in windows
                    repeat with t in tabs of w
                      repeat with s in sessions of t
                        if tty of s is "/dev/\(appleScriptEscaped(tty))" then
                          select s
                          select t
                          select w
                          return "found"
                        end if
                      end repeat
                    end repeat
                  end repeat
                end tell
                """)
        default:
            return false
        }
    }

    // MARK: - Process facts

    /// The process's controlling terminal, named the way `ps` prints it (`ttys014`). Nil
    /// when it has none — agents with no terminal to go back to, which is most
    /// desktop-hosted sessions.
    static func tty(of pid: pid_t) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        // NODEV (-1) is "no controlling terminal"; devname would read it as a real device
        // number and answer garbage.
        guard info.kp_eproc.e_tdev != -1, let name = devname(info.kp_eproc.e_tdev, S_IFCHR) else { return nil }
        return String(cString: name)
    }

    /// The process's working directory — how a terminal that publishes no tty (cmux's
    /// AppleScript interface) can still name the tab it lives in.
    static func currentDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let read = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard read == Int32(MemoryLayout<proc_vnodepathinfo>.size) else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    /// The session's own process tree knows exactly which surface it lives in: cmux
    /// exports CMUX_SURFACE_ID into every terminal it spawns, and the agent inherits it.
    /// Read up the ancestry until it turns up — wrappers occasionally scrub it from the
    /// agent itself, but the shell or launcher above still has it.
    static func cmuxSurfaceID(of pid: pid_t) -> String? {
        for candidate in ancestry(of: pid) {
            for entry in environment(of: candidate) {
                guard entry.hasPrefix("CMUX_SURFACE_ID=") else { continue }
                let value = String(entry.dropFirst("CMUX_SURFACE_ID=".count))
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// A process's full argument/environment block as NUL-separated strings. Same-user
    /// reads only — which is all a session's own tree ever needs.
    static func environment(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        var strings: [String] = []
        buffer.withUnsafeBytes { raw in
            var offset = MemoryLayout<Int32>.size   // past argc
            while offset < raw.count {
                guard let nul = raw[offset...].firstIndex(of: 0) else { break }
                // Empty runs separate the blocks (path, argv, env) — skip them rather
                // than stop at the first one.
                if nul == offset {
                    offset += 1
                    continue
                }
                if let string = String(bytes: raw[offset..<nul], encoding: .utf8) {
                    strings.append(string)
                }
                offset = nul + 1
            }
        }
        return strings
    }

    /// The process and its parents, nearest first, bounded — no real chain from an agent
    /// to its terminal is deeper than a handful.
    private static func ancestry(of pid: pid_t, limit: Int = 8) -> [pid_t] {
        var chain: [pid_t] = []
        var current = pid
        while chain.count < limit, current > 1 {
            chain.append(current)
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { break }
            let parent = info.kp_eproc.e_ppid
            guard parent != current else { break }
            current = parent
        }
        return chain
    }

    /// The same directory, spelled the ways it might appear: the kernel's report can
    /// carry a `/private` prefix the terminal's title never shows, and symlinks along
    /// the path resolve differently on either side.
    static func cmuxPathCandidates(_ cwd: String) -> [String] {
        var candidates = [cwd]
        let resolved = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
        if resolved != cwd { candidates.append(resolved) }
        for path in [cwd, resolved] {
            if path.hasPrefix("/private/") {
                candidates.append(String(path.dropFirst("/private".count)))
            } else {
                candidates.append("/private" + path)
            }
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    // MARK: - cmux scripting

    /// The scripting dictionary's `terminal` panels carry an `id`, a `working directory`
    /// and a title but no tty; `select tab` picks the workspace, and `focus` plus
    /// `activate window` finish the job.
    private static func selectCmuxTerminal(matching condition: String) -> Bool {
        runOsascript("""
            tell application "cmux"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with term in terminals of t
                    if \(condition) then
                      select tab t
                      focus term
                      activate window w
                      return "found"
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            """)
    }

    /// An AppleScript string literal's two dangerous characters, escaped — every value
    /// interpolated into a script goes through here.
    static func appleScriptEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Running the tools

    /// A subprocess's stdout, read to the end on the calling thread, with a timer that
    /// terminates a child still running at the deadline (closing its stdout, so the read
    /// returns). Same shape as the Copilot token runner. Nil on any failure.
    ///
    /// The deadline is generous: the first script against each terminal sits on the
    /// Automation consent prompt until the user answers it, and killing the child under
    /// that prompt throws the answer away.
    static func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval = 30) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let expiry = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: expiry)
        defer { expiry.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func runOsascript(_ script: String) -> Bool {
        run("/usr/bin/osascript", ["-e", script]).map { $0.contains("found") } ?? false
    }
}
