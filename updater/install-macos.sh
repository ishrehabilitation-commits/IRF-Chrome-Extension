#!/bin/bash
# One-time setup so the panel's "Update now" button works on this computer.
# Run it from a Terminal:   bash updater/install-macos.sh
#
# It tells Chrome that the IRF Minutes extension is allowed to run
# updater/irf_updater.py, which is what pulls the new files.

set -euo pipefail

EXTENSION_ID="mmibabdnhomcdfpmhfchijiociknhibo"
HOST_NAME="com.irf.minutes.updater"

updater_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
host_path="$updater_dir/irf_updater.py"

command -v git >/dev/null || { echo "git isn't installed. Install it first." >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 isn't installed. Install it first." >&2; exit 1; }
chmod +x "$host_path"

# Run the helper the way Chrome will, without changing anything.
if ! "$host_path" --check; then
  echo "The updater couldn't run here; see $updater_dir/updater.log." >&2
  exit 1
fi

for browser_dir in \
  "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts" \
  "$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts"
do
  [ -d "$(dirname "$browser_dir")" ] || continue
  mkdir -p "$browser_dir"
  cat > "$browser_dir/$HOST_NAME.json" <<JSON
{
  "name": "$HOST_NAME",
  "description": "IRF Minutes updater",
  "path": "$host_path",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXTENSION_ID/"]
}
JSON
  echo "Registered in $browser_dir"
done

echo "Done. Restart Chrome, then the Update now button will work."
