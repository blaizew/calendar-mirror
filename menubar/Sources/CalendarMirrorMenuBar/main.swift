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

@discardableResult
func shell(_ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", args.joined(separator: " ")]
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        statusItem.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.refresh() }
    }

    var stateURL: URL { dir.appendingPathComponent("state.json") }
    var logURL: URL { dir.appendingPathComponent("sync.log") }

    func isLoaded() -> Bool {
        shell(["launchctl", "list", LABEL]).0 == 0
    }

    func refresh() {
        var interval = 60.0
        var mirrored: Int? = nil
        var lastRun: Date? = nil
        var status = ""
        lastError = ""

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

        if status == "abort" {
            health = .error
            statusLine = "Error — last sync failed"
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
        let st = NSMenuItem(title: "\(dot) \(statusLine)", action: nil, keyEquivalent: "")
        st.isEnabled = false
        menu.addItem(st)

        if !detailLine.isEmpty {
            let d = NSMenuItem(title: "   \(detailLine)", action: nil, keyEquivalent: "")
            d.isEnabled = false
            menu.addItem(d)
        }
        if health == .error && !lastError.isEmpty {
            let e = NSMenuItem(title: "   \(lastError)", action: nil, keyEquivalent: "")
            e.isEnabled = false
            menu.addItem(e)
        }

        menu.addItem(.separator())

        let sync = NSMenuItem(title: "Sync now", action: #selector(syncNow), keyEquivalent: "s")
        sync.target = self; menu.addItem(sync)

        let logs = NSMenuItem(title: "Open logs", action: #selector(openLogs), keyEquivalent: "l")
        logs.target = self; menu.addItem(logs)

        let ref = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        ref.target = self; menu.addItem(ref)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
    }

    @objc func syncNow() {
        let uid = getuid()
        _ = shell(["launchctl", "kickstart", "-k", "gui/\(uid)/\(LABEL)"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.refresh() }
    }

    @objc func openLogs() {
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: logURL.path) ? logURL : dir)
    }

    @objc func refreshNow() { refresh() }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
