#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
review_directory=$(mktemp -d "$PWD/build/installer-test.XXXXXX")
trap 'rm -rf -- "$review_directory"' EXIT
special_directory="$review_directory/A & B <tools> \"quoted\" 'single'"
mkdir -p "$special_directory"
binary="$special_directory/App"
# A fixture executable; it is never launched.
printf '#!/bin/sh\nexit 0\n' > "$binary"
chmod 700 "$binary"
output_plist="$review_directory/agent.plist"
/bin/zsh scripts/write-launch-agent.sh "$binary" "$special_directory/log" "$output_plist"
[[ "$(/usr/bin/plutil -extract ProgramArguments.0 raw "$output_plist")" == "$binary" ]]
[[ "$(/usr/bin/plutil -extract StandardErrorPath raw "$output_plist")" == "$special_directory/log" ]]
[[ "$(/usr/bin/plutil -extract KeepAlive.SuccessfulExit raw "$output_plist")" == false ]]
before=$(shasum -a 256 "$output_plist")
if /bin/zsh scripts/write-launch-agent.sh "$review_directory/missing" "$special_directory/log" "$output_plist" 2>/dev/null; then
    print -u2 'Missing executable was accepted'
    exit 1
fi
[[ "$(shasum -a 256 "$output_plist")" == "$before" ]]
chmod 600 "$binary"
if /bin/zsh scripts/write-launch-agent.sh "$binary" "$special_directory/log" "$output_plist" 2>/dev/null; then
    print -u2 'Non-executable file was accepted'
    exit 1
fi
print 'Installer checks passed: special paths round-trip; invalid executables leave existing plist intact'
