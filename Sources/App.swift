import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var claude: Result<ClaudeUsage, Error>?
    private var codex: Result<CodexUsage, Error>?
    private var lastRefresh: Date?
    private var refreshing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        render()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    @objc func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            let claudeResult = await attempt { try await fetchClaudeUsage() }
            let codexResult = await attempt { try await fetchCodexUsage() }
            claude = claudeResult
            codex = codexResult
            lastRefresh = Date()
            refreshing = false
            render()
        }
    }

    private func render() {
        guard let item = statusItem else { return }
        let claudeUsage = try? claude?.get()
        let codexUsage = try? codex?.get()
        let title = NSMutableAttributedString()
        title.append(segment(ServiceIcons.claude, status: claudeUsage?.shortStatus ?? "n/a",
                             percent: claudeUsage?.percent, alarm: false))
        title.append(NSAttributedString(string: "  "))
        title.append(segment(ServiceIcons.codex, status: codexUsage?.shortStatus ?? "n/a",
                             percent: codexUsage?.percent, alarm: codexUsage?.limitReached ?? false))
        item.button?.attributedTitle = title
        // Keep one point on each outer edge; inter-item spacing belongs to macOS.
        item.length = ceil(title.size().width) + 2
        let description = menubarText(claude: claudeUsage?.shortStatus ?? "n/a",
                                      codex: codexUsage?.shortStatus ?? "n/a")
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

        addHeader(menu, "Claude" + ((try? claude?.get().plan)?.map { " (\($0.capitalized))" } ?? ""))
        switch claude {
        case .success(let usage)?: claudeLines(usage, now: now).forEach { addInfo(menu, $0) }
        case .failure(let error)?: addInfo(menu, "Unavailable: \(error.localizedDescription)")
        case nil: addInfo(menu, "Loading...")
        }
        menu.addItem(.separator())

        addHeader(menu, "Codex" + ((try? codex?.get().planType)?.map { " (\($0.capitalized))" } ?? ""))
        switch codex {
        case .success(let usage)?: codexLines(usage, now: now).forEach { addInfo(menu, $0) }
        case .failure(let error)?: addInfo(menu, "Unavailable: \(error.localizedDescription)")
        case nil: addInfo(menu, "Loading...")
        }
        menu.addItem(.separator())

        if let lastRefresh {
            addInfo(menu, "Refreshed \(formatReset(lastRefresh, now: now.addingTimeInterval(1)))")
        }
        let refreshItem = NSMenuItem(title: "Refresh now", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        return menu
    }

    private func addHeader(_ menu: NSMenu, _ text: String) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addInfo(_ menu: NSMenu, _ text: String) {
        let item = NSMenuItem(title: "    " + text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }
}
