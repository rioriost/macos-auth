#!/bin/sh
set -eu

usage() {
  cat <<'USAGE'
Usage:
  macos-dev-setup.sh --host-id ID --host-pubkey-file PATH [options]

Creates a development macOS agent setup:
  - builds macos-auth-agent
  - installs it to ~/.local/bin/macos-auth-agent by default
  - creates ~/Library/Application Support/macos-auth
  - stores/generates an agent key in Keychain
  - writes agent-config.json
  - optionally installs a LaunchAgent

Options:
  --host-id ID                 Linux host id to allow
  --host-pubkey-file PATH      Linux host public key file to copy into the allowlist
  --app-dir PATH               Default: ~/Library/Application Support/macos-auth
  --agent-bin PATH             Default: ~/.local/bin/macos-auth-agent
  --socket-path PATH           Default: APP_DIR/agent.sock
  --keychain-service NAME      Default: com.macos-auth.agent
  --keychain-account NAME      Default: default
  --overwrite-keychain         Replace existing Keychain key material
  --install-launchagent        Install and load the LaunchAgent after writing config
  -h, --help                   Show this help
USAGE
}

host_id=""
host_pubkey_file=""
app_dir="$HOME/Library/Application Support/macos-auth"
agent_bin="$HOME/.local/bin/macos-auth-agent"
socket_path=""
keychain_service="com.macos-auth.agent"
keychain_account="default"
overwrite_keychain=0
install_launchagent=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host-id)
      host_id="$2"
      shift 2
      ;;
    --host-pubkey-file)
      host_pubkey_file="$2"
      shift 2
      ;;
    --app-dir)
      app_dir="$2"
      shift 2
      ;;
    --agent-bin)
      agent_bin="$2"
      shift 2
      ;;
    --socket-path)
      socket_path="$2"
      shift 2
      ;;
    --keychain-service)
      keychain_service="$2"
      shift 2
      ;;
    --keychain-account)
      keychain_account="$2"
      shift 2
      ;;
    --overwrite-keychain)
      overwrite_keychain=1
      shift
      ;;
    --install-launchagent)
      install_launchagent=1
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

if [ -z "$host_id" ] || [ -z "$host_pubkey_file" ]; then
  usage >&2
  exit 2
fi

if [ ! -f "$host_pubkey_file" ]; then
  echo "host public key file does not exist: $host_pubkey_file" >&2
  exit 1
fi

if [ -z "$socket_path" ]; then
  socket_path="$app_dir/agent.sock"
fi

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

mkdir -p "$(dirname -- "$agent_bin")" "$app_dir/hosts"

swift build --package-path "$repo_root/agent"
cp "$repo_root/agent/.build/debug/macos-auth-agent" "$agent_bin"
chmod 0755 "$agent_bin"

host_pubkey_dest="$app_dir/hosts/$host_id.pub"
cp "$host_pubkey_file" "$host_pubkey_dest"
chmod 0644 "$host_pubkey_dest"

keychain_args=""
if [ "$overwrite_keychain" -eq 1 ]; then
  keychain_args="--overwrite"
fi

"$agent_bin" keychain-init \
  --service "$keychain_service" \
  --account "$keychain_account" \
  $keychain_args > "$app_dir/agent_public_key.txt"

config_path="$app_dir/agent-config.json"
cat > "$config_path" <<EOF
{
  "socket_path": "$socket_path",
  "hosts": [
    {
      "host_id": "$host_id",
      "public_key_file": "$host_pubkey_dest"
    }
  ],
  "agent_keychain_service": "$keychain_service",
  "agent_keychain_account": "$keychain_account",
  "agent_key_id": "agent-key-1",
  "allowed_future_skew_ms": 30000,
  "require_confirmation": true,
  "rate_limit_window_seconds": 60,
  "rate_limit_max_requests": 5
}
EOF
chmod 0644 "$config_path"

if [ "$install_launchagent" -eq 1 ]; then
  "$repo_root/scripts/install-launchagent.sh" \
    --agent-bin "$agent_bin" \
    --config "$config_path"
fi

cat <<EOF
macos-auth development agent setup complete.

Agent binary: $agent_bin
Agent config: $config_path
Agent socket: $socket_path
Host public key: $host_pubkey_dest
Agent public key: $app_dir/agent_public_key.txt

If you did not pass --install-launchagent, run manually with:
  "$agent_bin" serve --config "$config_path"
EOF
