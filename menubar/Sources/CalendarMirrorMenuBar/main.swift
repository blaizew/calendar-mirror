// calendar-mirror menu-bar status indicator.
//
// A tiny AppKit menu-bar-only app (.accessory policy — no Dock icon, no third-party deps).
// It is a READ-ONLY viewer of the calendar-mirror sync job: every ~20s it reads the job's
// heartbeat (state.json) and checks launchd, then shows a green/yellow/red icon + a menu.
//
// The mirror project directory is passed as argv[1] (or env CALENDAR_MIRROR_DIR) by the
// LaunchAgent that install.sh sets up.

import AppKit
import Foundation

let LABEL = "com.calendar-mirror"

func mirrorDirectory() -> URL {
    if CommandLine.arguments.count > 1 {
        return URL(fileURLWithPath: CommandLine.arguments[1])
    }
    if let env = ProcessInfo.processInfo.environment["CALENDAR_MIRROR_DIR"] {
        return URL(fileURLWithPath: env)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

enum Health { case healthy, stale, error, unknown }

// Run a command with its arguments passed as a literal array (no shell). args[0] is the
// program (resolved on PATH via /usr/bin/env); the rest are argv, so nothing is ever
// interpreted by a shell.
@discardableResult
func run(_ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "") }
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func agoString(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    if s < 90 { return "\(max(s, 0))s ago" }
    if s < 5400 { return "\(s / 60)m ago" }
    if s < 172800 { return "\(s / 3600)h ago" }
    return "\(s / 86400)d ago"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let dir = mirrorDirectory()
    var timer: Timer?

    // Cached for the menu
    var health: Health = .unknown
    var statusLine = "Loading…"
    var detailLine = ""
    var lastError = ""
    var authExpired = false
    var transientLine: String?  // shown once (e.g. "Copied"), cleared on next refresh

    // OAuth consent screen for the gws project (where you publish the app to stop the
    // ~7-day token expiry). Project id is read from gws's own config when available.
    let consentScreenURL = "https://console.cloud.google.com/auth/clients"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        statusItem.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.refresh() }
    }

    var stateURL: URL { dir.appendingPathComponent("state.json") }
    var logURL: URL { dir.appendingPathComponent("sync.log") }
    var configURL: URL { dir.appendingPathComponent("config.json") }

    // Path to the gws binary, from config.json (a leading ~ expanded), defaulting to "gws".
    // Mirrors how mirror.py resolves gws_path, so the copied command actually runs.
    func gwsPath() -> String {
        var path = "gws"
        if let data = try? Data(contentsOf: configURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let p = obj["gws_path"] as? String, !p.isEmpty {
            path = p
        }
        if path == "~" { return FileManager.default.homeDirectoryForCurrentUser.path }
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }

    func reauthCommand() -> String {
        "\(gwsPath()) auth login --scopes https://www.googleapis.com/auth/calendar"
    }

    func isLoaded() -> Bool {
        run(["launchctl", "list", LABEL]).0 == 0
    }

    func refresh() {
        var interval = 60.0
        var mirrored: Int? = nil
        var lastRun: Date? = nil
        var status = ""
        lastError = ""
        transientLine = nil

        if let data = try? Data(contentsOf: stateURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            status = (obj["status"] as? String) ?? ""
            if let i = obj["interval_seconds"] as? Double { interval = i }
            else if let i = obj["interval_seconds"] as? Int { interval = Double(i) }
            mirrored = obj["mirrored"] as? Int
            lastError = (obj["error"] as? String) ?? ""
            if let lr = obj["last_run"] as? String {
                let fmt = ISO8601DateFormatter()
                fmt.formatOptions = [.withInternetDateTime]
                lastRun = fmt.date(from: lr)
            }
        }

        let loaded = isLoaded()

        // Token-expiry is the one error a user can fix from here. Match ONLY the expired/revoked
        // signature, not gws's generic auth-category errors (e.g. missing root CAs), which
        // re-auth won't fix — those keep the plain error display.
        let lowerErr = lastError.lowercased()
        authExpired = status == "abort"
            && (lowerErr.contains("invalid_grant") || lowerErr.contains("expired or revoked"))

        if status == "abort" {
            health = .error
            statusLine = authExpired ? "Sign-in expired — sync paused" : "Error — last sync failed"
        } else if let lr = lastRun {
            let age = Date().timeIntervalSince(lr)
            let staleAfter = max(180.0, interval * 3.0)
            if !loaded {
                health = .error
                statusLine = "Not scheduled — launchd job missing"
            } else if age <= staleAfter {
                health = .healthy
                statusLine = "Healthy — last sync \(agoString(age))"
            } else {
                health = .stale
                statusLine = "Stale — last sync \(agoString(age))"
            }
        } else {
            health = loaded ? .stale : .error
            statusLine = loaded ? "Waiting for first sync…" : "Not scheduled — launchd job missing"
        }

        if let m = mirrored {
            detailLine = "\(m) busy block\(m == 1 ? "" : "s") mirrored"
        } else {
            detailLine = ""
        }

        updateIcon()
        rebuildMenu()
    }

    func symbolName() -> String {
        // Always a calendar glyph (so it's recognizable as calendar-mirror); the badge + color
        // convey health.
        switch health {
        case .healthy: return "calendar.badge.checkmark"
        case .stale:   return "calendar.badge.clock"
        case .error:   return "calendar.badge.exclamationmark"
        case .unknown: return "calendar"
        }
    }

    func color() -> NSColor {
        switch health {
        case .healthy: return .systemGreen
        case .stale:   return .systemYellow
        case .error:   return .systemRed
        case .unknown: return .secondaryLabelColor
        }
    }

    func updateIcon() {
        guard let button = statusItem.button else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            .applying(.init(paletteColors: [color()]))
        if let img = NSImage(systemSymbolName: symbolName(), accessibilityDescription: "calendar-mirror")?
            .withSymbolConfiguration(cfg) {
            img.isTemplate = false
            button.image = img
        }
        button.toolTip = "calendar-mirror — \(statusLine)"
    }

    func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let header = NSMenuItem(title: "calendar-mirror", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let dot: String
        switch health {
        case .healthy: dot = "🟢"; case .stale: dot = "🟡"; case .error: dot = "🔴"; case .unknown: dot = "⚪️"
        }
        let line = transientLine ?? "\(dot) \(statusLine)"
        let st = NSMenuItem(title: line, action: nil, keyEquivalent: "")
        st.isEnabled = false
        menu.addItem(st)

        if !detailLine.isEmpty {
            let d = NSMenuItem(title: "   \(detailLine)", action: nil, keyEquivalent: "")
            d.isEnabled = false
            menu.addItem(d)
        }
        // For the expired-token case the human-readable status line already says it; suppress the
        // raw gws stderr (it's long and redundant) and offer the fix instead. Other errors still
        // show the raw message so nothing is hidden.
        if health == .error && !authExpired && !lastError.isEmpty {
            let e = NSMenuItem(title: "   \(lastError)", action: nil, keyEquivalent: "")
            e.isEnabled = false
            menu.addItem(e)
        }

        if authExpired {
            menu.addItem(.separator())
            let copy = NSMenuItem(title: "Copy re-auth command", action: #selector(copyReauthCommand), keyEquivalent: "c")
            copy.target = self; menu.addItem(copy)
            let fix = NSMenuItem(title: "How to fix…", action: #selector(showFixInstructions), keyEquivalent: "")
            fix.target = self; menu.addItem(fix)
        }

        menu.addItem(.separator())

        // While sign-in is expired, syncing and refreshing are dead ends: "Sync now" would just
        // kickstart launchd into the same auth abort, and there's nothing new to re-read until the
        // user re-auths. Grey both out (the 20s timer still recovers the menu once a sync succeeds,
        // re-enabling them automatically). "Copy re-auth command" / "How to fix…" stay active.
        let sync = NSMenuItem(title: "Sync now", action: #selector(syncNow), keyEquivalent: "s")
        sync.target = self; sync.isEnabled = !authExpired; menu.addItem(sync)

        let logs = NSMenuItem(title: "Open logs", action: #selector(openLogs), keyEquivalent: "l")
        logs.target = self; menu.addItem(logs)

        let ref = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        ref.target = self; ref.isEnabled = !authExpired; menu.addItem(ref)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
    }

    @objc func syncNow() {
        let uid = getuid()
        _ = run(["launchctl", "kickstart", "-k", "gui/\(uid)/\(LABEL)"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.refresh() }
    }

    @objc func openLogs() {
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: logURL.path) ? logURL : dir)
    }

    func copyToClipboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    @objc func copyReauthCommand() {
        copyToClipboard(reauthCommand())
        transientLine = "✅ Copied — paste into Terminal"
        rebuildMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self = self, self.transientLine != nil else { return }
            self.transientLine = nil
            self.rebuildMenu()
        }
    }

    @objc func showFixInstructions() {
        let alert = NSAlert()
        alert.messageText = "Calendar Mirror sign-in expired"
        alert.informativeText = """
        The Google sign-in for the sync expired, so it has paused. No calendar changes are \
        being made until you sign in again.

        Fix now (about a minute):
        1. Click “Copy command”, paste it into Terminal, and run it.
        2. In the browser: pick the intermediary account, then Advanced → “Go to … (unsafe)” → Allow.
        The next sync turns green automatically — no restart needed.

        Stop this from recurring:
        This happens every ~7 days while the OAuth app is in “Testing” mode. Publish it once \
        (Google Cloud → APIs & Services → OAuth consent screen → Publishing status → Publish app) \
        and the sign-in stops expiring.
        """
        alert.addButton(withTitle: "Copy command")
        alert.addButton(withTitle: "Open Google Cloud console")
        alert.addButton(withTitle: "Close")
        // Bring the (accessory) app forward so the modal is visible and focused.
        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            copyToClipboard(reauthCommand())
        } else if resp == .alertSecondButtonReturn {
            if let url = URL(string: consentScreenURL) { NSWorkspace.shared.open(url) }
        }
    }

    @objc func refreshNow() { refresh() }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
