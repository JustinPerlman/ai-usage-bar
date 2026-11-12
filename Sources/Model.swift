import Foundation

// Pure data types and functions. No network, no Keychain, no AppKit.
// Everything in this file is exercised by Tests/main.swift.

struct ClaudeSpend: Equatable, Sendable {
    let usedMinor: Int
    let limitMinor: Int
    let exponent: Int
    let currency: String

    var used: Double { Double(usedMinor) / divisor }
    var limit: Double { Double(limitMinor) / divisor }
    var remaining: Double { Double(max(limitMinor - usedMinor, 0)) / divisor }
    // Floor, not round, so 84.5% reads as 84% like the Claude desktop app.
    var percent: Int { limitMinor > 0 ? Int(Double(usedMinor) * 100 / Double(limitMinor)) : 0 }

    private var divisor: Double { pow(10.0, Double(exponent)) }
}

struct ClaudeWindow: Equatable, Sendable {
    let label: String
    let utilization: Double
    let resetsAt: Date?
}

struct ClaudeUsage: Equatable, Sendable {
    let plan: String?
    let spend: ClaudeSpend?          // Enterprise/Team monthly spend limit
    let windows: [ClaudeWindow]      // 5-hour and 7-day windows on plans that have them

    // Spend limit wins when present; otherwise the fuller rate window.
    var percent: Int? {
        if let spend { return spend.percent }
        return windows.map(\.utilization).max().map { Int($0) }
    }

    var shortStatus: String { percent.map { "\($0)%" } ?? "n/a" }
}

struct CodexWindow: Equatable, Sendable {
    let usedPercent: Double
    let windowSeconds: Int?
    let resetAt: Date?

    var label: String {
        guard let seconds = windowSeconds else { return "Rate limit" }
        if seconds == 604_800 { return "Weekly limit" }
        return "\(seconds / 3600)-hour limit"
    }
}

struct CodexSpend: Equatable, Sendable {
    let used: Double?
    let limit: Double?
    let remaining: Double?
    let unit: String?
    let usedPercent: Double
    let resetAt: Date?
}

struct CodexUsage: Equatable, Sendable {
    let planType: String?
    let spend: CodexSpend?
    let primary: CodexWindow?
    let secondary: CodexWindow?
    let unlimitedCredits: Bool
    let limitReached: Bool

    // Show the fullest spending or rate limit. Nil when no metered limit is reported.
    var percent: Int? {
        let values = [spend?.usedPercent, primary?.usedPercent, secondary?.usedPercent].compactMap { $0 }
        return values.max().map { Int($0) }
    }

    var shortStatus: String {
        if limitReached { return "LIMITED" }
        if let percent { return "\(percent)%" }
        return unlimitedCredits ? "OK" : "n/a"
    }
}

enum UsageError: LocalizedError, Equatable {
    case missingField(String)
    case invalidField(String)
    case credentialsUnavailable(String)
    case unauthorized(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidField(let field): return "response has invalid \(field)"
        case .missingField(let field): return "response missing \(field)"
        case .credentialsUnavailable(let why): return why
        case .unauthorized(let who): return "\(who) token rejected; open \(who) to refresh it"
        case .http(let code): return "HTTP \(code)"
        }
    }
}

// MARK: - Parsing

// Preserve legitimate overage percentages, but reject values that cannot be
// safely displayed as an integer. Provider values never reach conversion unchecked.
private func validatePercent(_ value: Double, field: String) throws {
    guard value.isFinite, value >= 0, value < Double(Int.max) else {
        throw UsageError.invalidField(field)
    }
}

private func validatedDate(_ seconds: Double) throws -> Date {
    guard seconds.isFinite, (0...253_402_300_799).contains(seconds) else {
        throw UsageError.invalidField("reset timestamp")
    }
    return Date(timeIntervalSince1970: seconds)
}

private func resetDate(at: Double?, after: Double?, now: Date) throws -> Date? {
    if let at { return try validatedDate(at) }
    if let after {
        guard after.isFinite, after >= 0 else { throw UsageError.invalidField("reset interval") }
        return try validatedDate(now.timeIntervalSince1970 + after)
    }
    return nil
}

private struct ClaudeResponse: Decodable {
    struct Money: Decodable { let amountMinor: Int; let currency: String; let exponent: Int }
    struct Spend: Decodable { let used: Money?; let limit: Money? }
    struct Window: Decodable { let utilization: Double?; let resetsAt: FlexibleDate? }
    let spend: Spend?
    let fiveHour: Window?
    let sevenDay: Window?
}

// resets_at has been seen as an ISO 8601 string; accept a unix timestamp too.
struct FlexibleDate: Decodable {
    let date: Date?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Double.self) { date = try validatedDate(seconds); return }
        if let text = try? container.decode(String.self) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = iso.date(from: text) ?? ISO8601DateFormatter().date(from: text)
            return
        }
        date = nil
    }
}

func parseClaudeUsage(_ data: Data, plan: String? = nil) throws -> ClaudeUsage {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let response = try decoder.decode(ClaudeResponse.self, from: data)

    var spend: ClaudeSpend?
    if let used = response.spend?.used, let limit = response.spend?.limit {
        guard used.amountMinor >= 0, limit.amountMinor >= 0,
              (0...9).contains(used.exponent), used.exponent == limit.exponent,
              used.currency == limit.currency else {
            throw UsageError.invalidField("spend amounts or units")
        }
        if limit.amountMinor > 0 {
            try validatePercent(Double(used.amountMinor) * 100 / Double(limit.amountMinor), field: "spend percent")
        }
        spend = ClaudeSpend(usedMinor: used.amountMinor, limitMinor: limit.amountMinor,
                            exponent: used.exponent, currency: used.currency)
    }

    func window(_ raw: ClaudeResponse.Window?, _ label: String) throws -> ClaudeWindow? {
        guard let raw, let utilization = raw.utilization else { return nil }
        try validatePercent(utilization, field: "utilization")
        return ClaudeWindow(label: label, utilization: utilization, resetsAt: raw.resetsAt?.date)
    }
    let windows = try [window(response.fiveHour, "5-hour limit"), window(response.sevenDay, "Weekly limit")].compactMap { $0 }

    guard spend != nil || !windows.isEmpty else { throw UsageError.missingField("spend limit or rate limits") }
    return ClaudeUsage(plan: plan, spend: spend, windows: windows)
}

private struct CodexResponse: Decodable {
    struct Window: Decodable {
        let usedPercent: Double?
        let limitWindowSeconds: Int?
        let resetAt: Double?
        let resetAfterSeconds: Double?
    }
    struct RateLimit: Decodable { let primaryWindow: Window?; let secondaryWindow: Window? }
    struct Credits: Decodable { let unlimited: Bool? }
    struct SpendControl: Decodable {
        struct IndividualLimit: Decodable {
            let unit: String?
            let limit: FlexibleNumber?
            let used: FlexibleNumber?
            let remaining: FlexibleNumber?
            let usedPercent: Double?
            let resetAt: Double?
            let resetAfterSeconds: Double?
        }
        let reached: Bool?
        let individualLimit: IndividualLimit?
    }
    let planType: String?
    let rateLimit: RateLimit?
    let rateLimitReachedType: String?
    let credits: Credits?
    let spendControl: SpendControl?
}

// Credit amounts are strings in the usage endpoint; accept JSON numbers too.
private struct FlexibleNumber: Decodable {
    let value: Double?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let number: Double?
        if let text = try? container.decode(String.self) { number = Double(text) }
        else { number = try? container.decode(Double.self) }
        if let number, !number.isFinite || number < 0 {
            throw UsageError.invalidField("credit amount")
        }
        value = number
    }
}

func parseCodexUsage(_ data: Data, now: Date = Date()) throws -> CodexUsage {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let response = try decoder.decode(CodexResponse.self, from: data)

    func window(_ raw: CodexResponse.Window?) throws -> CodexWindow? {
        guard let raw, let used = raw.usedPercent else { return nil }
        try validatePercent(used, field: "used percent")
        if let seconds = raw.limitWindowSeconds, seconds <= 0 {
            throw UsageError.invalidField("limit window seconds")
        }
        let reset = try resetDate(at: raw.resetAt, after: raw.resetAfterSeconds, now: now)
        return CodexWindow(usedPercent: used, windowSeconds: raw.limitWindowSeconds, resetAt: reset)
    }

    var spend: CodexSpend?
    if let raw = response.spendControl?.individualLimit {
        let used = raw.used?.value
        let limit = raw.limit?.value
        let percent = raw.usedPercent ?? used.flatMap { used in
            limit.flatMap { $0 > 0 ? used * 100 / $0 : nil }
        }
        if let percent {
            try validatePercent(percent, field: "spend percent")
            let reset = try resetDate(at: raw.resetAt, after: raw.resetAfterSeconds, now: now)
            spend = CodexSpend(used: used, limit: limit, remaining: raw.remaining?.value,
                               unit: raw.unit, usedPercent: percent, resetAt: reset)
        }
    }

    return CodexUsage(planType: response.planType,
                      spend: spend,
                      primary: try window(response.rateLimit?.primaryWindow),
                      secondary: try window(response.rateLimit?.secondaryWindow),
                      unlimitedCredits: response.credits?.unlimited ?? false,
                      limitReached: response.rateLimitReachedType != nil || response.spendControl?.reached == true)
}

// MARK: - Dates

let utc = TimeZone(identifier: "UTC")!

// Claude's monthly spend limit resets at 00:00 UTC on the 1st (shown as 8 PM EDT on the last day).
func nextMonthStartUTC(after date: Date) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
    return calendar.date(byAdding: .month, value: 1, to: thisMonth)!
}

func daysUntil(_ date: Date, from now: Date) -> Int {
    Int(ceil(date.timeIntervalSince(now) / 86_400))
}

// MARK: - Formatting

func formatMoney(_ amount: Double, currency: String) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = currency
    formatter.locale = Locale(identifier: "en_US")
    return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f %@", amount, currency)
}

func formatReset(_ date: Date, now: Date, timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.timeZone = timeZone
    formatter.dateFormat = date.timeIntervalSince(now) < 86_400 ? "h:mm a" : "EEE h:mm a"
    return formatter.string(from: date)
}

func menubarText(claude: String, codex: String) -> String {
    "Claude \(claude)  Codex \(codex)"
}

func claudeLines(_ usage: ClaudeUsage, now: Date, timeZone: TimeZone = .current) -> [String] {
    var lines: [String] = []
    if let spend = usage.spend {
        let reset = nextMonthStartUTC(after: now)
        let resetFormatter = DateFormatter()
        resetFormatter.locale = Locale(identifier: "en_US")
        resetFormatter.timeZone = timeZone
        resetFormatter.dateFormat = "MMM d, h:mm a"
        lines.append("\(formatMoney(spend.used, currency: spend.currency)) of \(formatMoney(spend.limit, currency: spend.currency)) · \(formatMoney(spend.remaining, currency: spend.currency)) left")
        lines.append("Resets in \(daysUntil(reset, from: now)) days (\(resetFormatter.string(from: reset)))")
    }
    for window in usage.windows {
        var line = "\(window.label) \(Int(window.utilization))%"
        if let reset = window.resetsAt { line += " · resets \(formatReset(reset, now: now, timeZone: timeZone))" }
        lines.append(line)
    }
    return lines
}

func codexLines(_ usage: CodexUsage, now: Date, timeZone: TimeZone = .current) -> [String] {
    var lines: [String] = [usage.primary, usage.secondary].compactMap { window in
        guard let window else { return nil }
        var line = "\(window.label) \(Int(window.usedPercent))%"
        if let reset = window.resetAt { line += " · resets \(formatReset(reset, now: now, timeZone: timeZone))" }
        return line
    }
    if let spend = usage.spend {
        var details: [String] = []
        if let used = spend.used, let limit = spend.limit {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.locale = Locale(identifier: "en_US")
            formatter.maximumFractionDigits = 2
            func amount(_ value: Double) -> String {
                formatter.string(from: NSNumber(value: value)) ?? String(value)
            }
            let unit = spend.unit == "credit" ? "credits" : (spend.unit ?? "units")
            var line = "\(amount(used)) of \(amount(limit)) \(unit)"
            if let remaining = spend.remaining { line += " · \(amount(remaining)) left" }
            details.append(line)
        }
        if let reset = spend.resetAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.timeZone = timeZone
            formatter.dateFormat = "MMM d, h:mm a"
            details.append("Resets in \(daysUntil(reset, from: now)) days (\(formatter.string(from: reset)))")
        }
        lines.insert(contentsOf: details, at: 0)
    }
    if lines.isEmpty {
        lines.append(usage.unlimitedCredits ? "Unlimited credits, no rate limits" : "No rate limits reported")
    }
    if usage.limitReached { lines.append("Limit reached") }
    return lines
}
