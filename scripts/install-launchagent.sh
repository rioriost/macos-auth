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

case "$agent_bin" in
  /*) ;;
  *) echo "--agent-bin must be absolute" >&2; exit 2 ;;
esac

case "$config_path" in
  /*) ;;
  *) echo "--config must be absolute" >&2; exit 2 ;;
esac

if [ ! -x "$agent_bin" ]; then
  echo "agent binary is not executable: $agent_bin" >&2
  exit 1
fi

if [ ! -f "$config_path" ]; then
  echo "config file does not exist: $config_path" >&2
  exit 1
fi

mkdir -p "$(dirname -- "$plist_path")" "$log_dir"

escape_sed() {
  printf '%s' "$1" | sed 's/[&|]/\\&/g'
}

agent_bin_escaped=$(escape_sed "$agent_bin")
config_path_escaped=$(escape_sed "$config_path")
log_dir_escaped=$(escape_sed "$log_dir")

sed \
  -e "s|__MACOS_AUTH_AGENT_BIN__|$agent_bin_escaped|g" \
  -e "s|__MACOS_AUTH_AGENT_CONFIG__|$config_path_escaped|g" \
  -e "s|__MACOS_AUTH_LOG_DIR__|$log_dir_escaped|g" \
  "$template_path" > "$plist_path"

chmod 0644 "$plist_path"

launchctl bootout "gui/$(id -u)" "$plist_path" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$plist_path"
launchctl enable "gui/$(id -u)/com.macos-auth.agent"

echo "Installed and loaded $plist_path"
