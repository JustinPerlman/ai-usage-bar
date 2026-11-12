import Foundation

// Fixture-driven checks for Sources/Model.swift. Run with ./test.sh.

var failures = 0
@MainActor func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("  ok   \(message)") } else { failures += 1; print("  FAIL \(message) (line \(line))") }
}
@MainActor func check<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
    check(actual == expected, "\(message): got \(actual)", line: line)
}

let eastern = TimeZone(identifier: "America/New_York")!
// 2026-09-17 13:52:00 UTC (9:52 AM EDT)
let now = Date(timeIntervalSince1970: 1_789_653_120)

// MARK: Claude parsing (fixture shaped like the live response on 2026-09-17)
let claudeJSON = """
{"five_hour":null,"seven_day":null,
 "spend":{"used":{"amount_minor":169070,"currency":"USD","exponent":2},
          "limit":{"amount_minor":200000,"currency":"USD","exponent":2},
          "percent":85,"severity":"warning","enabled":true}}
""".data(using: .utf8)!
print("Claude parsing")
do {
    let usage = try parseClaudeUsage(claudeJSON, plan: "enterprise")
    let spend = usage.spend!
    check(spend.used, 1690.70, "used dollars")
    check(spend.limit, 2000.0, "limit dollars")
    check(spend.remaining, 309.30, "remaining dollars")
    check(usage.percent, 84, "percent floors like the desktop app")
    check(usage.shortStatus, "84%", "short status")
    check(usage.plan, "enterprise", "plan carried through")
    check(usage.windows.isEmpty, "Enterprise has no rate windows")
    let lines = claudeLines(usage, now: now, timeZone: eastern)
    check(lines[0], "$1,690.70 of $2,000.00 · $309.30 left", "money line")
    check(lines[1], "Resets in 14 days (Sep 30, 8:00 PM)", "reset line in Eastern")
} catch { check(false, "unexpected error \(error)") }

print("Claude on a plan with rate limits and no spend limit")
let windowsJSON = """
{"five_hour":{"utilization":12.5,"resets_at":"2026-09-17T15:00:00.000000+00:00"},
 "seven_day":{"utilization":41.0,"resets_at":"2026-09-20T17:00:00Z"},
 "spend":null}
""".data(using: .utf8)!
do {
    let usage = try parseClaudeUsage(windowsJSON, plan: "max")
    check(usage.spend, nil, "no spend block")
    check(usage.windows.count, 2, "both windows parsed")
    check(usage.percent, 41, "percent is the fuller rate limit")
    let lines = claudeLines(usage, now: now, timeZone: eastern)
    check(lines, ["5-hour limit 12% · resets 11:00 AM", "Weekly limit 41% · resets Sun 1:00 PM"], "rate limit lines")
} catch { check(false, "unexpected error \(error)") }

print("Claude with neither spend nor rate limits")
let emptyJSON = #"{"five_hour":null,"seven_day":null,"spend":null}"#.data(using: .utf8)!
do { _ = try parseClaudeUsage(emptyJSON); check(false, "should have thrown") }
catch let error as UsageError { check(error, .missingField("spend limit or rate limits"), "clear error") }
catch { check(false, "wrong error type \(error)") }

// MARK: Codex parsing
let codexJSON = """
{"plan_type":"plus",
 "rate_limit":{"allowed":true,
   "primary_window":{"used_percent":12.4,"limit_window_seconds":18000,"reset_at":1789659600},
   "secondary_window":{"used_percent":34.0,"limit_window_seconds":604800,"reset_after_seconds":300000}}}
""".data(using: .utf8)!
print("Codex parsing")
do {
    let usage = try parseCodexUsage(codexJSON, now: now)
    check(usage.planType, "plus", "plan type")
    check(usage.primary?.label, "5-hour limit", "primary label")
    check(usage.secondary?.label, "Weekly limit", "secondary label")
    check(usage.percent, 34, "menubar percent is the fuller rate limit")
    check(usage.shortStatus, "34%", "short status uses the percent when metered")
    check(usage.secondary?.resetAt, now.addingTimeInterval(300_000), "reset_after_seconds fallback")
    let lines = codexLines(usage, now: now, timeZone: eastern)
    check(lines[0], "5-hour limit 12% · resets 11:40 AM", "primary line")
    check(lines[1], "Weekly limit 34% · resets Sun 9:12 PM", "secondary line shows weekday when >24h out")
} catch { check(false, "unexpected error \(error)") }

print("Codex on an unmetered Business plan (live shape on 2026-09-17)")
let businessJSON = """
{"plan_type":"business","rate_limit":null,"rate_limit_reached_type":null,
 "credits":{"unlimited":true,"has_credits":true,"balance":null},
 "spend_control":{"individual_limit":null,"reached":false}}
""".data(using: .utf8)!
do {
    let usage = try parseCodexUsage(businessJSON, now: now)
    check(usage.percent, nil, "no percent without rate limits")
    check(usage.shortStatus, "OK", "menubar shows OK when unlimited")
    check(codexLines(usage, now: now), ["Unlimited credits, no rate limits"], "dropdown explains no meter")
} catch { check(false, "unexpected error \(error)") }

print("Codex limit reached")
let limitedJSON = #"{"plan_type":"business","rate_limit":null,"rate_limit_reached_type":"weekly","credits":{"unlimited":false},"spend_control":{"reached":true}}"#.data(using: .utf8)!
do {
    let usage = try parseCodexUsage(limitedJSON, now: now)
    check(usage.shortStatus, "LIMITED", "menubar shows LIMITED")
    check(codexLines(usage, now: now), ["No rate limits reported", "Limit reached"], "dropdown flags the limit")
} catch { check(false, "unexpected error \(error)") }

print("Codex Business spending limit (synthetic values, production response shape)")
let spendJSON = """
{"plan_type":"business","rate_limit":null,"credits":{"unlimited":false},
 "spend_control":{"reached":false,"individual_limit":{"unit":"credit",
 "limit":"100000","used":"12345.67","remaining":"87654.33",
 "used_percent":12,"reset_at":1796083200,"reset_after_seconds":1574910}}}
""".data(using: .utf8)!
do {
    let usage = try parseCodexUsage(spendJSON, now: now)
    check(usage.shortStatus, "12%", "use server spending percentage")
    check(usage.spend?.limit, 100000, "parse string credit amounts")
    check(codexLines(usage, now: now, timeZone: eastern),
          ["12,345.67 of 100,000 credits · 87,654.33 left",
           "Resets in 75 days (Nov 30, 7:00 PM)"], "display amounts and reset countdown without redundant percentage")
    let combined = #"{"rate_limit":{"primary_window":{"used_percent":80}},"spend_control":{"reached":true,"individual_limit":{"used":25,"limit":100,"reset_after_seconds":60}}}"#.data(using: .utf8)!
    let mixed = try parseCodexUsage(combined, now: now)
    check(mixed.spend?.usedPercent, 25, "numeric amounts and percentage fallback")
    check(mixed.spend?.resetAt, now.addingTimeInterval(60), "spending reset fallback")
    check(mixed.percent, 80, "fullest limit wins across spend and rate windows")
    check(mixed.shortStatus, "LIMITED", "reached spending cap overrides percentage")
    let partial = #"{"spend_control":{"individual_limit":{"used":"invalid","limit":"0"}}}"#.data(using: .utf8)!
    check(try parseCodexUsage(partial).shortStatus, "n/a", "incomplete spending limit stays unavailable")
} catch { check(false, "unexpected error \(error)") }

// Malformed server data must throw instead of crashing during UI conversion.
print("Untrusted numeric response bounds")
let invalidCodex = [
    #"{"rate_limit":{"primary_window":{"used_percent":1e100}}}"#,
    #"{"rate_limit":{"primary_window":{"used_percent":-1}}}"#,
    #"{"rate_limit":{"primary_window":{"used_percent":1,"reset_at":1e100}}}"#,
    #"{"rate_limit":{"primary_window":{"used_percent":1,"reset_after_seconds":-1}}}"#,
    #"{"spend_control":{"individual_limit":{"used_percent":1e100}}}"#,
    #"{"spend_control":{"individual_limit":{"used":"1e308","limit":"0.01"}}}"#,
    #"{"spend_control":{"individual_limit":{"used":"-1","limit":"100"}}}"#,
    #"{"spend_control":{"individual_limit":{"used":"Infinity","limit":"100"}}}"#
]
for fixture in invalidCodex {
    do { _ = try parseCodexUsage(Data(fixture.utf8)); check(false, "invalid Codex numeric response accepted") }
    catch UsageError.invalidField { check(true, "invalid Codex numeric response rejected") }
    catch { check(false, "wrong error: \(error)") }
}
let invalidClaude = [
    #"{"five_hour":{"utilization":1e100}}"#,
    #"{"five_hour":{"utilization":-1}}"#,
    #"{"five_hour":{"utilization":1,"resets_at":1e100}}"#,
    #"{"spend":{"used":{"amount_minor":9223372036854775807,"currency":"USD","exponent":2},"limit":{"amount_minor":1,"currency":"USD","exponent":2}}}"#,
    #"{"spend":{"used":{"amount_minor":-9223372036854775808,"currency":"USD","exponent":2},"limit":{"amount_minor":1,"currency":"USD","exponent":2}}}"#,
    #"{"spend":{"used":{"amount_minor":1,"currency":"USD","exponent":-1000},"limit":{"amount_minor":1,"currency":"USD","exponent":-1000}}}"#
]
for fixture in invalidClaude {
    do { _ = try parseClaudeUsage(Data(fixture.utf8)); check(false, "invalid Claude numeric response accepted") }
    catch UsageError.invalidField { check(true, "invalid Claude numeric response rejected") }
    catch { check(false, "wrong error: \(error)") }
}
do {
    let overage = try parseCodexUsage(Data(#"{"rate_limit":{"primary_window":{"used_percent":125.5}}}"#.utf8))
    check(overage.shortStatus, "125%", "legitimate overage is preserved")
} catch { check(false, "overage rejected: \(error)") }

// MARK: Dates and text
print("Dates and text")
let reset = nextMonthStartUTC(after: now)
check(reset, Date(timeIntervalSince1970: 1_790_812_800), "next month start is 2026-10-01 00:00 UTC")
check(daysUntil(reset, from: now), 14, "days until reset rounds up")
let decReset = nextMonthStartUTC(after: Date(timeIntervalSince1970: 1_797_000_000)) // 2026-12-11
check(Calendar(identifier: .gregorian).dateComponents(in: utc, from: decReset).year, 2027, "December rolls into next year")
check(menubarText(claude: "84%", codex: "OK"), "Claude 84%  Codex OK", "menubar text")
check(formatMoney(0, currency: "USD"), "$0.00", "zero dollars")

print(failures == 0 ? "\nAll checks passed" : "\n\(failures) check(s) FAILED")
exit(failures == 0 ? 0 : 1)
