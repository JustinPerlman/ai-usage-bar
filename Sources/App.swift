import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var claude = Feed<ClaudeUsage>()
    private var codex = Feed<CodexUsage>()
    private var loaded = false
    private var lastRefresh: Date?
    private var refreshing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        render()
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: false) }
        }
    }

    @objc func refreshNow() { refresh(force: true) }

    // Scheduled refreshes skip a service that is waiting out a 429; a manual
    // refresh always asks.
    private func refresh(force: Bool) {
        guard !refreshing else { return }
        let start = Date()
        let askClaude = force || claude.isDue(start)
        let askCodex = force || codex.isDue(start)
        guard askClaude || askCodex else { return }
        refreshing = true
        Task {
            if askClaude { claude.record(await attempt { try await fetchClaudeUsage() }, now: Date()) }
            if askCodex { codex.record(await attempt { try await fetchCodexUsage() }, now: Date()) }
            loaded = true
            lastRefresh = Date()
            refreshing = false
            render()
        }
    }

    private func render() {
        guard let item = statusItem else { return }
        let claudeUsage = claude.usage
        let codexUsage = codex.usage
        let title = NSMutableAttributedString()
        title.append(segment(ServiceIcons.claude, status: claudeUsage?.shortStatus ?? "n/a",
                             percent: claudeUsage?.percent, alarm: false))
        title.append(NSAttributedString(string: "  "))
        title.append(segment(ServiceIcons.codex, status: codexUsage?.shortStatus ?? "n/a",
                             percent: codexUsage?.percent, alarm: codexUsage?.limitReached ?? false))
        item.button?.attributedTitle = title
        // Keep one point on each outer edge; inter-item spacing belongs to macOS.
        item.length = ceil(title.size().width) + 2
        let now = Date()
        let description = menubarText(claude: claudeUsage?.shortStatus ?? "n/a",
                                      codex: codexUsage?.shortStatus ?? "n/a",
                                      claudePace: claudeUsage.flatMap {
                                          servicePace(claudePace($0, now: now), limitReached: $0.limitReached) },
                                      codexPace: codexUsage.flatMap {
                                          servicePace(codexPace($0, now: now), limitReached: $0.anyLimitReached) })
        item.button?.toolTip = description
        item.button?.setAccessibilityLabel(description)
        item.menu = buildMenu()
    }

    private func segment(_ icon: NSImage, status: String, percent: Int?, alarm: Bool) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuBarFont(ofSize: 0)]
        if alarm || (percent ?? 0) >= 90 { attributes[.foregroundColor] = NSColor.systemRed }
        else if (percent ?? 0) >= 75 { attributes[.foregroundColor] = NSColor.systemOrange }
        let attachment = NSTextAttachment()
        attachment.image = icon
        attachment.bounds = NSRect(x: 0, y: -3, width: 14, height: 14)
        let segment = NSMutableAttributedString(attachment: attachment)
        segment.append(NSAttributedString(string: " \(status)", attributes: attributes))
        return segment
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let now = Date()

        let claudeReadings = claude.usage.map { claudePace($0, now: now) } ?? []
        addHeader(menu, "Claude" + (claude.usage?.plan.map { " (\($0.capitalized))" } ?? ""),
                  pace: claude.usage.flatMap { servicePace(claudeReadings, limitReached: $0.limitReached) })
        addFeed(menu, claude, now: now) { claudeLines($0, now: now) + claudeReadings.map(\.line) }
        menu.addItem(.separator())

        let codexReadings = codex.usage.map { codexPace($0, now: now) } ?? []
        addHeader(menu, "Codex" + (codex.usage?.planType.map { " (\($0.capitalized))" } ?? ""),
                  pace: codex.usage.flatMap { servicePace(codexReadings, limitReached: $0.anyLimitReached) })
        addFeed(menu, codex, now: now) { codexLines($0, now: now) + codexReadings.map(\.line) }
        menu.addItem(.separator())

        if let lastRefresh {
            addInfo(menu, "Refreshed \(formatReset(lastRefresh, now: now.addingTimeInterval(1)))")
        }
        let refreshItem = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        return menu
    }

    private func addFeed<Usage>(_ menu: NSMenu, _ feed: Feed<Usage>, now: Date, lines: (Usage) -> [String]) {
        if let usage = feed.usage {
            lines(usage).forEach { addInfo(menu, $0) }
            if feed.isStale, let usageAt = feed.usageAt {
                var note = "Stale since \(formatReset(usageAt, now: now)), rate limited"
                if let retryAt = feed.retryAt { note += "; retrying after \(formatReset(retryAt, now: now))" }
                addInfo(menu, note)
            }
        } else if let error = feed.error {
            addInfo(menu, "Unavailable: \(error.localizedDescription)")
            if let retryAt = feed.retryAt { addInfo(menu, "Retrying after \(formatReset(retryAt, now: now))") }
        } else {
            addInfo(menu, loaded ? "Not checked yet" : "Loading...")
        }
    }

    private func addHeader(_ menu: NSMenu, _ text: String, pace: Pace?) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        let font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        let title = NSMutableAttributedString()
        if let pace {
            title.append(NSAttributedString(string: "● ", attributes: [.font: font, .foregroundColor: color(pace)]))
        }
        title.append(NSAttributedString(string: text, attributes: [.font: font]))
        if let pace {
            title.append(NSAttributedString(string: "  \(pace.label)",
                                            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                                         .foregroundColor: NSColor.secondaryLabelColor]))
        }
        item.attributedTitle = title
        item.isEnabled = false
        menu.addItem(item)
    }

    private func color(_ pace: Pace) -> NSColor {
        switch pace {
        case .green: return .systemGreen
        case .yellow: return .systemYellow
        case .orange: return .systemOrange
        case .red, .limited: return .systemRed
        }
    }

    private func addInfo(_ menu: NSMenu, _ text: String) {
        let item = NSMenuItem(title: "    " + text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }
}
