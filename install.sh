#!/bin/zsh
# Installs a per-user LaunchAgent; never run this script with sudo.
set -euo pipefail
cd "$(dirname "$0")"
if (( EUID == 0 )); then
    print -u2 'Run this installer as your normal user, without sudo.'
    exit 1
fi
binary="$PWD/build/AIUsageBar"
if [[ ! -f "$binary" || ! -x "$binary" ]]; then
    print -u2 'App executable is missing or not executable; run ./build.sh first.'
    exit 1
fi
umask 077
label=local.ai-usage-bar
agent_directory=~/Library/LaunchAgents
mkdir -p "$agent_directory"
plist="$agent_directory/$label.plist"
temporary_plist=$(mktemp "$agent_directory/.$label.XXXXXX")
trap 'rm -f -- "$temporary_plist"' EXIT
/bin/zsh scripts/write-launch-agent.sh "$binary" "$PWD/build/stderr.log" "$temporary_plist"
# Replace only after generation and validation succeed; existing service stays
# running if preparation fails. Rename also avoids following a target symlink.
mv -f -- "$temporary_plist" "$plist"
launchctl bootout gui/$(id -u)/$label 2>/dev/null || true
launchctl bootstrap gui/$(id -u) "$plist"
echo "installed and started $label"
