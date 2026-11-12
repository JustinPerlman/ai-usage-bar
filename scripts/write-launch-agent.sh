#!/bin/zsh
# Generate a plist without interpolating filesystem paths into XML.
set -euo pipefail
if (( $# != 3 )); then
    print -u2 'Usage: write-launch-agent.sh EXECUTABLE LOG_PATH OUTPUT_PLIST'
    exit 1
fi
binary=$1
log_path=$2
output_plist=$3
if [[ "$binary" != /* || ! -f "$binary" || ! -x "$binary" ]]; then
    print -u2 'App executable is missing or not executable; run ./build.sh first.'
    exit 1
fi
/usr/bin/plutil -create xml1 "$output_plist"
/usr/bin/plutil -insert Label -string local.ai-usage-bar "$output_plist"
/usr/bin/plutil -insert ProgramArguments -array "$output_plist"
/usr/bin/plutil -insert ProgramArguments.0 -string "$binary" "$output_plist"
/usr/bin/plutil -insert RunAtLoad -bool YES "$output_plist"
/usr/bin/plutil -insert KeepAlive -dictionary "$output_plist"
/usr/bin/plutil -insert KeepAlive.SuccessfulExit -bool NO "$output_plist"
/usr/bin/plutil -insert StandardErrorPath -string "$log_path" "$output_plist"
/usr/bin/plutil -lint -s "$output_plist"
