#!/bin/sh
set -eu

usage() {
  cat <<'USAGE'
Usage:
  status-launchagent.sh [--label LABEL]

Shows launchctl status for the macos-auth LaunchAgent.

Options:
  --label LABEL  Default: com.macos-auth.agent
  -h, --help     Show this help
USAGE
}

label="com.macos-auth.agent"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --label)
      label="$2"
      shift 2
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

launchctl print "gui/$(id -u)/$label"
