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

// MARK: Rate limiting
print("Rate limiting")
check(parseRetryAfter("120", now: now), 120, "Retry-After seconds")
check(parseRetryAfter(" 0 ", now: now), 0, "Retry-After zero with whitespace")
check(parseRetryAfter("-5", now: now), nil, "negative Retry-After rejected")
check(parseRetryAfter("soon", now: now), nil, "garbage Retry-After rejected")
check(parseRetryAfter(nil, now: now), nil, "missing Retry-After")
check(parseRetryAfter("Thu, 17 Sep 2026 13:55:00 GMT", now: now), 180, "Retry-After HTTP date")
check(parseRetryAfter("Thu, 17 Sep 2026 13:00:00 GMT", now: now), 0, "past Retry-After date clamps to zero")
check([1, 2, 3, 4, 9].map { rateLimitDelay(strikes: $0, retryAfter: nil) }, [300, 600, 1200, 1800, 1800],
      "backoff doubles from 5 minutes and caps at 30")
check(rateLimitDelay(strikes: 3, retryAfter: 90), 90, "Retry-After overrides backoff")
check(rateLimitDelay(strikes: 1, retryAfter: 86_400), 3_600, "Retry-After capped at an hour")

var feed = Feed<Int>()
check(feed.isDue(now), true, "new feed is due")
feed.record(.success(42), now: now)
feed.record(.failure(UsageError.rateLimited(retryAfter: nil)), now: now)
check(feed.usage, 42, "429 keeps last good reading")
check(feed.isStale, true, "429 marks reading stale")
check(feed.retryAt, now.addingTimeInterval(300), "first 429 waits 5 minutes")
check(feed.isDue(now.addingTimeInterval(299)), false, "not due during backoff")
check(feed.isDue(now.addingTimeInterval(300)), true, "due once backoff ends")
feed.record(.failure(UsageError.rateLimited(retryAfter: nil)), now: now)
check(feed.retryAt, now.addingTimeInterval(600), "second 429 waits 10 minutes")
feed.record(.success(7), now: now)
check(feed.usage, 7, "success replaces reading")
check(feed.isStale, false, "success clears stale")
check(feed.retryAt, nil, "success clears backoff")
feed.record(.failure(UsageError.rateLimited(retryAfter: nil)), now: now)
check(feed.retryAt, now.addingTimeInterval(300), "backoff restarts after success")
feed.record(.failure(UsageError.http(500)), now: now)
check(feed.usage, nil, "non-429 failure clears reading")
check(feed.retryAt, nil, "non-429 failure does not back off")

// MARK: Pace
print("Pace")
check(paceFor(usedPercent: 30, weekdaysLeft: 0.5), .green, "30% used, half the weekdays left")
check(paceFor(usedPercent: 50, weekdaysLeft: 0.5), .green, "exactly on pace")
check(paceFor(usedPercent: 60, weekdaysLeft: 0.5), .yellow, "60% used, half left")
check(paceFor(usedPercent: 70, weekdaysLeft: 0.5), .orange, "70% used, half left")
check(paceFor(usedPercent: 90, weekdaysLeft: 0.5), .red, "90% used, half left")
check(paceFor(usedPercent: 100, weekdaysLeft: 0.9), .red, "limit used up")
check(paceFor(usedPercent: 99, weekdaysLeft: 0), .green, "no weekdays left and limit not hit")
check(paceFor(usedPercent: 20, weekdaysLeft: 1), .yellow, "a fifth gone before the cycle starts")

let monday = Date(timeIntervalSince1970: 1_789_344_000) // 2026-09-14 00:00 UTC
let nextMonday = monday.addingTimeInterval(7 * 86_400)
check(weekdaysLeft(start: monday, end: nextMonday, now: monday.addingTimeInterval(2.5 * 86_400), timeZone: utc),
      0.5, "Wednesday noon is halfway through the work week")
check(weekdaysLeft(start: monday, end: nextMonday, now: monday.addingTimeInterval(5.5 * 86_400), timeZone: utc),
      0, "Saturday has no weekdays left")
check(weekdaysLeft(start: monday, end: nextMonday, now: monday.addingTimeInterval(-86_400), timeZone: utc),
      1, "before the cycle all weekdays are left")
check(weekdaysLeft(start: monday.addingTimeInterval(5 * 86_400), end: nextMonday, now: monday, timeZone: utc),
      nil, "a weekend-only cycle has no weekdays")

let weekly = ClaudeUsage(plan: nil, spend: nil, windows: [
    ClaudeWindow(label: "5-hour limit", utilization: 95, resetsAt: nextMonday),
    ClaudeWindow(label: "Weekly limit", utilization: 60, resetsAt: nextMonday)])
let weeklyPace = claudePace(weekly, now: monday.addingTimeInterval(2.5 * 86_400), timeZone: utc)
check(weeklyPace.map(\.label), ["Weekly limit"], "5-hour window is not paced")
check(worstPace(weeklyPace), .yellow, "Claude weekly 60% at midweek is yellow")
check(weeklyPace.first?.line, "Weekly limit 60% used · 50% of weekdays left", "pace line")

let codexWeekly = CodexUsage(planType: nil, spend: nil,
    primary: CodexWindow(usedPercent: 99, windowSeconds: 18_000, resetAt: nextMonday),
    secondary: CodexWindow(usedPercent: 30, windowSeconds: 604_800, resetAt: nextMonday),
    unlimitedCredits: false, limitReached: false)
check(worstPace(codexPace(codexWeekly, now: monday.addingTimeInterval(2.5 * 86_400), timeZone: utc)), .green,
      "Codex weekly 30% at midweek is green; 5-hour window ignored")
check(menubarText(claude: "60%", codex: "30%", claudePace: .yellow, codexPace: .green),
      "Claude 60% (running a bit fast)  Codex 30% (on pace)", "tooltip includes pace")

// MARK: Pace edge cases
print("Pace edge cases")
let midweek = monday.addingTimeInterval(2.5 * 86_400)
func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.0001 } ?? false }

// Claude monthly spend, Eastern time: cycle is Aug 31 8 PM to Sep 30 8 PM EDT (22 weekdays);
// from Thu Sep 17 9:52 AM, 9.4222 weekdays remain.
func claudeSpend(_ used: Int, _ limit: Int) -> ClaudeUsage {
    ClaudeUsage(plan: nil, spend: ClaudeSpend(usedMinor: used, limitMinor: limit, exponent: 2, currency: "USD"), windows: [])
}
let spendPace = claudePace(claudeSpend(50_000, 100_000), now: now, timeZone: eastern)
check(spendPace.map(\.label), ["Spend"], "Claude spend is paced")
check(near(spendPace.first?.weekdaysLeft, 226.1333 / 528), true, "Claude spend weekdays left in Eastern time")
check(worstPace(spendPace), .green, "Claude spend 50% with 43% of weekdays left is green")
check(worstPace(claudePace(claudeSpend(80_000, 100_000), now: now, timeZone: eastern)), .orange,
      "Claude spend 80% with 43% of weekdays left is orange")
check(claudePace(claudeSpend(0, 0), now: now, timeZone: eastern), [], "zero spend limit is skipped")

// Codex spend: cycle is the calendar month before the reset.
let decFirst = Date(timeIntervalSince1970: 1_796_083_200) // 2026-12-01 00:00 UTC
let novFirst = Date(timeIntervalSince1970: 1_793_491_200) // 2026-11-01 00:00 UTC
let nov17 = Date(timeIntervalSince1970: 1_794_916_800)    // 2026-11-17 12:00 UTC
let codexSpendUsage = CodexUsage(planType: nil,
    spend: CodexSpend(used: 13, limit: 100, remaining: 87, unit: "credit", usedPercent: 13, resetAt: decFirst),
    primary: nil, secondary: nil, unlimitedCredits: false, limitReached: false)
let codexSpendPace = codexPace(codexSpendUsage, now: nov17, timeZone: utc)
check(codexSpendPace.map(\.label), ["Spend"], "Codex spend is paced")
check(codexSpendPace.first?.weekdaysLeft, weekdaysLeft(start: novFirst, end: decFirst, now: nov17, timeZone: utc),
      "Codex spend cycle starts a month before the reset")

// Daylight saving: Sat Oct 31 to Sat Nov 7 in Los Angeles crosses the Nov 1 clock change.
let pacific = TimeZone(identifier: "America/Los_Angeles")!
var laCalendar = Calendar(identifier: .gregorian)
laCalendar.timeZone = pacific
let dstStart = laCalendar.date(from: DateComponents(year: 2026, month: 10, day: 31))!
let dstEnd = laCalendar.date(from: DateComponents(year: 2026, month: 11, day: 7))!
let dstNoon = laCalendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12))!
check(weekdaysLeft(start: dstStart, end: dstEnd, now: dstNoon, timeZone: pacific), 0.5,
      "Wednesday noon is halfway through a week that crosses the DST change")

// Overage, missing reset, and a reset already past.
let over = ClaudeUsage(plan: nil, spend: nil, windows: [ClaudeWindow(label: "Weekly limit", utilization: 150, resetsAt: nextMonday)])
let overPace = claudePace(over, now: midweek, timeZone: utc)
check(worstPace(overPace), .red, "usage over 100% is red")
check(overPace.first?.line, "Weekly limit 150% used · 50% of weekdays left", "overage line")
let noReset = ClaudeUsage(plan: nil, spend: nil, windows: [ClaudeWindow(label: "Weekly limit", utilization: 60, resetsAt: nil)])
check(claudePace(noReset, now: midweek, timeZone: utc), [], "window without a reset time is skipped")
let afterReset = nextMonday.addingTimeInterval(3_600)
check(claudePace(weekly, now: afterReset, timeZone: utc), [], "Claude reading past its reset is dropped")
check(codexPace(codexWeekly, now: afterReset, timeZone: utc), [], "Codex reading past its reset is dropped")
check(codexPace(codexSpendUsage, now: decFirst, timeZone: utc), [], "Codex spend at its reset instant is dropped")

// A used-up limit of any length makes the service red.
let fiveHourOut = ClaudeUsage(plan: nil, spend: nil, windows: [
    ClaudeWindow(label: "5-hour limit", utilization: 100, resetsAt: nextMonday),
    ClaudeWindow(label: "Weekly limit", utilization: 20, resetsAt: nextMonday)])
check(fiveHourOut.limitReached, true, "Claude 5-hour window at 100% counts as limit reached")
check(servicePace(claudePace(fiveHourOut, now: midweek, timeZone: utc), limitReached: fiveHourOut.limitReached),
      .limited, "Claude used-up 5-hour window beats an on-pace weekly")
check(claudeSpend(100_000, 100_000).limitReached, true, "Claude spend at its limit counts as reached")
check(weekly.limitReached, false, "Claude under every limit is not reached")
check(servicePace(claudePace(weekly, now: midweek, timeZone: utc), limitReached: weekly.limitReached),
      .yellow, "without a used-up limit the pace color is kept")
let codexFlagged = CodexUsage(planType: nil, spend: nil,
    primary: CodexWindow(usedPercent: 40, windowSeconds: 18_000, resetAt: nextMonday),
    secondary: CodexWindow(usedPercent: 30, windowSeconds: 604_800, resetAt: nextMonday),
    unlimitedCredits: false, limitReached: true)
check(servicePace(codexPace(codexFlagged, now: midweek, timeZone: utc), limitReached: codexFlagged.anyLimitReached),
      .limited, "Codex reported as limited is red")
check(codexWeekly.anyLimitReached, false, "Codex 5-hour at 99% is not reached")
let codexFiveHourOut = CodexUsage(planType: nil, spend: nil,
    primary: CodexWindow(usedPercent: 100, windowSeconds: 18_000, resetAt: nextMonday),
    secondary: nil, unlimitedCredits: false, limitReached: false)
check(codexFiveHourOut.anyLimitReached, true, "Codex 5-hour at 100% counts as reached")
check(menubarText(claude: "100%", codex: "LIMITED", claudePace: .limited, codexPace: .limited),
      "Claude 100% (limit reached)  Codex LIMITED (limit reached)", "tooltip says limit reached")

print(failures == 0 ? "\nAll checks passed" : "\n\(failures) check(s) FAILED")
exit(failures == 0 ? 0 : 1)
