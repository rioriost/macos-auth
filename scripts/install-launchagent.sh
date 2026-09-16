#!/bin/sh
set -eu

usage() {
  cat <<'USAGE'
Usage:
  install-launchagent.sh --agent-bin PATH --config PATH [--log-dir PATH] [--plist PATH]

Installs a per-user LaunchAgent plist for macos-auth-agent.

Example:
  scripts/install-launchagent.sh \
    --agent-bin "$HOME/.local/bin/macos-auth-agent" \
    --config "$HOME/Library/Application Support/macos-auth/agent-config.json"
USAGE
}

agent_bin=""
config_path=""
log_dir="$HOME/Library/Logs/macos-auth"
plist_path="$HOME/Library/LaunchAgents/com.macos-auth.agent.plist"

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_template_path="$script_dir/../agent/launchd/com.macos-auth.agent.plist"
installed_template_path="$script_dir/../launchd/com.macos-auth.agent.plist"

if [ -f "$repo_template_path" ]; then
  template_path="$repo_template_path"
elif [ -f "$installed_template_path" ]; then
  template_path="$installed_template_path"
else
  echo "LaunchAgent template not found." >&2
  echo "Tried: $repo_template_path" >&2
  echo "Tried: $installed_template_path" >&2
  exit 1
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent-bin|--config|--log-dir|--plist)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for $1" >&2
        exit 2
      fi
      ;;
  esac
  case "$1" in
    --agent-bin)
      agent_bin="$2"
      shift 2
      ;;
    --config)
      config_path="$2"
      shift 2
      ;;
    --log-dir)
      log_dir="$2"
      shift 2
      ;;
    --plist)
      plist_path="$2"
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

if [ -z "$agent_bin" ] || [ -z "$config_path" ]; then
  usage >&2
  exit 2
fi

for path in "$agent_bin" "$config_path" "$log_dir" "$plist_path"; do
  case "$path" in
    /*) ;;
    *) echo "All paths must be absolute: $path" >&2; exit 2 ;;
  esac
done

if [ ! -x "$agent_bin" ]; then
  echo "agent binary is not executable: $agent_bin" >&2
  exit 1
fi

if [ ! -f "$config_path" ]; then
  echo "config file does not exist: $config_path" >&2
  exit 1
fi

mkdir -p "$(dirname -- "$plist_path")" "$log_dir"

if [ -L "$plist_path" ] || { [ -e "$plist_path" ] && [ ! -f "$plist_path" ]; }; then
  echo "plist path must be a regular file, not a symlink: $plist_path" >&2
  exit 1
fi

temp_plist=$(mktemp "${plist_path}.tmp.XXXXXX")
trap 'rm -f "$temp_plist"' EXIT
trap 'exit 1' HUP INT TERM
cp "$template_path" "$temp_plist"
plutil -remove ProgramArguments.0 "$temp_plist"
plutil -insert ProgramArguments.0 -string "$agent_bin" "$temp_plist"
plutil -remove ProgramArguments.3 "$temp_plist"
plutil -insert ProgramArguments.3 -string "$config_path" "$temp_plist"
plutil -replace StandardOutPath -string "$log_dir/agent.stdout.log" "$temp_plist"
plutil -replace StandardErrorPath -string "$log_dir/agent.stderr.log" "$temp_plist"
plutil -lint "$temp_plist"
chmod 0644 "$temp_plist"

domain="gui/$(id -u)"
service="$domain/com.macos-auth.agent"
if launchctl print "$service" >/dev/null 2>&1; then
  launchctl bootout "$service"
fi
mv -f "$temp_plist" "$plist_path"

launchctl bootstrap "$domain" "$plist_path"
launchctl enable "$service"

echo "Installed and loaded $plist_path"
