#!/bin/sh
set -eu

usage() {
  cat <<'USAGE'
Usage:
  uninstall-launchagent.sh [--plist PATH] [--keep-plist]

Unloads the per-user macos-auth LaunchAgent and removes its plist by default.

Options:
  --plist PATH   Default: ~/Library/LaunchAgents/com.macos-auth.agent.plist
  --keep-plist   Unload but do not remove the plist
  -h, --help     Show this help
USAGE
}

plist_path="$HOME/Library/LaunchAgents/com.macos-auth.agent.plist"
keep_plist=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --plist)
      plist_path="$2"
      shift 2
      ;;
    --keep-plist)
      keep_plist=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

launchctl bootout "gui/$(id -u)" "$plist_path" >/dev/null 2>&1 || true

if [ "$keep_plist" -ne 1 ]; then
  rm -f "$plist_path"
fi

echo "Unloaded macos-auth LaunchAgent"
if [ "$keep_plist" -ne 1 ]; then
  echo "Removed $plist_path"
fi
