import AppKit

// `AIUsageBar --check` prints the same numbers the menubar shows, then exits.
// Useful for verifying from Terminal without launching the menubar.
if CommandLine.arguments.contains("--check") {
    Task {
        let now = Date()
        switch await attempt({ try await fetchClaudeUsage() }) {
        case .success(let usage):
            let readings = claudePace(usage, now: now)
            print("Claude \(usage.plan ?? "") \(usage.shortStatus)" + (servicePace(readings, limitReached: usage.limitReached).map { " (\($0.label))" } ?? ""))
            (claudeLines(usage, now: now) + readings.map(\.line)).forEach { print("  \($0)") }
        case .failure(let error):
            print("Claude unavailable: \(error.localizedDescription)")
        }
        switch await attempt({ try await fetchCodexUsage() }) {
        case .success(let usage):
            let readings = codexPace(usage, now: now)
            print("Codex \(usage.planType ?? "") \(usage.shortStatus)" + (servicePace(readings, limitReached: usage.anyLimitReached).map { " (\($0.label))" } ?? ""))
            (codexLines(usage, now: now) + readings.map(\.line)).forEach { print("  \($0)") }
        case .failure(let error):
            print("Codex unavailable: \(error.localizedDescription)")
        }
        exit(0)
    }
    dispatchMain()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
