# ai-usage-bar

macOS only.

A native macOS menubar app that shows how much of your AI coding tools' quota
you have used. One Swift executable, compiled locally with Apple's Command Line
Tools. No dependencies, no third-party binaries, nothing phones home except the
two usage endpoints the tools themselves already call.

    Claude 85%  Codex OK

The menu bar uses compact white Claude and Codex logos on transparent backgrounds,
with each usage percentage to its right. Hover for service names.

Click it for the detail:

    Claude (Enterprise)
        $1,700.35 of $2,000.00 · $299.65 left
        Resets in 14 days (Sep 30, 8:00 PM)
    Codex (Business)
        Unlimited credits, no rate limits
    Refreshed 11:14 AM
    Refresh now
    Quit

## What it reads

| Provider | Source | Shown |
|----------|--------|-------|
| Claude | Claude Code's OAuth token in Keychain, and the usage endpoint behind Claude Code's `/usage` command | Monthly spend against the plan limit (Enterprise/Team), or the 5-hour and 7-day rate limits on plans that have them |
| Codex | `~/.codex/auth.json` and the Codex rate-limit endpoint | Individual spending limits (credits and reset date), or 5-hour and weekly rate limits when metered, `OK` when the plan is unmetered, `LIMITED` when OpenAI reports a cap reached |

The ChatGPT chat app is not shown. It exposes no usage data locally and OpenAI
has no consumer usage API.

The Claude reset date is computed as 00:00 UTC on the 1st of next month (the
desktop app shows this as 8:00 PM Eastern on the last day). The API does not
return it.

The app only reads tokens. It never refreshes, rotates, writes, or logs them.
If a token has expired the dropdown says so and asks you to open the owning
tool, which refreshes it.

## Requirements

- macOS 13 or later on Apple Silicon or Intel
- Apple Command Line Tools (`xcode-select --install`). Full Xcode is not needed.
- Claude Code logged in (for the Claude line), Codex CLI or app logged in with
  ChatGPT (for the Codex line). Either can be missing; the other still works.

## Install

    git clone https://github.com/JustinPerlman/ai-usage-bar.git
    cd ai-usage-bar
    ./test.sh        # run the fixture tests
    ./build.sh       # compile to build/AIUsageBar
    ./install.sh     # start now and at every login

The Claude token is read through `/usr/bin/security`, the same tool Claude Code
uses to write it. Whether macOS prompts depends on the item’s access settings. (Reading
the item directly from the app did prompt: Claude Code rewrites the item on
every token refresh, which wipes any "Always Allow" grant within hours.)

Useful commands:

    ./build/AIUsageBar --check   # print the numbers to Terminal, no menubar
    ./uninstall.sh               # stop the app and remove the LaunchAgent

If the menubar item does not appear on a MacBook screen, the menubar is full
and macOS hid it. It will show on an external display; on the built-in screen,
remove other menubar icons to make room.

## Operating it

The LaunchAgent restarts the app automatically after a crash. Choosing
**Quit** from the menu is treated as deliberate and it stays down until you
start it again or log in.

    launchctl kickstart gui/$(id -u)/local.ai-usage-bar          # start it again after Quit
    launchctl print gui/$(id -u)/local.ai-usage-bar | grep -E 'state|pid'   # is it running?
    cat build/stderr.log                                        # crash output, if any
    ./build/AIUsageBar --check                                  # run the fetches in Terminal

If `launchctl print` says the service could not be found, run `./install.sh`.
After pulling new code, run `./build.sh` then `./install.sh` to relaunch on the
new binary.

## Layout

- `Sources/Model.swift`: parsing, date math, formatting. Pure functions, all tested.
- `Sources/Fetch.swift`: Keychain read, file read, HTTP. Never logs a token.
- `Sources/App.swift`: the menubar item and dropdown.
- `Sources/main.swift`: entry point and the `--check` mode.
- `Tests/main.swift`: fixture tests, run with `./test.sh`.

## Known gaps

- Claude 5-hour and 7-day rate-limit parsing is tested against fixtures only. The
  author's Enterprise account returns those fields as null, so the live shape
  has not been observed. If yours renders oddly, open an issue with the output
  of `--check`.
- Refresh interval is fixed at 5 minutes.

## Security and sharing

Build from source in a directory only your user can modify. The installer runs
as your user, verifies the executable, and validates the LaunchAgent before
restarting the app. It does not need sudo. Moving the checkout requires reinstalling.

The app reads existing provider access tokens; these are sensitive credentials,
not dedicated read-only usage tokens. It sends them only to the fixed HTTPS usage
endpoints in `Sources/Fetch.swift`. Networking uses an ephemeral session with
caching, cookies, and credential storage disabled, and refuses all redirects.
System certificate validation remains enabled. This does not clear any caches
created by older versions or prevent operating-system memory/crash diagnostics.

No tokens are included in the repository or intentionally logged. `--check`
prints account usage, so review its output before sharing. Test amounts added by
this fork are synthetic. The original upstream history is retained.

Share the repository rather than a copy of your working directory or `build/`.
The locally built executable is not a notarized distribution package. Each user
must have the supported local login files and permissions; provider endpoints
can change without notice. Follow your organization's rules for credential access.
